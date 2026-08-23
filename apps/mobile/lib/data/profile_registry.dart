/// Registry of the people this install serves, and who is wearing the watch now.
///
/// One phone can monitor more than one person — a shared family device, or a
/// community health worker's phone covering a household. Each profile is a
/// distinct person with their own questionnaire, display name, emergency
/// contacts, readings archive, and — critically — their own [activeId], which is
/// the `patient_id` every reading is uploaded under. Two people on one phone
/// therefore appear as two patients on the clinician dashboard, not as one
/// blended history.
///
/// ### What this class owns (and only this)
///
/// The *pointer*: which profiles exist and which one is active. The data itself
/// stays in the per-profile stores ([ProfileStore], [EmergencyContacts],
/// [ReadingStore]), which namespace their keys by profile id. This split means
/// switching is just: persist a new pointer here, reload the stores.
///
/// ### Migration from the single-profile era
///
/// Installs before multi-profile existed one person under un-namespaced keys,
/// with the identity in AppSettings' `patient_id`. On first launch of this code
/// that id is adopted as the first profile (`legacyId`), so nothing is lost or
/// re-identified: the same patient id keeps its dashboard history, and the
/// per-profile stores read through to the legacy keys until the user saves over
/// them. See each store's `load` for the read-through rule.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reading_store.dart' show generateClientId;

class ProfileRegistry extends ChangeNotifier {
  ProfileRegistry._(
    this._prefs,
    this._ids,
    this._activeId,
    this.legacyId,
  );

  static const _indexKey = 'profiles_index';
  static const _activeKey = 'profiles_active';
  static const _legacyKey = 'profiles_legacy_id';
  static const _dbFileKeyPrefix = 'profile.dbfile.';

  /// Archive filename of the profile migrated from a single-profile install.
  ///
  /// That install's readings already live in the default database; pointing the
  /// adopted profile at it is what makes migration invisible. Profiles created
  /// afterwards get their own file — see [_dbFileFor].
  static const legacyDbFile = 'mecai_readings.db';

  final SharedPreferences? _prefs;
  List<String> _ids;
  String _activeId;

  /// The profile id adopted from a pre-multi-profile install, if this instance
  /// performed (or loaded) that migration. Persisted because the per-profile
  /// stores need it on *every* launch, not just the first: an unsaved legacy
  /// field must keep reading through to the old key indefinitely.
  final String? legacyId;

  List<String> get ids => List.unmodifiable(_ids);
  String get activeId => _activeId;
  int get count => _ids.length;
  bool get isPersistent => _prefs != null;

  /// Loads the registry, migrating a single-profile install when found.
  ///
  /// [seedPatientId] is the identity AppSettings minted for this install. A
  /// registry that has never been written adopts it as profile #1 rather than
  /// minting a competing id — two ids would split one person's dashboard
  /// history across two rows.
  static Future<ProfileRegistry> load({String? seedPatientId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final raw = prefs.getString(_indexKey);
      if (raw != null) {
        final ids = (jsonDecode(raw) as List<dynamic>).cast<String>();
        final active =
            prefs.getString(_activeKey) ?? (ids.isNotEmpty ? ids.first : '');
        return ProfileRegistry._(prefs, ids, active, prefs.getString(_legacyKey));
      }

      // First run under multi-profile. Adopt the existing identity, or mint one
      // for a genuinely fresh install.
      var adopted = seedPatientId;
      if (adopted == null || adopted.length < 8) {
        adopted = generateClientId();
      }

      await prefs.setString(_indexKey, jsonEncode([adopted]));
      await prefs.setString(_activeKey, adopted);
      await prefs.setString(_legacyKey, adopted);
      await prefs.setString('$_dbFileKeyPrefix$adopted', legacyDbFile);

      // Carry the display name across once, so the switcher can show it for
      // this profile even while it is not the active one. The rest of the
      // questionnaire needs no copy: ProfileStore reads through to the legacy
      // keys whenever the namespaced ones are unset.
      final name = prefs.getString('profile_display_name');
      if (name != null) {
        await prefs.setString('profile.$adopted.display_name', name);
      }

      return ProfileRegistry._(prefs, [adopted], adopted, adopted);
    } on Object catch (error) {
      debugPrint('ProfileRegistry: store unavailable, single session profile. $error');
      final id =
          (seedPatientId != null && seedPatientId.length >= 8)
              ? seedPatientId
              : generateClientId();
      return ProfileRegistry._(null, [id], id, seedPatientId);
    }
  }

  /// Adds a profile and makes it active. Returns the new id.
  Future<String> create() async {
    final id = generateClientId();
    _ids = [..._ids, id];
    _activeId = id;
    await _persist();
    notifyListeners();
    return id;
  }

  /// Points the app at another existing profile.
  Future<void> switchTo(String id) async {
    if (!_ids.contains(id) || id == _activeId) return;
    _activeId = id;
    await _persist();
    notifyListeners();
  }

  /// The archive filename this profile's readings live in.
  ///
  /// Recorded at creation/migration so the mapping never changes: a profile
  /// whose database file moved between launches would lose its history.
  String dbFileFor(String id) =>
      _prefs?.getString('$_dbFileKeyPrefix$id') ?? _dbFileFor(id);

  static String _dbFileFor(String id) =>
      'mecai_readings_${id.substring(0, 8)}.db';

  /// Display name for the roster, without loading a full [ProfileStore].
  ///
  /// Reads only the one string the switcher list needs. Empty when unset — the
  /// caller falls back to a label derived from the id, exactly as
  /// [ProfileStore.resolvedDisplayName] does for the active profile.
  String displayNameOf(String id) {
    final prefs = _prefs;
    if (prefs == null) return '';
    return prefs.getString('profile.$id.display_name') ??
        (id == legacyId ? prefs.getString('profile_display_name') ?? '' : '');
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(_indexKey, jsonEncode(_ids));
    await prefs.setString(_activeKey, _activeId);
    // First write wins. Re-recording a mapping would be fatal for the adopted
    // profile: its readings live under [legacyDbFile], and pointing it at the
    // derived per-profile name instead would hide every reading it owns.
    final key = '$_dbFileKeyPrefix$_activeId';
    if (!prefs.containsKey(key)) {
      await prefs.setString(key, _dbFileFor(_activeId));
    }
  }
}
