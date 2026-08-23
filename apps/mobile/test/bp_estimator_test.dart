/// The cuffless BP estimator.
///
/// The guards that matter, in order of what they prevent:
/// 1. No cuff baseline → no figure at all, rather than a population average
///    presented next to this user's real heart rate.
/// 2. The estimate never leaks into `VitalsReading`, so it cannot reach the acute
///    alert engine or the upload payload as if it were measured.
/// 3. Output stays physiologically shaped (systolic > diastolic, plausible range)
///    even at the extremes of its inputs.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/data/acute_flags.dart';
import 'package:mecai_mobile/data/bp_estimator.dart';
import 'package:mecai_mobile/design/tokens.dart';
import 'package:mecai_mobile/models/vitals.dart';

const _withBaseline = RiskProfile(
  age: 45,
  sexMale: true,
  smoker: false,
  diabetic: false,
  baselineSystolicMmHg: 120,
  baselineDiastolicMmHg: 80,
);

const _noBaseline = RiskProfile(
  age: 45,
  sexMale: true,
  smoker: false,
  diabetic: false,
);

VitalsReading _reading({double? hr, double? spo2, bool motion = false}) =>
    VitalsReading(
      heartRateBpm: hr,
      spo2Pct: spo2,
      measuredAt: DateTime(2026),
      motionArtifact: motion,
    );

/// Enough samples at [bpm] for `restingHeartRate` to return a value.
List<VitalsReading> _history(double bpm, {int count = 60}) =>
    List.generate(count, (_) => _reading(hr: bpm, spo2: 98));

