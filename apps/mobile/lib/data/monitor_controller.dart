/// Shared live-monitoring state for the whole app.
///
/// Before the app had more than one screen, all of this lived inside
/// `_HomeScreenState`. Four tabs now need the same link state, the same reading
/// history and the same assessment, and four independent BLE subscriptions to one
/// characteristic would mean four copies of the history diverging from each other —
/// and a `_score()` race between them over which figure the ring shows.
///
/// So exactly one of these exists, owned by the shell, and every tab listens.
///
/// ### The two scoring paths, and which one is cached
///
/// * **Acute flags** are evaluated locally from the *current* reading on every
///   update, and never cached. An SpO2 of 88% is an emergency with or without a
///   network, and a stale flag — or worse, a stale *absence* of one — is the one
///   thing this class must never show.
/// * **The ten-year band** comes from the server, is written to
///   [AssessmentCache], and is served from there while the server is unreachable.
///   The local engine is the fallback only when nothing has ever been cached, so
///   the app is not blank on first launch.
///
/// That split is why a lost connection leaves the risk figure unchanged rather
/// than swapping it for a locally-recomputed one: a ten-year estimate that moves
/// when you walk out of Wi-Fi range is not a number to trust.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/vitals.dart';
import 'acute_flags.dart';
import 'alert_gate.dart';
import 'alert_notifications.dart';
import 'assessment_cache.dart';
import 'ble_vitals_source.dart';
import 'bp_estimator.dart';
import 'emergency_contacts.dart';
import 'local_risk_engine.dart';
import 'location_service.dart';
import 'profile_store.dart';
import 'reading_store.dart';
import 'risk_service.dart';
import 'settings.dart';
import 'sos_dispatcher.dart';
import 'sync_service.dart';
import 'vitals_source.dart';

/// Where the displayed ten-year figure came from.
enum ScoreOrigin {
  /// Computed by the server just now.
  server,

  /// The last figure the server produced, replayed while it is unreachable.
  cached,

  /// The on-device engine, because the server has never been reached.
  onDevice,

  /// Nothing to show — no reading, or an incomplete profile.
  none;

  bool get isStale => this == ScoreOrigin.cached;
}

class MonitorController extends ChangeNotifier {
  MonitorController({
    required VitalsSource source,
    required RiskService riskService,
    required AppSettings settings,
    required ProfileStore profileStore,
    required AssessmentCache assessmentCache,
    required EmergencyContacts emergencyContacts,
    ReadingStore? readingStore,
    SyncService? syncService,
    LocationService? locationService,
    SosDispatcher dispatcher = const SosDispatcher(),
  })  : _source = source,
        _riskService = riskService,
        _settings = settings,
        _profiles = profileStore,
        _cache = assessmentCache,
        _contacts = emergencyContacts,
        _store = readingStore,
        _sync = syncService,
        _location = locationService ?? LocationService(),
        _dispatcher = dispatcher {
    _profiles.addListener(_onProfileEdited);
  }

  final VitalsSource _source;
  final RiskService _riskService;
  final AppSettings _settings;
  final AssessmentCache _cache;
  final LocationService _location;
  final SosDispatcher _dispatcher;

  /// The active person's stores. Mutable because one install can serve several
  /// people — see [switchProfile] and [ProfileRegistry].
  ProfileStore _profiles;
  EmergencyContacts _contacts;
  ReadingStore? _store;
  SyncService? _sync;

  VitalsSource get source => _source;

  /// The BLE link when this device has one, for screens that offer re-pairing.
  /// Null on the mock/desktop path, where no watch can connect at all.
  BleVitalsSource? get bleSource =>
      _source is BleVitalsSource ? _source : null;
  ReadingStore? get store => _store;
  SyncService? get syncService => _sync;
  ProfileStore get profileStore => _profiles;
  AppSettings get settings => _settings;
  RiskService get riskService => _riskService;
  RiskProfile get profile => _profiles.profile;
  EmergencyContacts get emergencyContacts => _contacts;
  LocationService get locationService => _location;

  /// The fix captured for the SOS currently on screen, so the emergency screen can
  /// show where the alert says the user is.
  LocationFix? get sosFix => _sosFix;

  /// Result of the last send, so the UI can name who it reached rather than
  /// leaving the user unsure whether anything went out.
  DispatchResult? get lastDispatch => _lastDispatch;

  StreamSubscription<WatchVitals>? _vitalsSub;
  StreamSubscription<bool>? _sosSub;
  StreamSubscription<LinkState>? _linkSub;

