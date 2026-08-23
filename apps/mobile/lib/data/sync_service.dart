/// Backs the on-device archive up to `services/api`.
///
/// The phone owns its readings; this uploads copies. Nothing here deletes local
/// data on success — [ReadingStore.prune] does that on its own retention
/// schedule, and only for rows already acknowledged.
///
/// ### Failure is the normal case
///
/// This runs on a rural device. A flat network is expected, so:
///
/// * **Transient failures cost nothing.** An unreachable server leaves the queue
///   exactly as it was; the next cycle retries. Only a response the server
///   actually returned counts against a reading.
/// * **Retries are safe.** Every reading carries a `client_id` generated when it
///   was archived, and the server's `(patient_id, client_id)` uniqueness turns a
///   re-sent batch into duplicates rather than new rows. A batch dropped halfway
///   is re-sent whole.
/// * **Duplicates are success.** `stored + duplicates` is what gets marked
///   synced: a duplicate means the archive already has it.
/// * **The backlog drains oldest-first** and in bounded batches, so a week
///   offline arrives as a coherent history rather than as newest-first fragments.
///
/// ### Ordering
///
/// Enrolment goes first, then SOS, then readings. SOS before vitals because an
/// emergency is time-critical and a large reading backlog must not delay it —
/// a batch of 200 readings on a weak link can take tens of seconds.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'profile_store.dart';
import 'reading_store.dart';
import 'settings.dart';

enum SyncState {
  /// Nothing in flight and nothing known to be wrong.
  idle,

  uploading,

  /// Everything queued has been acknowledged.
  upToDate,

  /// The server could not be reached. Not an error the user must act on — the
  /// queue is intact and the next cycle retries.
  offline,

  /// The server answered, and refused. This one does need surfacing.
  failed,

  /// Backup switched off in Settings. The local archive still fills.
  disabled;

  bool get isBusy => this == SyncState.uploading;
}

@immutable
class SyncOutcome {
  const SyncOutcome({
    this.stored = 0,
    this.duplicates = 0,
    this.rejected = 0,
    this.sosUploaded = 0,
    this.state = SyncState.idle,
    this.error,
  });

  final int stored;
  final int duplicates;
  final int rejected;
  final int sosUploaded;
  final SyncState state;
  final String? error;

  bool get succeeded => state == SyncState.upToDate;

  /// Wording for a one-line status in Settings.
  String get summary => switch (state) {
        SyncState.disabled => 'Backup is off. Readings are saved on this phone only.',
        SyncState.offline => 'Server unreachable. Readings are queued on this phone.',
        SyncState.failed => error ?? 'The server refused the upload.',
        SyncState.uploading => 'Backing up…',
        _ when stored == 0 && duplicates == 0 => 'Everything is backed up.',
        _ => 'Backed up $stored reading${stored == 1 ? '' : 's'}.',
      };
}

class SyncService extends ChangeNotifier {
  SyncService({
    required AppSettings settings,
    required ProfileStore profileStore,
    required ReadingStore store,
    http.Client? client,
    this.interval = const Duration(minutes: 5),
  })  : _settings = settings,
        _profiles = profileStore,
        _store = store,
        _client = client ?? http.Client();

  final AppSettings _settings;
  final ProfileStore _profiles;
  final ReadingStore _store;
  final http.Client _client;

  /// How often a background cycle runs.
  ///
  /// Five minutes, not seconds: the sample interval is a minute, so a tighter
  /// cycle would spend radio wake-ups to upload one or two rows. Battery on a
  /// device someone wears all day is a feature.
  final Duration interval;

  /// How long a freshly-archived reading waits before it is uploaded.
  ///
  /// Long enough that a run of samples is coalesced into one request, short
  /// enough that the dashboard is not five minutes behind the wrist. Repeated
  /// nudges inside the window collapse into the one already scheduled, so the
  /// radio cost is bounded by this delay and not by the sample rate.
  static const Duration nudgeDelay = Duration(seconds: 45);

  Timer? _timer;
  Timer? _nudgeTimer;
  Timer? _retryTimer;
  int _offlineStreak = 0;
  bool _inFlight = false;

  /// True once [detach] ran: this instance is being replaced (profile switch)
  /// or torn down. Every entry point and notification checks it, so an upload
  /// cycle that was in flight during the swap cannot touch the stores it no
  /// longer owns or fire listeners on a service the app has moved past.
  bool _detached = false;

  SyncState _state = SyncState.idle;
  SyncOutcome _last = const SyncOutcome();
  int _pending = 0;
  int _quarantined = 0;

  SyncState get state => _settings.backupEnabled ? _state : SyncState.disabled;
  SyncOutcome get lastOutcome => _last;
  int get pendingCount => _pending;

  /// Readings the server refused repeatedly and that are no longer retried.
  /// Non-zero means the backup is knowingly incomplete.
  int get quarantinedCount => _quarantined;

  DateTime? get lastSyncAt => _settings.lastSyncAt;

  static const _timeout = Duration(seconds: 20);