void main() {
  group('refuses to guess', () {
    test('no cuff baseline means no estimate', () {
      final e = estimateBloodPressure(
        profile: _noBaseline,
        reading: _reading(hr: 80, spo2: 98),
      );
      expect(e.hasEstimate, isFalse);
      expect(e.display, VitalsReading.absent);
      expect(e.problem, contains('cuff'));
    });

    test('a systolic without a diastolic is still no estimate', () {
      final e = estimateBloodPressure(
        profile: _withBaseline.copyWith(baselineDiastolicMmHg: null),
        reading: _reading(hr: 80, spo2: 98),
      );
      // copyWith cannot null a field, so assert the guard directly instead.
      expect(
        estimateBloodPressure(
          profile: const RiskProfile(
            age: 45,
            sexMale: true,
            smoker: false,
            diabetic: false,
            baselineSystolicMmHg: 120,
          ),
          reading: _reading(hr: 80, spo2: 98),
        ).hasEstimate,
        isFalse,
      );
      expect(e.hasEstimate, isTrue); // sanity: copyWith kept the diastolic
    });

    test('no heart rate means no estimate', () {
      final e = estimateBloodPressure(
        profile: _withBaseline,
        reading: _reading(spo2: 98),
      );
      expect(e.hasEstimate, isFalse);
      expect(e.problem, contains('heart rate'));
    });

    test('no reading at all means no estimate', () {
      final e = estimateBloodPressure(profile: _withBaseline, reading: null);
      expect(e.hasEstimate, isFalse);
    });
  });

  group('direction', () {
    test('at the resting rate it returns the baseline', () {
      final e = estimateBloodPressure(
        profile: _withBaseline,
        reading: _reading(hr: 70, spo2: 98),
        history: _history(70),
      );
      expect(e.systolicMmHg, closeTo(120, 0.001));
      expect(e.diastolicMmHg, closeTo(80, 0.001));
      expect(e.confidence, BpConfidence.good);
    });

    test('a raised heart rate raises the estimate', () {
      final e = estimateBloodPressure(
        profile: _withBaseline,
        reading: _reading(hr: 100, spo2: 98),
        history: _history(70),
      );
      expect(e.systolicMmHg!, greaterThan(120));
      // Diastolic moves less than systolic — the whole point of the two
      // coefficients. A model where both moved together would be wrong.
      expect(
        e.diastolicMmHg! - 80,
        lessThan(e.systolicMmHg! - 120),
      );
    });

    test('low SpO2 raises the estimate', () {
      final normal = estimateBloodPressure(
        profile: _withBaseline,
        reading: _reading(hr: 70, spo2: 98),
        history: _history(70),
      );
      final hypoxic = estimateBloodPressure(
        profile: _withBaseline,
        reading: _reading(hr: 70, spo2: 88),
        history: _history(70),
      );
      expect(hypoxic.systolicMmHg!, greaterThan(normal.systolicMmHg!));
    });

    test('SpO2 above the warning line contributes nothing', () {
      final a = estimateBloodPressure(
        profile: _withBaseline,
        reading: _reading(hr: 70, spo2: 96),
        history: _history(70),
      );
      final b = estimateBloodPressure(
        profile: _withBaseline,
        reading: _reading(hr: 70, spo2: 100),
        history: _history(70),
      );
      expect(a.systolicMmHg, closeTo(b.systolicMmHg!, 0.001));
    });
  });

  group('stays physiological', () {
    test('systolic stays above diastolic by at least 20 at any heart rate', () {
      for (var hr = MecPlausible.heartRateMin;
          hr <= MecPlausible.heartRateMax;
          hr += 5) {
        final e = estimateBloodPressure(
          profile: _withBaseline,
          reading: _reading(hr: hr, spo2: 85),
          history: _history(70),
        );
        expect(
          e.systolicMmHg! - e.diastolicMmHg!,
          greaterThanOrEqualTo(20),
          reason: 'pulse pressure collapsed at $hr bpm',
        );
      }
    });

    test('output stays inside the plausibility bounds', () {
      final extreme = estimateBloodPressure(
        profile: const RiskProfile(
          age: 45,
          sexMale: true,
          smoker: false,
          diabetic: false,
          baselineSystolicMmHg: MecPlausible.systolicMax,
          baselineDiastolicMmHg: MecPlausible.diastolicMax,
        ),
        reading: _reading(hr: 250, spo2: 50),
        history: _history(70),
      );
      expect(extreme.systolicMmHg!,
          lessThanOrEqualTo(MecPlausible.systolicMax));
      expect(extreme.diastolicMmHg!,
          lessThanOrEqualTo(MecPlausible.diastolicMax));
    });
  });

  group('confidence', () {
    test('a motion-affected reading is always poor', () {
      final e = estimateBloodPressure(
        profile: _withBaseline,
        reading: _reading(hr: 70, spo2: 98, motion: true),
        history: _history(70),
      );
      expect(e.confidence, BpConfidence.poor);
      expect(e.motionAffected, isTrue);
    });

    test('far from resting is poor', () {
      final e = estimateBloodPressure(
        profile: _withBaseline,
        reading: _reading(hr: 140, spo2: 98),
        history: _history(70),
      );
      expect(e.confidence, BpConfidence.poor);
    });

    test('without derived resting history it is never better than fair', () {
      final e = estimateBloodPressure(
        profile: _withBaseline,
        reading: _reading(hr: 70, spo2: 98),
      );
      expect(e.confidence, BpConfidence.fair);
    });
  });

  group('resting heart rate', () {
    test('too little history yields null', () {
      expect(restingHeartRate(_history(70, count: 10)), isNull);
    });

    test('a single noisy low sample does not become the resting rate', () {
      final history = [..._history(70), _reading(hr: 30, spo2: 98)];
      // A minimum would return 30 here. The 10th percentile does not.
      expect(restingHeartRate(history), greaterThan(60));
    });

    test('implausible rates are excluded', () {
      final history = [
        ..._history(70),
        ...List.generate(20, (_) => _reading(hr: 400, spo2: 98)),
      ];
      expect(restingHeartRate(history), closeTo(70, 0.001));
    });
  });

  group('never becomes a measurement', () {
    test('an estimate in the crisis range raises no acute flag', () {
      // The estimator can produce a figure past 180/120. If that ever reached
      // evaluateAcuteFlags it would fire a hypertensive-crisis alarm from an
      // estimate. The reading it was derived from carries no pressure at all,
      // so it cannot.
      final reading = _reading(hr: 180, spo2: 80);
      final e = estimateBloodPressure(
        profile: const RiskProfile(
          age: 45,
          sexMale: true,
          smoker: false,
          diabetic: false,
          baselineSystolicMmHg: 175,
          baselineDiastolicMmHg: 115,
        ),
        reading: reading,
        history: _history(70),
      );
      expect(e.stage, BpStage.crisisRange);

      expect(reading.systolicMmHg, isNull);
      expect(reading.hasBloodPressure, isFalse);
      expect(
        evaluateAcuteFlags(reading).where((f) => f.vital == 'Blood pressure'),
        isEmpty,
      );
    });

    test('the estimate is absent from the upload payload', () {
      final reading = _reading(hr: 90, spo2: 92);
      final json = reading.toJson();
      expect(json['systolic_mmhg'], isNull);
      expect(json['diastolic_mmhg'], isNull);
    });
  });

  group('staging', () {
    test('maps to the AHA cut-points', () {
      expect(BpStage.of(115, 75), BpStage.normal);
      expect(BpStage.of(125, 75), BpStage.elevated);
      expect(BpStage.of(135, 75), BpStage.stage1);
      expect(BpStage.of(115, 85), BpStage.stage1); // diastolic alone
      expect(BpStage.of(145, 85), BpStage.stage2);
      expect(BpStage.of(185, 85), BpStage.crisisRange);
      expect(BpStage.of(150, 125), BpStage.crisisRange);
    });
  });
}