  /// Forwards questionnaire edits into the scoring path.
  ///
  /// Owned here rather than by the shell so that [switchProfile] can re-point
  /// it at the new person's store in one place; screens come and go, this
  /// subscription must survive across them.
  void _onProfileEdited() => onProfileChanged();

  List<VitalsReading> _history = const [];
  RiskAssessment? _assessment;
  List<String> _notes = const [];
  ScoreOrigin _origin = ScoreOrigin.none;
  DateTime? _scoredAt;
  bool _wearing = false;
  bool _sosActive = false;
  String _sosOrigin = 'app';
  bool _loading = true;
  String? _serverError;
  LocationFix? _sosFix;
  DispatchResult? _lastDispatch;

  /// Live in-memory window, oldest first. Seeded from the archive on start so the
  /// charts open on real history rather than filling in a moment later.
  List<VitalsReading> get history => _history;

  VitalsReading? get latest => _history.isEmpty ? null : _history.last;

  RiskAssessment? get assessment => _assessment;
  List<String> get notes => _notes;
  ScoreOrigin get scoreOrigin => _origin;

  /// When the displayed figure was computed. Drives the "scored N ago" label that
  /// makes a replayed figure legible as one.
  DateTime? get scoredAt => _scoredAt;

  bool get wearing => _wearing;
  bool get sosActive => _sosActive;

  String get sosOrigin => _sosOrigin;
  bool get loading => _loading;
  LinkState get linkState => _source.currentLinkState;

  /// Set when the server answered with an error. Null while merely unreachable —
  /// being offline is the expected state for this device, not a fault to report.
  String? get serverError => _serverError;

  /// Evaluated live, every read. Never cached — see the class docstring.
  List<AcuteFlag> get acuteFlags {
    final reading = latest;
    return reading == null ? const [] : evaluateAcuteFlags(reading);
  }

  /// The cuffless blood-pressure estimate, derived from the live heart rate and
  /// SpO₂ against the cuff baseline in the profile.
  ///
  /// Deliberately a separate getter rather than fields on [latest]: nothing that
  /// consumes a [VitalsReading] — the acute engine, the upload payload, the
  /// Framingham path — may see an estimate where it expects a measurement. See
  /// `bp_estimator.dart`.
  BpEstimate get bpEstimate => estimateBloodPressure(
        profile: profile,
        reading: latest,
        history: _history,
      );

  /// The worst severity currently present, for the nav badge and the alarm banner.
  Severity? get worstSeverity {
    final flags = acuteFlags;
    if (flags.isEmpty) return null;
    // `evaluateAcuteFlags` returns most-severe first.
    return flags.first.severity;
  }

  int get criticalCount =>
      acuteFlags.where((f) => f.severity == Severity.critical).length;

  // ───────────────────────────── lifecycle ─────────────────────────────

  Future<void> start() async {
    // 1. Restore what was already recorded.
    await _seedFromArchive();
    _loading = false;
    notifyListeners();

    // 2. Bring the link up in the background.
    _source.connect();
    _linkSub = _source.linkState.listen((state) {
      // A dropped link ends the episode as far as the gate is concerned: the
      // readings after a reconnect describe a fresh situation, and a cooldown
      // carried across the gap would suppress the first alarm after it.
      // Only `disconnected` — `connected` precedes `streaming`, so resetting on
      // "anything but streaming" would clear the gate mid-episode.
      if (state == LinkState.disconnected) _alertGate.reset();
      notifyListeners();
    });

    final source = _source;
    if (source is BleVitalsSource) {
      _vitalsSub = source.watchVitals.listen(_onWatchVitals);
      _sosSub = source.sosStream.listen((sos) {
        _sosActive = sos;
        notifyListeners();
      });
    } else {
      // Mock/desktop path: seed from whatever the source can replay.
      final replayed = await source.history(window: const Duration(hours: 12));
      _history = [..._history, ...replayed];
      notifyListeners();
    }

    await score();
  }

  /// Loads the active person's archived history and their last server score.
  ///
  /// Used at startup and again after a profile switch — the same two questions:
  /// "what does *this* person's last while look like, and what did we last tell
  /// them?" The cache answers only when its fingerprint matches, so a figure
  /// computed for someone else can never be shown here.
  Future<void> _seedFromArchive() async {
    final store = _store;
    if (store != null) {
      try {
        _history = await store.recent(window: const Duration(hours: 12));
      } on Object catch (error) {
        debugPrint('MonitorController: could not read the archive. $error');
      }
    }
    _restoreCachedScore();
  }

