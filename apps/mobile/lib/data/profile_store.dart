/// Persisted health profile — the questionnaire inputs the watch cannot sense.
///
/// Separate from [AppSettings] because it answers a different question: that class
/// holds *how the app connects*, this one holds *who the user is*. Both sit on
/// SharedPreferences, which is a singleton, so loading two stores is cheap.
///
/// Age and sex have no sensible null: a profile with no age cannot be scored and
/// cannot be displayed either, so they default to the values the model treats as
/// mid-population and the user is asked to correct them. The clinical measurements
/// stay null until entered — a fabricated cholesterol would produce a
/// confident-looking figure with nothing behind it, which is the reasoning the
/// service states in its own `RiskProfile` docstring.
library;

import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/vitals.dart';

class ProfileStore extends ChangeNotifier {
  ProfileStore._(this._prefs, this._profile, {required String? id, String? legacyOf})
      : _id = id,
        _legacyFallback = id != null && id == legacyOf;

  /// Null on the pre-multi-profile storage layout: every key is used exactly as
  /// it always was, so callers that do not care about profiles (tests, tools)
  /// keep working untouched.
  final String? _id;

  /// Whether unset fields may read through to the un-namespaced keys.
  ///
  /// True only for the profile adopted from a single-profile install — see
  /// [ProfileRegistry.legacyId]. It lets an install migrate without copying or
  /// rewriting anything: values the user has not re-saved still come from where
  /// they were written years ago, and a save moves them forward permanently.
  final bool _legacyFallback;

  static const _legacyPrefix = 'profile_';

  // Field suffixes. Namespaced keys are 'profile.<id>.<suffix>'; the legacy
  // layout was 'profile_<suffix>'.
  static const _displayNameSuffix = 'display_name';
  static const _ageSuffix = 'age';
  static const _sexMaleSuffix = 'sex_male';
  static const _smokerSuffix = 'smoker';
  static const _diabeticSuffix = 'diabetic';
  static const _bpMedSuffix = 'on_bp_medication';
  static const _totalCholSuffix = 'total_cholesterol_mgdl';
  static const _hdlCholSuffix = 'hdl_cholesterol_mgdl';
  static const _systolicSuffix = 'baseline_systolic_mmhg';
  static const _diastolicSuffix = 'baseline_diastolic_mmhg';
  static const _familyHistorySuffix = 'family_history_cvd';
  static const _savedSuffix = 'saved';

  String _key(String suffix) =>
      _id == null ? '$_legacyPrefix$suffix' : 'profile.$_id.$suffix';

  /// Null when preferences could not be opened. The profile then works for the
  /// session but does not survive a restart.
  final SharedPreferences? _prefs;

  RiskProfile _profile;
  bool _saved = false;
  String _displayName = '';

  RiskProfile get profile => _profile;

  /// The name shown on the clinician dashboard beside this patient's readings.
  ///
  /// Empty until the user enters one, and [resolvedDisplayName] then falls back to
  /// a label derived from the device id. A blank roster entry would be worse than
  /// a pseudonymous one — a clinician cannot act on a row they cannot identify.
  String get displayName => _displayName;

  /// [displayName], or a readable stand-in built from [patientId].
  String resolvedDisplayName(String patientId) => _displayName.trim().isEmpty
      ? 'Patient ${patientId.replaceAll('-', '').substring(0, 8)}'
      : _displayName.trim();

