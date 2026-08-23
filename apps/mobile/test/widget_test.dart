/// Tests for the risk indicator's redundant-channel contract.
///
/// These are the safety tests. The palette validator measured the low↔high pair
/// at ΔE 4.1 under deuteranopia, meaning colour alone cannot distinguish "Low"
/// from "High" for roughly 8% of men. Every test below asserts that some channel
/// other than colour carries the meaning, so a future refactor that quietly
/// reduces the ring to a coloured arc fails here rather than in the field.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/data/vitals_source.dart';
import 'package:mecai_mobile/design/theme.dart';
import 'package:mecai_mobile/design/tokens.dart';
import 'package:mecai_mobile/models/vitals.dart';
import 'package:mecai_mobile/widgets/measure_ring.dart';
import 'package:mecai_mobile/widgets/risk_ring.dart';
import 'package:mecai_mobile/widgets/skeleton.dart';
import 'package:mecai_mobile/widgets/vital_tile.dart';

RiskAssessment _scored(MecRiskBand band, double pct) => RiskAssessment(
      band: band,
      valuePct: pct,
      horizon: '10-year',
      factors: const [
        RiskFactor(
          name: 'Age',
          displayValue: '55 years',
          contribution: 0.4,
          source: FactorSource.profile,
          modifiable: false,
        ),
        RiskFactor(
          name: 'Systolic blood pressure',
          displayValue: '125 mmHg',
          contribution: 0.6,
          source: FactorSource.device,
          modifiable: true,
        ),
      ],
      confidence: Confidence.complete,
      missingFields: const [],
      modelVersion: 'framingham-general-cvd-2008',
      disclaimer: 'Screening indicator, not a diagnosis. Consult a physician.',
    );

