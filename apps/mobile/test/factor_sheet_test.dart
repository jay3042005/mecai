/// Regression tests for the factor sheet's height.
///
/// A complete profile produces six factors. As a fixed `Column` inside a bottom
/// sheet that overflowed by 208px, so four of the six were unreachable and the
/// framework threw during layout. The bug only appeared once profiles could
/// actually be scored — with an incomplete profile the list is empty or has one
/// row, which always fitted.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/design/theme.dart';
import 'package:mecai_mobile/design/tokens.dart';
import 'package:mecai_mobile/models/vitals.dart';
import 'package:mecai_mobile/widgets/factor_sheet.dart';

RiskAssessment _assessment({required int factorCount}) => RiskAssessment(
      band: MecRiskBand.moderate,
      valuePct: 14.2,
      horizon: '10-year',
      factors: List<RiskFactor>.generate(
        factorCount,
        (i) => RiskFactor(
          name: 'Factor with a fairly long name $i',
          displayValue: '$i mg/dL',
          contribution: 1 / factorCount,
          source: i.isEven ? FactorSource.device : FactorSource.profile,
          modifiable: true,
        ),
      ),
      confidence: Confidence.complete,
      missingFields: const [],
      modelVersion: 'framingham-general-cvd-2008',
      disclaimer: 'Screening indicator, not a diagnosis. Consult a physician.',
    );

/// Hosts the sheet inside a box the height of a real bottom sheet, which is where
/// the overflow occurred — testing it unbounded would never reproduce the bug.
Widget _host(Widget child, {double maxHeight = 376.8}) => MaterialApp(
      theme: MecTheme.dark(),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 360, maxHeight: maxHeight),
            child: child,
          ),
        ),
      ),
    );

void main() {
  testWidgets('six factors fit a half-screen sheet without overflowing',
      (tester) async {
    await tester.pumpWidget(_host(FactorSheet(assessment: _assessment(factorCount: 6))));
    await tester.pumpAndSettle();

    // `tester.takeException` returns the layout assertion if the flex overflowed.
    expect(tester.takeException(), isNull);
  });

  testWidgets('the caveat stays visible with a long factor list', (tester) async {
    await tester.pumpWidget(_host(FactorSheet(assessment: _assessment(factorCount: 6))));
    await tester.pumpAndSettle();

    // Pinned, not scrolled away: bars that scroll free of this line read as
    // individual risk percentages, which is exactly what they are not.
    expect(
      find.textContaining('not individual risk percentages'),
      findsOneWidget,
    );
    expect(find.text('What drove this score'), findsOneWidget);
  });

  testWidgets('the factor rows scroll when they do not fit', (tester) async {
    await tester.pumpWidget(_host(FactorSheet(assessment: _assessment(factorCount: 6))));
    await tester.pumpAndSettle();

    expect(find.byType(Scrollable), findsWidgets);
  });

  testWidgets('a short list sizes to its rows rather than forcing a scroll',
      (tester) async {
    await tester.pumpWidget(
      _host(FactorSheet(assessment: _assessment(factorCount: 2))),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // The list shrink-wraps: two rows occupy their own height, well inside the
    // sheet, so a short breakdown is fully visible without scrolling. Asserted on
    // the list rather than the sheet because the sheet's overall height is the
    // host's decision, not this widget's.
    final listHeight = tester.getSize(find.byType(ListView)).height;
    expect(listHeight, lessThan(300));
    expect(listHeight, greaterThan(0));
  });

  testWidgets('an empty factor list renders without error', (tester) async {
    await tester.pumpWidget(
      _host(FactorSheet(assessment: _assessment(factorCount: 0))),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('What drove this score'), findsOneWidget);
  });

  testWidgets('fits a very short sheet too', (tester) async {
    // A small phone in landscape leaves very little height. The rows must give way
    // rather than the layout throwing.
    await tester.pumpWidget(
      _host(FactorSheet(assessment: _assessment(factorCount: 6)), maxHeight: 200),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
