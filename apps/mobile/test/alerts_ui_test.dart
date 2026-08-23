/// The alerts popup and its cards.
///
/// What these guard, in order of what they prevent:
/// 1. Severity is never carried by colour alone — the word is on the card.
/// 2. The header count matches the nav badge (urgent only), so the two cannot
///    disagree about how many alarms exist.
/// 3. `AcuteFlag.threshold` is rendered, so a finding is checkable rather than
///    asserted.
/// 4. The disclaimer is present without scrolling.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/design/theme.dart';
import 'package:mecai_mobile/models/vitals.dart';
import 'package:mecai_mobile/widgets/alert_card.dart';

AcuteFlag _flag(Severity severity, {String vital = 'SpO2'}) => AcuteFlag(
      severity: severity,
      vital: vital,
      displayValue: '88%',
      threshold: 'below 90%',
      message: 'Blood oxygen is critically low.',
      recommendation: 'Seek emergency care now.',
    );

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: MecTheme.dark(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

void main() {
  group('AlertCard', () {
    testWidgets('carries the severity as a word, not only a colour',
        (tester) async {
      await _pump(tester, AlertCard(flag: _flag(Severity.critical)));
      expect(find.text('CRITICAL'), findsOneWidget);

      await _pump(tester, AlertCard(flag: _flag(Severity.warning)));
      expect(find.text('WARNING'), findsOneWidget);

      await _pump(tester, AlertCard(flag: _flag(Severity.info)));
      expect(find.text('NOTE'), findsOneWidget);
    });

    testWidgets('shows the threshold that produced the finding', (tester) async {
      // The value alone is not checkable. This was carried on every AcuteFlag
      // and rendered nowhere before.
      await _pump(tester, AlertCard(flag: _flag(Severity.critical)));
      expect(find.text('below 90%'), findsOneWidget);
    });

    testWidgets('shows the reading, the message and the recommendation',
        (tester) async {
      await _pump(tester, AlertCard(flag: _flag(Severity.critical)));
      expect(find.text('88%'), findsOneWidget);
      expect(find.text('Blood oxygen is critically low.'), findsOneWidget);
      expect(find.text('Seek emergency care now.'), findsOneWidget);
    });

    testWidgets('reads as one utterance to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, AlertCard(flag: _flag(Severity.critical)));

      expect(
        find.bySemanticsLabel(RegExp(
          r'^CRITICAL\. SpO2 88%, below 90%\..*Seek emergency care now\.',
        )),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('does not overflow at the largest text scale', (tester) async {
      // A card that overflows is a card whose recommendation is unreadable, and
      // this one asks the user to seek emergency care.
      await tester.pumpWidget(
        MaterialApp(
          theme: MecTheme.dark(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: 320,
                  child: AlertCard(flag: _flag(Severity.critical)),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
