/// Persisted app settings.
///
/// Holds how the app connects and how it identifies itself: the API address, the
/// locally-minted [AppSettings.patientId], and whether backup is switched on. Who
/// the user *is* lives in [ProfileStore] instead.
///
/// The API address is the setting that most often goes wrong, because the correct
/// value depends entirely on how the app is being run and there is no default that
/// works everywhere.
///
/// | Running on | Correct address |
/// |---|---|
/// | Android emulator | `10.0.2.2:8000` (host loopback alias) |
/// | iOS simulator | `127.0.0.1:8000` |
/// | Physical device on Wi-Fi | the host's LAN IP, e.g. `192.168.1.11:8000` |
///
/// A physical phone cannot reach `127.0.0.1` or `10.0.2.2` — those resolve to the
/// phone itself. Hence a user-editable field rather than a compile-time constant.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, debugPrintStack, kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

import 'reading_store.dart' show generateClientId;

const int defaultApiPort = 8000;

class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs, this._apiBaseUrl, this._patientId);

  static const _apiBaseUrlKey = 'api_base_url';
  static const _watchPairedKey = 'watch_paired';
  static const _pairingDismissedKey = 'pairing_dismissed';
  static const _patientIdKey = 'patient_id';
  static const _backupEnabledKey = 'backup_enabled';
  static const _lastSyncKey = 'last_sync_at';

  /// Null when preferences could not be opened — see [load]. Settings then work
  /// for the session but do not survive a restart.
  final SharedPreferences? _prefs;

  String _apiBaseUrl;
  bool _watchPaired = false;
  bool _pairingDismissed = false;
  String _patientId;
  bool _backupEnabled = true;
  DateTime? _lastSyncAt;

  String get apiBaseUrl => _apiBaseUrl;
  String get apiIpAddress => Uri.parse(_apiBaseUrl).host;
  bool get watchPaired => _watchPaired;

  /// True when the user chose to continue without pairing, via the long-hold
  /// skip on the setup screen. Persisted so a deliberate "not now" is not
  /// asked again at every launch — monitoring works without the watch, and
  /// nagging someone who already declined teaches them to dismiss faster,
  /// not to pair. Pairing stays available in Settings.
  bool get pairingDismissed => _pairingDismissed;

  /// Stable identity for this install, generated locally on first launch.
  ///
  /// Locally rather than server-assigned because the phone records readings
  /// before it has ever reached the network — which, for a device intended for
  /// rural use, is the normal case. An id issued by the server on first contact
  /// would leave everything measured beforehand with nothing to attach it to.
  ///
  /// Note this is a pseudonymous key, not a name: on its own it identifies a
  /// device, and the display name is kept in the profile alongside the other
  /// personal fields.
  ///
  /// With multiple profiles ([ProfileRegistry]) this is the *active* person's
  /// id; [switchPatient] moves it. The stored `patient_id` preference stays at
  /// its original minted value — the registry owns the pointer, so writing here
  /// too would be a second source of truth that could disagree after a crash.
  String get patientId => _patientId;

  /// Re-points identity at another profile's patient id.
  ///
  /// Not persisted (see [patientId]); the caller persists the choice in the
  /// registry. Listeners fire so SyncService re-enrols under the new identity.
  Future<void> switchPatient(String id) async {
    if (id == _patientId) return;
    _patientId = id;
    notifyListeners();
  }

  /// Whether readings are uploaded to the server.
  ///
  /// The local archive fills regardless. Turning this off stops the backup, not
  /// the monitoring — health data leaving the device is the part that needs
  /// consent under RA 10173, and a switch that also stopped local recording would
  /// make privacy and function the same choice.
  bool get backupEnabled => _backupEnabled;

  DateTime? get lastSyncAt => _lastSyncAt;

  /// False when the store is unavailable, so the UI can say so rather than
  /// silently forgetting the address on next launch.
  bool get isPersistent => _prefs != null;

  /// Loads settings, falling back to in-memory defaults if the store is unusable.
  ///
  /// A corrupt or full preferences store must not prevent the app from starting.
  /// Launching with a default address the user can correct in Settings is strictly
  /// better than a crash on a health-monitoring app.
  ///
  /// Requires `WidgetsFlutterBinding.ensureInitialized()` to have run first —
  /// SharedPreferences is a platform channel call.
  static Future<AppSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Minted once and then reused for the life of the install. Regenerating it
      // would orphan every reading already backed up under the previous id — the
      // dashboard would show the same person as two patients, each with half a
      // history.
      var patientId = prefs.getString(_patientIdKey);
      if (patientId == null || patientId.length < 8) {
        patientId = generateClientId();
        await prefs.setString(_patientIdKey, patientId);
      }

      final settings = AppSettings._(
        prefs,
        prefs.getString(_apiBaseUrlKey) ?? platformDefaultBaseUrl(),
        patientId,
      );
      settings._watchPaired = prefs.getBool(_watchPairedKey) ?? false;
      settings._pairingDismissed = prefs.getBool(_pairingDismissedKey) ?? false;
      settings._backupEnabled = prefs.getBool(_backupEnabledKey) ?? true;
      final lastSync = prefs.getInt(_lastSyncKey);
      if (lastSync != null) {
        settings._lastSyncAt =
            DateTime.fromMillisecondsSinceEpoch(lastSync, isUtc: true);
      }
      return settings;
    } on Exception catch (error, stack) {
      debugPrint(
        'AppSettings: preferences unavailable, using defaults. $error',
      );
      debugPrintStack(stackTrace: stack);
      // A session-only id. Readings still archive and still upload; they land
      // under a fresh patient each launch, which is visibly wrong on the
      // dashboard rather than silently lost — and `isPersistent` is false, so
      // the settings screen says so.
      return AppSettings._(null, platformDefaultBaseUrl(), generateClientId());
    }
  }

  Future<void> setApiBaseUrl(String raw) async {
    final normalized = normalizeBaseUrl(raw);
    if (normalized == _apiBaseUrl) return;
    _apiBaseUrl = normalized;
    await _prefs?.setString(_apiBaseUrlKey, normalized);
    notifyListeners();
  }

  /// Extracts the IPv4 address from user input and stores the full request URL.
  ///
  /// Accepts what a person would actually type into a bare-IP field:
  /// `192.168.1.11`, `192.168.1.11:8000`, `http://192.168.1.11:8000`.
  /// Everything except the four octets is discarded and the fixed port is applied.
  Future<bool> setApiIpAddress(String raw) async {
    final ip = _extractIpv4(raw);
    if (ip == null) return false;
    await setApiBaseUrl('http://$ip:$defaultApiPort');
    return true;
  }

  /// Pulls the first dotted-decimal pattern out of [raw], or returns null.
  static String? _extractIpv4(String raw) {
    final match = RegExp(r'(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})')
        .firstMatch(raw.trim());
    if (match == null) return null;
    final parts = [match.group(1)!, match.group(2)!, match.group(3)!, match.group(4)!];
    final valid = parts.every((p) => int.parse(p) <= 255);
    return valid ? parts.join('.') : null;
  }

  Future<void> resetApiBaseUrl() async {
    _apiBaseUrl = platformDefaultBaseUrl();
    await _prefs?.remove(_apiBaseUrlKey);
    notifyListeners();
  }

  Future<void> setWatchPaired(bool paired) async {
    if (paired == _watchPaired) return;
    await _prefs?.setBool(_watchPairedKey, paired);
    _watchPaired = paired;
    // A completed pairing supersedes a past skip: the user came back and
    // finished what they put off.
    if (paired && _pairingDismissed) {
      await setPairingDismissed(false);
    }
    notifyListeners();
  }

  /// Records (or clears) the "set up later" choice from the pairing screen.
  Future<void> setPairingDismissed(bool dismissed) async {
    if (dismissed == _pairingDismissed) return;
    _pairingDismissed = dismissed;
    await _prefs?.setBool(_pairingDismissedKey, dismissed);
    notifyListeners();
  }

  Future<void> setBackupEnabled(bool enabled) async {
    if (enabled == _backupEnabled) return;
    _backupEnabled = enabled;
    await _prefs?.setBool(_backupEnabledKey, enabled);
    notifyListeners();
  }

  /// Recorded after a successful upload so Settings can report when the archive
  /// last reached the server — the difference between "backed up" and "recording
  /// into a void" is not otherwise visible to the user.
  Future<void> recordSync(DateTime at) async {
    _lastSyncAt = at;
    await _prefs?.setInt(_lastSyncKey, at.toUtc().millisecondsSinceEpoch);
    notifyListeners();
  }

  /// Best guess for the current platform, used until the user sets one.
  ///
  /// A `--dart-define=MECAI_API_URL=...` build wins, so CI and demo builds can
  /// pin an address without touching the stored setting.
  static String platformDefaultBaseUrl() {
    const override = String.fromEnvironment('MECAI_API_URL');
    if (override.isNotEmpty) return normalizeBaseUrl(override);
    if (!kIsWeb && Platform.isAndroid) return 'http://10.0.2.2:$defaultApiPort';
    return 'http://127.0.0.1:$defaultApiPort';
  }

  /// Accepts what a person would actually type.
  ///
  /// `192.168.1.11` → `http://192.168.1.11:8000`
  /// `192.168.1.11:9000` → `http://192.168.1.11:9000`
  /// `https://api.example.com` → left alone (explicit scheme, implicit port)
  ///
  /// Being forgiving here matters — the alternative is a user typing a bare IP,
  /// getting a silent connection failure, and having no way to tell that the
  /// missing `http://` was the problem.
  static String normalizeBaseUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return platformDefaultBaseUrl();

    // Strip a trailing slash so path concatenation never doubles up.
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }

    final hasScheme =
        value.startsWith('http://') || value.startsWith('https://');
    if (!hasScheme) value = 'http://$value';

    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return value;

    // Only add a port for plain http — https on 443 is already correct, and
    // appending :8000 to a hosted URL would break it.
    if (!uri.hasPort && uri.scheme == 'http') {
      return uri.replace(port: defaultApiPort).toString();
    }
    return uri.toString();
  }
}
