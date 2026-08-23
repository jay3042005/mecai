/// The blood-pressure estimate card.
///
/// The one thing these guard: the card can never be mistaken for a measurement.
/// The word ESTIMATE, the `~`, and the confidence line are all required to be
/// present, and the missing-baseline state must offer the fix rather than a bare
/// em-dash.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/data/bp_estimator.dart';
import 'package:mecai_mobile/design/theme.dart';
import 'package:mecai_mobile/models/vitals.dart';
import 'package:mecai_mobile/widgets/bp_estimate_card.dart';

const _baseline = RiskProfile(
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

VitalsReading _reading({double hr = 78, double spo2 = 97}) => VitalsReading(
      heartRateBpm: hr,
      spo2Pct: spo2,
      measuredAt: DateTime(2026),
    );

Future<void> _pump(WidgetTester tester, BpEstimate estimate,
        {VoidCallback? onSetBaseline}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: MecTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: BpEstimateCard(
              estimate: estimate,
              onSetBaseline: onSetBaseline,
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('is labelled an estimate and never a measurement',
      (tester) async {
    await _pump(
      tester,
      estimateBloodPressure(profile: _baseline, reading: _reading()),
    );

    expect(find.text('ESTIMATE'), findsOneWidget);
    expect(find.text('Estimated blood pressure'), findsOneWidget);
    // The tilde is the mark that survives someone glancing at the figure and
    // reading nothing else.
    expect(find.textContaining('~'), findsOneWidget);
    expect(find.textContaining('not a measurement'), findsOneWidget);
  });

  testWidgets('carries a Low/Medium/High band, with a word not just a hue',
      (tester) async {
    // Baseline 120/80 at rest → Elevated stage → Medium band.
    await _pump(
      tester,
      estimateBloodPressure(profile: _baseline, reading: _reading(hr: 70)),
    );
    expect(find.text('MEDIUM'), findsOneWidget);

    // A high baseline lands in the high band.
    await _pump(
      tester,
      estimateBloodPressure(
        profile: const RiskProfile(
          age: 45,
          sexMale: true,
          smoker: false,
          diabetic: false,
          baselineSystolicMmHg: 150,
          baselineDiastolicMmHg: 95,
        ),
        reading: _reading(hr: 70),
      ),
    );
    expect(find.text('HIGH'), findsOneWidget);

    // And a normal one in the low band.
    await _pump(
      tester,
      estimateBloodPressure(
        profile: const RiskProfile(
          age: 45,
          sexMale: true,
          smoker: false,
          diabetic: false,
          baselineSystolicMmHg: 110,
          baselineDiastolicMmHg: 70,
        ),
        reading: _reading(hr: 70),
      ),
    );
    expect(find.text('LOW'), findsOneWidget);
  });

  testWidgets('shows the confidence and the derivation', (tester) async {
    await _pump(
      tester,
      estimateBloodPressure(profile: _baseline, reading: _reading(hr: 78)),
    );

    // Confidence is always present — an estimate with no stated confidence is
    // read as a reading.
    expect(
      find.textContaining(RegExp('baseline|Rough')),
      findsWidgets,
    );
    // The arithmetic is inspectable: the user can see it is their own resting
    // rate plus a shift, not an oracle.
    expect(find.textContaining('78 bpm'), findsOneWidget);
  });

  testWidgets('with no cuff baseline it names the gap and offers the fix',
      (tester) async {
    var opened = false;
    await _pump(
      tester,
      estimateBloodPressure(profile: _noBaseline, reading: _reading()),
      onSetBaseline: () => opened = true,
    );

    expect(find.textContaining('cuff'), findsOneWidget);
    // A bare em-dash would leave the user with no idea what to do.
    await tester.tap(find.text('Open health profile'));
    expect(opened, isTrue);
  });

  testWidgets('a motion-affected reading says so on the card', (tester) async {
    final estimate = estimateBloodPressure(
      profile: _baseline,
      reading: VitalsReading(
        heartRateBpm: 78,
        spo2Pct: 97,
        measuredAt: DateTime(2026),
        motionArtifact: true,
      ),
    );
    await _pump(tester, estimate);

    expect(find.textContaining('direction'), findsWidgets);
  });

  testWidgets('does not overflow at the largest text scale', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MecTheme.dark(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 320,
                child: BpEstimateCard(
                  estimate: estimateBloodPressure(
                    profile: _baseline,
                    reading: _reading(hr: 130, spo2: 88),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
