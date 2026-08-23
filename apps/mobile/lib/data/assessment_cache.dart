/// Persists the last **server-computed** ten-year assessment.
///
/// ### Why the server's figure is the one that gets cached
///
/// The ten-year score is the server's to compute: the Framingham coefficients live
/// in `services/api/src/mecai_api/risk/`, and that is deliberately the only place
/// they live. The on-device engine in `local_risk_engine.dart` exists so the app
/// is not blank on first launch, but when the two are available the server's is
/// authoritative.
///
/// So when a score arrives from the server it is written here, and when the server
/// is unreachable the app shows **this stored figure, unchanged**, labelled with
/// how old it is. The alternative — recomputing locally on every disconnection —
/// makes the number the user sees flicker between two implementations depending on
/// signal strength, and a ten-year risk estimate that changes when you walk out of
/// Wi-Fi range is not a number anyone should trust.
///
/// ### What is deliberately NOT cached
///
/// **Acute flags.** Those are evaluated live, on-device, from the current reading,
/// every time — see `acute_flags.dart`. Serving a cached SpO2 warning would be
/// showing a stale emergency; worse, a cached *absence* of one would suppress a
/// live emergency. The cache holds the chronic estimate only.
///
/// ### Invalidation
///
/// The cache records a fingerprint of the profile it was computed from. Editing the
/// questionnaire changes the fingerprint and the stored figure is then reported as
/// stale rather than shown as current — a score computed from last month's
/// cholesterol is not an answer about today's profile.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/vitals.dart';

@immutable
class CachedAssessment {
  const CachedAssessment({
    required this.assessment,
    required this.computedAt,
    required this.profileFingerprint,
    required this.notes,
  });

  final RiskAssessment assessment;

  /// When the server produced this figure — not when it was last displayed.
  final DateTime computedAt;

  /// Identifies the questionnaire the figure was computed from, so a profile edit
  /// can mark it stale instead of silently re-labelling an old answer as current.
  final String profileFingerprint;

  final List<String> notes;

  /// Whether this figure still describes [profile].
  bool matches(RiskProfile profile) =>
      profileFingerprint == AssessmentCache.fingerprint(profile);

  Duration get age => DateTime.now().toUtc().difference(computedAt.toUtc());

  Map<String, dynamic> toJson() => <String, dynamic>{
        'computed_at': computedAt.toUtc().toIso8601String(),
        'profile_fingerprint': profileFingerprint,
        'notes': notes,
        'assessment': <String, dynamic>{
          'band': assessment.band.name,
          'value_pct': assessment.valuePct,
          'horizon': assessment.horizon,
          'confidence':
              assessment.confidence == Confidence.complete ? 'complete' : 'incomplete',
          'missing_fields': assessment.missingFields,
          'model_version': assessment.modelVersion,
          'disclaimer': assessment.disclaimer,
          'factors': [
            for (final factor in assessment.factors)
              <String, dynamic>{
                'name': factor.name,
                'display_value': factor.displayValue,
                'contribution': factor.contribution,
                'source': factor.source == FactorSource.device ? 'device' : 'profile',
                'modifiable': factor.modifiable,
              },
          ],
        },
      };

  static CachedAssessment? fromJson(Map<String, dynamic> json) {
    try {
      return CachedAssessment(
        assessment: RiskAssessment.fromJson(
          json['assessment'] as Map<String, dynamic>,
        ),
        computedAt: DateTime.parse(json['computed_at'] as String),
        profileFingerprint: json['profile_fingerprint'] as String? ?? '',
        notes: (json['notes'] as List<dynamic>? ?? const [])
            .cast<String>()
            .toList(growable: false),
      );
    } on Object catch (error) {
      // A cache written by an older build must not crash the app. Discarding it
      // costs one server round trip; failing to parse it would cost the launch.
      debugPrint('AssessmentCache: discarding unreadable entry. $error');
      return null;
    }
  }
}

class AssessmentCache extends ChangeNotifier {
  AssessmentCache._(this._prefs, this._cached);

  static const _key = 'last_server_assessment';

  final SharedPreferences? _prefs;
  CachedAssessment? _cached;

  /// The last figure the server produced, or null if it has never been reached.
  CachedAssessment? get cached => _cached;

  bool get isPersistent => _prefs != null;

  static Future<AssessmentCache> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return AssessmentCache._(prefs, null);
      return AssessmentCache._(
        prefs,
        CachedAssessment.fromJson(jsonDecode(raw) as Map<String, dynamic>),
      );
    } on Object catch (error) {
      debugPrint('AssessmentCache: store unavailable. $error');
      return AssessmentCache._(null, null);
    }
  }

  /// Stores a figure the server computed.
  ///
  /// Only complete assessments are kept. An `unknown` band carries no figure, so
  /// caching one would overwrite a real score with the absence of one — and then
  /// a single request made before the profile was filled in would erase a
  /// perfectly good stored result.
  Future<void> save({
    required RiskAssessment assessment,
    required RiskProfile profile,
    List<String> notes = const [],
  }) async {
    if (assessment.confidence != Confidence.complete) return;

    final entry = CachedAssessment(
      assessment: assessment,
      computedAt: DateTime.now().toUtc(),
      profileFingerprint: fingerprint(profile),
      notes: notes,
    );
    _cached = entry;
    await _prefs?.setString(_key, jsonEncode(entry.toJson()));
    notifyListeners();
  }

  Future<void> clear() async {
    _cached = null;
    await _prefs?.remove(_key);
    notifyListeners();
  }

  /// Identity of the questionnaire inputs the model actually consumes.
  ///
  /// Only the scoring inputs, so cosmetic edits do not invalidate a good figure:
  /// changing a display name or toggling family history — which Framingham does
  /// not use — should not mark the score stale.
  static String fingerprint(RiskProfile profile) => [
        profile.age,
        profile.sexMale ? 'm' : 'f',
        profile.smoker ? 's' : '-',
        profile.diabetic ? 'd' : '-',
        profile.onBpMedication ? 'rx' : '-',
        profile.totalCholesterolMgdl?.toStringAsFixed(1) ?? '-',
        profile.hdlCholesterolMgdl?.toStringAsFixed(1) ?? '-',
        profile.baselineSystolicMmHg?.toStringAsFixed(1) ?? '-',
      ].join('|');
}