  /// Re-binds every per-person store to [profileStore]'s owner.
  ///
  /// Called by the app shell after the caller has loaded the new person's
  /// stores and re-pointed identity. The assignments happen before any await,
  /// so nothing downstream — an in-flight BLE packet, a scoring response for
  /// the previous person — can observe half of the swap. What belonged to the
  /// previous person is discarded outright rather than carried over: history,
  /// score, SOS fix and dispatch result are all facts about *someone else*, and
  /// showing them under a new name would be worse than showing nothing.
  ///
  /// The caller owns the old stores' lifecycle (the readings database stays
  /// open; it will be needed again when that profile returns).
  Future<void> switchProfile({
    required ProfileStore profileStore,
    required EmergencyContacts emergencyContacts,
    ReadingStore? readingStore,
    SyncService? syncService,
  }) async {
    _profiles.removeListener(_onProfileEdited);
    _profiles = profileStore;
    _contacts = emergencyContacts;
    _store = readingStore;
    _sync = syncService;
    _profiles.addListener(_onProfileEdited);

    _history = const [];
    _assessment = null;
    _notes = const [];
    _origin = ScoreOrigin.none;
    _scoredAt = null;
    _serverError = null;
    _sosFix = null;
    _lastDispatch = null;
    _alertGate.reset();
    _loading = true;
    notifyListeners();

    await _seedFromArchive();
    _loading = false;
    notifyListeners();
    await score();
  }

  @override
  void dispose() {
    _vitalsSub?.cancel();
    _sosSub?.cancel();
    _linkSub?.cancel();
    _profiles.removeListener(_onProfileEdited);
    super.dispose();
  }

  void _onWatchVitals(WatchVitals vitals) {
    final reading = VitalsReading(
      heartRateBpm: vitals.heartRateBpm,
      spo2Pct: vitals.spo2Pct,
      ambientTempC: vitals.ambientTempC,
      measuredAt: DateTime.now(),
    );

    _wearing = vitals.wearing;
    final sosChanged = vitals.sosActive != _sosActive;
    _sosActive = vitals.sosActive;
    if (sosChanged && vitals.sosActive) _sosOrigin = 'watch';

    // Every packet feeds the live UI; the archive samples separately.
    _history = [..._history, reading];
    if (_history.length > 1440) {
      _history = _history.sublist(_history.length - 1440);
    }

    _archive(reading, wearing: vitals.wearing);
    _notifyAcuteAlert(reading);
    notifyListeners();

    unawaited(score());
  }

  /// Rate-limits the notification channel. See `alert_gate.dart` — a sustained
  /// SpO2 of ~90% used to fire a fresh max-importance alarm about twice a second,
  /// because the dedupe key included the noisy value.
  final AlertGate _alertGate = AlertGate();

  void _notifyAcuteAlert(VitalsReading reading) {
    for (final flag in _alertGate.due(evaluateAcuteFlags(reading))) {
      AlertNotifications.show(flag).catchError((_) {});
    }
  }

  void _archive(VitalsReading reading, {bool? wearing}) {
    final store = _store;
    if (store == null) return;
    // Fire-and-forget: a slow disk must not stall a 2 Hz stream, and a failed
    // write must not interrupt live monitoring.
    store.insertSampled(reading, wearing: wearing).then((clientId) {
      if (clientId == null) return;
      _sync?.refreshCounts();
      // A row was actually archived, so ask for an upload shortly. Coalesced
      // inside SyncService — this fires per stored sample, not per BLE packet,
      // and several inside the window still cost one request.
      _sync?.nudge();
    }).catchError((Object error) {
      debugPrint('MonitorController: archive write failed. $error');
      return null;
    });
  }

  // ────────────────────────────── scoring ──────────────────────────────

  void _restoreCachedScore() {
    final entry = _cache.cached;
    if (entry == null || !entry.matches(profile)) return;
    _assessment = entry.assessment;
    _notes = entry.notes;
    _origin = ScoreOrigin.cached;
    _scoredAt = entry.computedAt;
  }