  Future<void> setDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed == _displayName) return;
    _displayName = trimmed;
    if (trimmed.isEmpty) {
      await _prefs?.remove(_key(_displayNameSuffix));
    } else {
      await _prefs?.setString(_key(_displayNameSuffix), trimmed);
    }
    notifyListeners();
  }

  /// False until the user has actually filled the questionnaire in.
  ///
  /// Distinguishes "defaults nobody has looked at" from "a real profile that
  /// happens to be missing a lipid panel", which the UI needs in order to say
  /// something useful.
  bool get hasBeenEdited => _saved;

  bool get isPersistent => _prefs != null;

  /// A profile with no clinical measurements — the honest starting point.
  static const empty = RiskProfile(
    age: 45,
    sexMale: true,
    smoker: false,
    diabetic: false,
  );

  /// Loads the profile for [id], or the legacy un-namespaced layout when null.
  ///
  /// [legacyOf] enables read-through to that legacy layout for the one profile
  /// adopted from it — see [_legacyFallback]. Every write goes to the
  /// namespaced key, so a save permanently supersedes whatever was migrated.
  static Future<ProfileStore> load(String? id, {String? legacyOf}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final store = ProfileStore._(prefs, empty, id: id, legacyOf: legacyOf);

      final loaded = RiskProfile(
        age: store._read<int>(_ageSuffix) ?? empty.age,
        sexMale: store._read<bool>(_sexMaleSuffix) ?? empty.sexMale,
        smoker: store._read<bool>(_smokerSuffix) ?? empty.smoker,
        diabetic: store._read<bool>(_diabeticSuffix) ?? empty.diabetic,
        onBpMedication: store._read<bool>(_bpMedSuffix) ?? false,
        totalCholesterolMgdl: store._read<double>(_totalCholSuffix),
        hdlCholesterolMgdl: store._read<double>(_hdlCholSuffix),
        baselineSystolicMmHg: store._read<double>(_systolicSuffix),
        baselineDiastolicMmHg: store._read<double>(_diastolicSuffix),
        familyHistoryCvd: store._read<bool>(_familyHistorySuffix) ?? false,
      );
      // Rebuild rather than mutate: [_profile] is not written outside save().
      return ProfileStore._(
        prefs,
        loaded,
        id: id,
        legacyOf: legacyOf,
      )
        .._saved = store._read<bool>(_savedSuffix) ?? false
        .._displayName = store._read<String>(_displayNameSuffix) ?? '';
    } on Exception catch (error) {
      // A health app must still start with an unusable preferences store.
      debugPrint('ProfileStore: preferences unavailable, using defaults. $error');
      return ProfileStore._(null, empty, id: id, legacyOf: legacyOf);
    }
  }

  /// Field value from this profile's namespace, falling back to the legacy
  /// layout when this profile was adopted from it and never re-saved.
  T? _read<T>(String suffix) {
    final prefs = _prefs;
    if (prefs == null) return null;
    final own = switch (T) {
      const (int) => prefs.getInt(_key(suffix)) as T?,
      const (bool) => prefs.getBool(_key(suffix)) as T?,
      const (double) => prefs.getDouble(_key(suffix)) as T?,
      const (String) => prefs.getString(_key(suffix)) as T?,
      _ => throw StateError('unsupported profile field type $T'),
    };
    if (own != null || !_legacyFallback) return own;
    return switch (T) {
      const (int) => prefs.getInt('$_legacyPrefix$suffix') as T?,
      const (bool) => prefs.getBool('$_legacyPrefix$suffix') as T?,
      const (double) => prefs.getDouble('$_legacyPrefix$suffix') as T?,
      const (String) => prefs.getString('$_legacyPrefix$suffix') as T?,
      _ => null,
    };
  }

  Future<void> save(RiskProfile next) async {
    _profile = next;
    _saved = true;

    final prefs = _prefs;
    if (prefs != null) {
      await prefs.setInt(_key(_ageSuffix), next.age);
      await prefs.setBool(_key(_sexMaleSuffix), next.sexMale);
      await prefs.setBool(_key(_smokerSuffix), next.smoker);
      await prefs.setBool(_key(_diabeticSuffix), next.diabetic);
      await prefs.setBool(_key(_bpMedSuffix), next.onBpMedication);
      await prefs.setBool(_key(_familyHistorySuffix), next.familyHistoryCvd);
      await prefs.setBool(_key(_savedSuffix), true);
      // A cleared measurement must remove the key, not leave the old value.
      await _putOrClear(prefs, _key(_totalCholSuffix), next.totalCholesterolMgdl);
      await _putOrClear(prefs, _key(_hdlCholSuffix), next.hdlCholesterolMgdl);
      await _putOrClear(prefs, _key(_systolicSuffix), next.baselineSystolicMmHg);
      await _putOrClear(prefs, _key(_diastolicSuffix), next.baselineDiastolicMmHg);
    }

    notifyListeners();
  }

  static Future<void> _putOrClear(
    SharedPreferences prefs,
    String key,
    double? value,
  ) async {
    if (value == null) {
      await prefs.remove(key);
    } else {
      await prefs.setDouble(key, value);
    }
  }
}
