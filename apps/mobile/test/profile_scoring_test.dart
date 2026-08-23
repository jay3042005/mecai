/// The profile questionnaire is what makes a score possible at all.
///
/// The MEC-AI watch streams heart rate, SpO2 and temperature — it has no cuff.
/// Framingham needs a systolic pressure, so before the profile could supply a
/// baseline the ring was *permanently* stuck on "Incomplete profile" and the
/// score could never be computed on real hardware. These tests pin that fix.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/data/local_risk_engine.dart';
import 'package:mecai_mobile/design/tokens.dart';
import 'package:mecai_mobile/models/vitals.dart';

/// What the watch actually reports: no blood pressure.
final _watchReading = VitalsReading(
  heartRateBpm: 72,
  spo2Pct: 98,
  ambientTempC: 28,
  measuredAt: DateTime(2026, 8, 20),
);

const _lipidsOnly = RiskProfile(
  age: 55,
  sexMale: true,
  smoker: false,
  diabetic: false,
  totalCholesterolMgdl: 213,
  hdlCholesterolMgdl: 50,
);

void main() {
  group('systolic pressure', () {
    test('a lipid panel alone cannot be scored on cuffless hardware', () {
      final r = evaluateRiskLocally(profile: _lipidsOnly, reading: _watchReading);

      expect(r.assessment.band, MecRiskBand.unknown);
      expect(r.assessment.valuePct, isNull);
      expect(r.assessment.missingFields, contains('systolic_mmhg'));
    });

    test('says how to supply the missing pressure', () {
      final r = evaluateRiskLocally(profile: _lipidsOnly, reading: _watchReading);

      // A dead end is not an acceptable state — the note names the fix.
      expect(
        r.notes.any((n) => n.contains('profile') && n.contains('systolic')),
        isTrue,
      );
    });

    test('a profile baseline completes the model', () {
      final profile = _lipidsOnly.copyWith(baselineSystolicMmHg: 128);
      final r = evaluateRiskLocally(profile: profile, reading: _watchReading);

      expect(r.assessment.confidence, Confidence.complete);
      expect(r.assessment.band, MecRiskBand.moderate);
      expect(r.assessment.valuePct, closeTo(11.5, 0.1));
      expect(r.assessment.missingFields, isEmpty);
    });

    test('a typed-in pressure is never credited to the device', () {
      final profile = _lipidsOnly.copyWith(baselineSystolicMmHg: 128);
      final r = evaluateRiskLocally(profile: profile, reading: _watchReading);

      final sbp = r.assessment.factors
          .firstWhere((f) => f.name == 'Systolic blood pressure');

      // The user is entitled to know which inputs were measured and which they
      // supplied, so a questionnaire value must not claim FactorSource.device.
      expect(sbp.source, FactorSource.profile);
    });

    test('a live cuff reading still wins, and is credited to the device', () {
      final profile = _lipidsOnly.copyWith(baselineSystolicMmHg: 128);
      final cuffed = VitalsReading(
        heartRateBpm: 72,
        spo2Pct: 98,
        ambientTempC: 28,
        systolicMmHg: 150,
        diastolicMmHg: 95,
        measuredAt: DateTime(2026, 8, 20),
      );

      final r = evaluateRiskLocally(profile: profile, reading: cuffed);
      final sbp = r.assessment.factors
          .firstWhere((f) => f.name == 'Systolic blood pressure');

      expect(sbp.displayValue, '150 mmHg');
      expect(sbp.source, FactorSource.device);
    });
  });

  group('completeness', () {
    test('names every field the model still needs', () {
      const bare = RiskProfile(
        age: 45,
        sexMale: true,
        smoker: false,
        diabetic: false,
      );

      expect(bare.isCompleteForScoring, isFalse);
      expect(bare.missingForScoring, <String>[
        'total_cholesterol_mgdl',
        'hdl_cholesterol_mgdl',
        'systolic_mmhg',
      ]);
    });

    test('is complete only with both lipids and a pressure', () {
      expect(_lipidsOnly.isCompleteForScoring, isFalse);
      expect(
        _lipidsOnly.copyWith(baselineSystolicMmHg: 128).isCompleteForScoring,
        isTrue,
      );
    });

    test('the baseline reaches the server payload', () {
      final json = _lipidsOnly.copyWith(baselineSystolicMmHg: 128).toJson();
      expect(json['baseline_systolic_mmhg'], 128.0);
    });
  });
}