  /// Recomputes the displayed figure.
  ///
  /// Order matters: whatever can be shown without a network goes up first, then
  /// the server is asked and allowed to replace it. The UI is never blocked on a
  /// request.
  Future<void> score() async {
    final reading = latest ?? _emptyReading();

    // 1. Something on screen now.
    if (_assessment == null || _origin == ScoreOrigin.onDevice) {
      final local = evaluateRiskLocally(profile: profile, reading: reading);
      _assessment = local.assessment;
      _notes = local.notes;
      _origin = local.assessment.isScored ? ScoreOrigin.onDevice : ScoreOrigin.none;
      _scoredAt = DateTime.now().toUtc();
      notifyListeners();
    }

    // 2. Ask the server, and let it win.
    try {
      final response = await _riskService.assess(profile: profile, reading: reading);
      _serverError = null;

      if (response.assessment.confidence == Confidence.complete) {
        _assessment = response.assessment;
        _notes = response.notes;
        _origin = ScoreOrigin.server;
        _scoredAt = DateTime.now().toUtc();
        // Persisted so the figure survives losing the connection.
        await _cache.save(
          assessment: response.assessment,
          profile: profile,
          notes: response.notes,
        );
      } else if (_cache.cached == null || !_cache.cached!.matches(profile)) {
        // The server says it cannot score this profile, and there is no stored
        // figure that describes it either. Show the incomplete state rather than
        // an old score computed from different inputs.
        _assessment = response.assessment;
        _notes = response.notes;
        _origin = ScoreOrigin.none;
        _scoredAt = DateTime.now().toUtc();
      }
      notifyListeners();
    } on RiskServiceException {
      // Unreachable. Keep the cached figure exactly as it is — this is the whole
      // point of caching it — and do not report an error for an expected state.
      if (_origin == ScoreOrigin.server) _origin = ScoreOrigin.cached;
      notifyListeners();
    }
  }

  VitalsReading _emptyReading() => VitalsReading(measuredAt: DateTime.now());

  /// Re-scores after the questionnaire changed. The cached figure no longer
  /// describes the profile, so it is dropped rather than relabelled.
  Future<void> onProfileChanged() async {
    final entry = _cache.cached;
    if (entry != null && !entry.matches(profile)) {
      _origin = ScoreOrigin.none;
    }
    await score();
  }

  // ──────────────────────────────── SOS ────────────────────────────────

  /// Records an SOS: capture the location, store it, upload it.
  ///
  /// Order matters. The alert is written to the local archive *before* the network
  /// is touched, and the location attempt is bounded — an SOS raised where there is
  /// no signal is still an SOS, and neither a dead network nor a missing GPS fix may
  /// prevent it being recorded.
  ///
  /// Returns the fix so the caller can compose the message from the same
  /// coordinates that were stored, rather than reading the GPS a second time and
  /// possibly reporting a different place than the record shows.
  Future<LocationFix> recordSos(String origin) async {
    final triggeredAt = DateTime.now().toUtc();

    // Bounded, and failure-free by construction — see LocationService.
    final fix = await _location.currentFix();
    _sosFix = fix;
    notifyListeners();

    final store = _store;
    if (store != null) {
      try {
        await store.insertSos(
          triggeredAt: triggeredAt,
          source: origin,
          latitude: fix.latitude,
          longitude: fix.longitude,
          accuracyM: fix.accuracyM,
          reading: latest,
          note: fix.hasPosition ? null : fix.problem,
        );
        await _sync?.syncNow();
      } on Object catch (error) {
        debugPrint('MonitorController: could not queue the SOS. $error');
      }
    }

    return fix;
  }

  /// Sends the emergency SMS to every configured contact.
  ///
  /// Uses [sosFix] rather than re-reading the GPS, so the message names the same
  /// place the stored record does — a second read could return a different
  /// position and then the archive and the message would disagree about where the
  /// emergency happened.
  Future<DispatchResult> dispatchSms() async {
    final fix = _sosFix ?? const LocationFix.unavailable();
    final message = SosDispatcher.composeMessage(
      patientName: _profiles.resolvedDisplayName(_settings.patientId),
      fix: fix,
      heartRateBpm: latest?.heartRateBpm,
      spo2Pct: latest?.spo2Pct,
    );

    final result = await _dispatcher.sendEmergencySms(
      contacts: _contacts.contacts,
      message: message,
    );
    _lastDispatch = result;
    notifyListeners();
    return result;
  }

  void setSosActive(bool active) {
    if (_sosActive == active) return;
    _sosActive = active;
    if (active) _sosOrigin = 'app';
    notifyListeners();
  }

  /// Toggles SOS on the watch, if one is connected.
  void sendSosToWatch() {
    final source = _source;
    if (source is BleVitalsSource) {
      source.sendCommand(WatchCommand.toggleSos);
    }
  }
}