  /// Fingerprint of the last successfully-enrolled name+profile.
  ///
  /// Enrolment is idempotent server-side, but sending it every cycle would be a
  /// wasted round trip on a link that may be metered. Comparing a fingerprint
  /// means it goes out once per session and once per profile edit.
  String? _enrolledFingerprint;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => syncNow());
    // A profile edit changes the fingerprint, so re-enrol on the next cycle.
    _profiles.addListener(_onProfileChanged);
    _settings.addListener(_onSettingsChanged);
    refreshCounts();
    syncNow();
  }

  void _onProfileChanged() {
    _enrolledFingerprint = null;
    syncNow();
  }

  /// A corrected server address is usually someone fixing a failed connection,
  /// so retry immediately rather than waiting out the rest of the cycle.
  void _onSettingsChanged() {
    _enrolledFingerprint = null;
    if (_settings.backupEnabled) syncNow();
    notifyListeners();
  }

  /// Asks for an upload soon, without forcing one now.
  ///
  /// Called by [MonitorController] each time a reading lands in the archive, so a
  /// worn watch keeps the server current instead of waiting out the five-minute
  /// cycle. Cheap and idempotent: a nudge while one is already pending is
  /// dropped, and a nudge while a cycle is in flight is ignored because that
  /// cycle drains the whole queue anyway.
  void nudge() {
    if (_detached || !_settings.backupEnabled) return;
    if (_inFlight || _nudgeTimer != null) return;
    _nudgeTimer = Timer(nudgeDelay, () {
      _nudgeTimer = null;
      syncNow();
    });
  }

  /// Retries sooner than the next cycle after a failed one, backing off.
  ///
  /// 30s, 60s, 120s… capped at the periodic interval. Without this, a phone that
  /// regains signal ten seconds after a failure sits idle for the rest of the
  /// five minutes; with an unbounded retry it would hammer a dead server.
  void _scheduleRetry() {
    _retryTimer?.cancel();
    final seconds = (30 * (1 << (_offlineStreak - 1).clamp(0, 3)))
        .clamp(30, interval.inSeconds);
    _retryTimer = Timer(Duration(seconds: seconds), () {
      _retryTimer = null;
      syncNow();
    });
  }

  /// Stops this service without closing the HTTP client.
  ///
  /// Used on profile switch, where the service is *replaced* rather than
  /// discarded: timers stop and in-flight work becomes a no-op, but [dispose]'s
  /// client shutdown — shared with nothing — waits for real teardown.
  void detach() {
    _detached = true;
    _timer?.cancel();
    _nudgeTimer?.cancel();
    _retryTimer?.cancel();
    _profiles.removeListener(_onProfileChanged);
    _settings.removeListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    detach();
    _client.close();
    super.dispose();
  }

  Future<void> refreshCounts() async {
    if (_detached) return;
    _pending = await _store.pendingCount();
    _quarantined = await _store.quarantinedCount();
    notifyListeners();
  }

  /// Runs one full cycle: enrol, then SOS, then readings.
  ///
  /// Re-entrant calls return the previous outcome rather than queueing. Two
  /// concurrent cycles would upload the same batch twice — harmless on the server
  /// thanks to the uniqueness constraint, but it would double the radio traffic
  /// for nothing.
  Future<SyncOutcome> syncNow() async {
    if (_detached) return _last;
    if (!_settings.backupEnabled) {
      _setState(SyncState.disabled);
      return _last = const SyncOutcome(state: SyncState.disabled);
    }
    if (_inFlight) return _last;
    _inFlight = true;
    // A cycle drains the whole queue, so anything already scheduled is redundant.
    _nudgeTimer?.cancel();
    _nudgeTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _setState(SyncState.uploading);

    try {
      final outcome = await _runCycle();
      _last = outcome;
      _setState(outcome.state);
      if (outcome.succeeded) {
        _offlineStreak = 0;
        await _settings.recordSync(DateTime.now().toUtc());
      } else if (outcome.state == SyncState.offline) {
        _offlineStreak++;
        _scheduleRetry();
      }
      return outcome;
    } finally {
      _inFlight = false;
      await refreshCounts();
    }
  }

  Future<SyncOutcome> _runCycle() async {
    try {
      await _enrolIfNeeded();
    } on _Unreachable catch (e) {
      return SyncOutcome(state: SyncState.offline, error: e.message);
    } on _Refused catch (e) {
      // Enrolment is what creates the patient record, so nothing can be uploaded
      // until it succeeds. Reporting it is more useful than uploading readings
      // that would 404.
      return SyncOutcome(state: SyncState.failed, error: e.message);
    }

    var sosUploaded = 0;
    try {
      sosUploaded = await _uploadSos();
    } on _Unreachable catch (e) {
      return SyncOutcome(state: SyncState.offline, error: e.message);
    } on _Refused {
      // A refused SOS must not stop the readings backup. It stays queued.
    }

    var stored = 0;
    var duplicates = 0;
    var rejected = 0;

    // Bounded rather than `while (true)`: a server that acknowledges a batch
    // without storing it would otherwise spin here indefinitely.
    const maxBatches = 20;
    for (var batch = 0; batch < maxBatches; batch++) {
      final queued = await _store.unsynced();
      if (queued.isEmpty) break;

      try {
        final result = await _uploadReadings(queued);
        stored += result.stored;
        duplicates += result.duplicates;
        rejected += result.rejected.length;

        // Duplicates count as delivered — the server already holds them.
        final accepted = queued
            .map((r) => r.clientId)
            .where((id) => !result.rejected.contains(id));
        await _store.markSynced(accepted);

        if (result.rejected.isNotEmpty) {
          await _store.recordFailedAttempt(result.rejected);
        }
      } on _Unreachable catch (e) {
        // Queue untouched, no attempt counted. Next cycle retries.
        return SyncOutcome(
          stored: stored,
          duplicates: duplicates,
          rejected: rejected,
          sosUploaded: sosUploaded,
          state: SyncState.offline,
          error: e.message,
        );
      } on _Refused catch (e) {
        // The server answered and refused the whole batch — a 422 on one bad row
        // rejects all of them. Count the attempt so a poison reading eventually
        // drops out of the queue instead of blocking everything behind it.
        await _store.recordFailedAttempt(queued.map((r) => r.clientId));
        return SyncOutcome(
          stored: stored,
          duplicates: duplicates,
          rejected: rejected + queued.length,
          sosUploaded: sosUploaded,
          state: SyncState.failed,
          error: e.message,
        );
      }
    }

    return SyncOutcome(
      stored: stored,
      duplicates: duplicates,
      rejected: rejected,
      sosUploaded: sosUploaded,
      state: SyncState.upToDate,
    );
  }

  Future<void> _enrolIfNeeded() async {
    final profile = _profiles.profile;
    final name = _profiles.resolvedDisplayName(_settings.patientId);
    final fingerprint = '$name|${jsonEncode(profile.toJson())}';
    if (_enrolledFingerprint == fingerprint) return;

    await _post('/v1/patients', {
      'patient_id': _settings.patientId,
      'display_name': name,
      'profile': profile.toJson(),
      'device_name': 'MECAI-Watch',
      'app_version': appVersion,
    });
    _enrolledFingerprint = fingerprint;
  }

  Future<int> _uploadSos() async {
    final queued = await _store.unsyncedSos();
    if (queued.isEmpty) return 0;

    final delivered = <String>[];
    for (final event in queued) {
      await _post('/v1/sos', event.toSyncJson(_settings.patientId));
      delivered.add(event.clientId);
    }
    await _store.markSosSynced(delivered);
    return delivered.length;
  }

  Future<_SyncResult> _uploadReadings(List<StoredReading> queued) async {
    final body = await _post('/v1/readings/sync', {
      'patient_id': _settings.patientId,
      // Sent with the batch so a profile edited offline scores the readings it
      // arrives with, rather than whatever the server last heard.
      'profile': _profiles.profile.toJson(),
      'readings': queued.map((r) => r.toSyncJson()).toList(growable: false),
    });
    return _SyncResult.fromJson(body);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> payload) async {
    final url = Uri.parse('${_settings.apiBaseUrl}$path');
    final http.Response response;
    try {
      response = await _client
          .post(
            url,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(_timeout);
    } on Exception catch (error) {
      throw _Unreachable("Can't reach ${_settings.apiBaseUrl} ($error)");
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    // 5xx is the server having a bad time, not this data being wrong. Treated as
    // transient so a restarting server does not burn attempts on good readings.
    if (response.statusCode >= 500) {
      throw _Unreachable('Server error ${response.statusCode} on $path.');
    }
    throw _Refused(_refusalMessage(response, path));
  }

  String _refusalMessage(http.Response response, String path) =>
      switch (response.statusCode) {
        404 =>
          'The server has no record of this device yet, and enrolment was rejected. '
              'Check the address in Settings points at a MEC-AI server.',
        422 => 'The server rejected the data as implausible ($path).',
        _ => 'Server returned ${response.statusCode} on $path.',
      };

  void _setState(SyncState next) {
    if (_detached || _state == next) return;
    _state = next;
    notifyListeners();
  }
}

/// Reported to the server as `app_version`, so the dashboard can tell which build
/// a patient's readings came from when their shape changes.
const String appVersion = '0.1.0';

@immutable
class _SyncResult {
  const _SyncResult({
    required this.stored,
    required this.duplicates,
    required this.rejected,
  });

  final int stored;
  final int duplicates;
  final List<String> rejected;

  factory _SyncResult.fromJson(Map<String, dynamic> json) => _SyncResult(
        stored: (json['stored'] as num?)?.toInt() ?? 0,
        duplicates: (json['duplicates'] as num?)?.toInt() ?? 0,
        rejected: (json['rejected'] as List<dynamic>? ?? const [])
            .cast<String>()
            .toList(growable: false),
      );
}

/// The network failed. Costs the queue nothing.
class _Unreachable implements Exception {
  _Unreachable(this.message);
  final String message;
}

/// The server answered and refused. Counts against the data.
class _Refused implements Exception {
  _Refused(this.message);
  final String message;
}