const _incomplete = RiskAssessment(
  band: MecRiskBand.unknown,
  valuePct: null,
  horizon: '10-year',
  factors: <RiskFactor>[],
  confidence: Confidence.incomplete,
  missingFields: <String>['total_cholesterol_mgdl', 'hdl_cholesterol_mgdl'],
  modelVersion: 'framingham-general-cvd-2008',
  disclaimer: 'Screening indicator, not a diagnosis. Consult a physician.',
);

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
      theme: MecTheme.dark(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  group('channel 1 — the band word is always visible', () {
    for (final band in [MecRiskBand.low, MecRiskBand.moderate, MecRiskBand.high]) {
      testWidgets('${band.name} renders its label as text', (tester) async {
        await tester.pumpWidget(_host(RiskRing(assessment: _scored(band, 12.0))));
        await tester.pumpAndSettle();

        expect(
          find.text(band.label.toUpperCase()),
          findsOneWidget,
          reason: 'the band word must be readable without perceiving colour',
        );
      });
    }
  });

  group('channel 2 — each band has a distinct icon', () {
    testWidgets('icons differ across all bands', (tester) async {
      final icons = <IconData>{};
      for (final band in MecRiskBand.values) {
        icons.add(riskBandIcon(band));
      }
      expect(
        icons.length,
        MecRiskBand.values.length,
        reason: 'a shared icon would collapse the shape channel',
      );
    });

    testWidgets('the band icon is rendered', (tester) async {
      await tester.pumpWidget(
        _host(RiskRing(assessment: _scored(MecRiskBand.high, 24.0))),
      );
      await tester.pumpAndSettle();

      expect(
        find.byIcon(riskBandIcon(MecRiskBand.high)),
        findsOneWidget,
      );
    });
  });

  group('the figure never appears bare', () {
    testWidgets('a percentage is always paired with its meaning', (tester) async {
      await tester.pumpWidget(
        _host(RiskRing(assessment: _scored(MecRiskBand.high, 42.0))),
      );
      await tester.pumpAndSettle();

      expect(find.text('42%'), findsOneWidget);
      expect(
        find.text('10-year estimated risk'),
        findsOneWidget,
        reason: 'an unlabelled 42% reads as an acute probability, not a 10-year estimate',
      );
    });

    testWidgets('the disclaimer is persistent, not dismissible', (tester) async {
      await tester.pumpWidget(
        _host(RiskRing(assessment: _scored(MecRiskBand.low, 4.0))),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('not a diagnosis'), findsOneWidget);
    });

    testWidgets('values below 10% keep one decimal', (tester) async {
      await tester.pumpWidget(
        _host(RiskRing(assessment: _scored(MecRiskBand.low, 4.3))),
      );
      await tester.pumpAndSettle();

      expect(find.text('4.3%'), findsOneWidget);
    });
  });

  group('incomplete profile', () {
    testWidgets('shows no percentage', (tester) async {
      await tester.pumpWidget(_host(const RiskRing(assessment: _incomplete)));
      await tester.pumpAndSettle();

      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('names the gap and offers the fix', (tester) async {
      await tester.pumpWidget(
        _host(RiskRing(assessment: _incomplete, onCompleteProfile: () {})),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('lipid panel'), findsOneWidget);
      expect(find.textContaining('Complete your profile'), findsOneWidget);
    });

    testWidgets('reports the unknown band, not a reassuring one', (tester) async {
      await tester.pumpWidget(_host(const RiskRing(assessment: _incomplete)));
      await tester.pumpAndSettle();

      expect(find.text(MecRiskBand.low.label.toUpperCase()), findsNothing);
      expect(find.text(MecRiskBand.unknown.label.toUpperCase()), findsOneWidget);
    });
  });

  group('accessibility', () {
    testWidgets('semantics carry band and meaning in one sentence', (tester) async {
      await tester.pumpWidget(
        _host(RiskRing(assessment: _scored(MecRiskBand.moderate, 14.2))),
      );
      await tester.pumpAndSettle();

      final node = tester.getSemantics(find.byType(RiskRing));
      expect(node.label, contains('Moderate'));
      expect(node.label, contains('14.2 percent'));
      expect(node.label, contains('10-year estimated risk'));
    });

    testWidgets('semantics explain an unscorable profile', (tester) async {
      await tester.pumpWidget(_host(const RiskRing(assessment: _incomplete)));
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.byType(RiskRing)).label,
        contains('cannot be calculated'),
      );
    });

    testWidgets('reduced motion arrives already filled', (tester) async {
      await tester.pumpWidget(
        _host(
          RiskRing(assessment: _scored(MecRiskBand.high, 30.0)),
          disableAnimations: true,
        ),
      );
      // A single frame — no settle. Under reduced motion the ring must not sweep,
      // so the value is final immediately.
      await tester.pump();

      expect(find.text('30%'), findsOneWidget);
    });
  });

  group('factor breakdown', () {
    testWidgets('exposes the factor count and stays tappable', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          RiskRing(
            assessment: _scored(MecRiskBand.moderate, 12.0),
            onTapFactors: () => tapped = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 factors'), findsOneWidget);

      await tester.tap(find.text('2 factors'));
      expect(
        tapped,
        isTrue,
        reason: 'a score the user cannot interrogate is not trustworthy',
      );
    });
  });

  group('skeletons', () {
    testWidgets('never suggest a risk level', (tester) async {
      await tester.pumpWidget(_host(const SkeletonRiskRing()));
      await tester.pump();

      // No band word, no percentage — a placeholder that implied "Low" would be
      // worse than an empty screen.
      for (final band in MecRiskBand.values) {
        expect(find.text(band.label.toUpperCase()), findsNothing);
      }
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('shimmer is applied when motion is allowed', (tester) async {
      await tester.pumpWidget(
        _host(const SkeletonShimmer(child: SkeletonBox(height: 20))),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(ShaderMask), findsOneWidget);
    });

    testWidgets('shimmer is dropped under reduced motion', (tester) async {
      await tester.pumpWidget(
        _host(
          const SkeletonShimmer(child: SkeletonBox(height: 20)),
          disableAnimations: true,
        ),
      );
      await tester.pump();

      // A looping gradient is exactly the ambient motion §3.6 requires stopping.
      expect(find.byType(ShaderMask), findsNothing);
      expect(find.byType(SkeletonBox), findsOneWidget);
    });

    testWidgets('the vitals grid renders one placeholder per tile', (tester) async {
      await tester.pumpWidget(_host(const SkeletonVitalsGrid()));
      await tester.pump();

      expect(find.byType(SkeletonVitalTile), findsNWidgets(3));
    });
  });

  group('vital tile fits its grid cell', () {
    // The real cell on a 360dp-wide screen: (360 - 32 page padding - 12 gutter)/2
    // = 158 wide, / 1.15 aspect = 137 high. The overflow that shipped was 3.6px
    // inside exactly these constraints, so the test pins them.
    const cellWidth = 158.0;
    const cellHeight = 137.0;

    testWidgets('with a threshold note and a sparkline', (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: cellWidth,
            height: cellHeight,
            child: VitalTile(
              label: 'Blood pressure',
              value: '152/95',
              unit: 'mmHg',
              trend: [140, 145, 150, 148, 152],
              range: VitalRange.outOfRange,
              thresholdNote: 'at or above 140/90',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'a flagged tile with a note must still fit its cell',
      );
    });

    testWidgets('without a sparkline', (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: cellWidth,
            height: cellHeight,
            child: VitalTile(
              label: 'Blood pressure',
              value: '—',
              unit: '',
              thresholdNote: 'No cuff sensor on this device',
              range: VitalRange.outOfRange,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('with a long label and a long note', (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: cellWidth,
            height: cellHeight,
            child: VitalTile(
              label: 'Peripheral capillary oxygen saturation',
              value: '88',
              unit: '%',
              trend: [96, 94, 92, 90, 88],
              range: VitalRange.outOfRange,
              thresholdNote: 'below 90% — seek emergency care immediately',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('measure ring', () {
    MeasureProgress progress(MeasurePhase phase, double pressure) => MeasureProgress(
          phase: phase,
          cuffPressureMmHg: pressure,
          targetPressureMmHg: 170,
        );

    testWidgets('shows the stage and the live cuff pressure', (tester) async {
      await tester.pumpWidget(
        _host(MeasureRing(progress: progress(MeasurePhase.inflating, 96))),
      );
      await tester.pump();

      expect(find.text('INFLATING'), findsOneWidget);
      expect(find.text('96'), findsOneWidget);
      expect(find.textContaining('mmHg'), findsOneWidget);
    });

    testWidgets('carries the coaching line for the stage', (tester) async {
      await tester.pumpWidget(
        _host(MeasureRing(progress: progress(MeasurePhase.measuring, 140))),
      );
      await tester.pump();

      expect(find.text(MeasurePhase.measuring.label), findsOneWidget);
    });

    testWidgets('never shows a risk band during measurement', (tester) async {
      await tester.pumpWidget(
        _host(MeasureRing(progress: progress(MeasurePhase.measuring, 140))),
      );
      await tester.pump();

      // A measurement in progress is not a risk state, and must not look like one.
      for (final band in MecRiskBand.values) {
        expect(find.text(band.label.toUpperCase()), findsNothing);
      }
    });

    testWidgets('still reports pressure under reduced motion', (tester) async {
      await tester.pumpWidget(
        _host(
          MeasureRing(progress: progress(MeasurePhase.measuring, 132)),
          disableAnimations: true,
        ),
      );
      await tester.pump();

      // The arc is data, not decoration — only the ripples stop.
      expect(find.text('132'), findsOneWidget);
      expect(find.text('MEASURING'), findsOneWidget);
    });

    testWidgets('shares the risk ring\'s footprint', (tester) async {
      // Same diameter in both states is what keeps the page from shifting when a
      // measurement starts.
      Size ringSize(Type ring) => tester.getSize(
            find
                .descendant(of: find.byType(ring), matching: find.byType(CustomPaint))
                .first,
          );

      await tester.pumpWidget(
        _host(MeasureRing(progress: progress(MeasurePhase.inflating, 50))),
      );
      await tester.pump();
      final measureSize = ringSize(MeasureRing);

      await tester.pumpWidget(
        _host(RiskRing(assessment: _scored(MecRiskBand.low, 5.0))),
      );
      await tester.pumpAndSettle();
      final riskSize = ringSize(RiskRing);

      expect(measureSize, riskSize);
      expect(measureSize.width, measureSize.height, reason: 'the ring is circular');
    });
  });
}
