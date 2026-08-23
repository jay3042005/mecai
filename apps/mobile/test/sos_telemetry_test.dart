/// The GPS line on the SOS screen reports the real fix.
///
/// The one thing this guards: the card must never print a place name it was not
/// given. It used to render 'GPS: Tacurong City, Sultan Kudarat (High accuracy)'
/// as a literal, whatever the phone's actual position was and even when the GPS
/// had failed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/data/location_service.dart';
import 'package:mecai_mobile/widgets/sos_telemetry.dart';

Future<void> _pump(WidgetTester tester, Widget card) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: card)),
    );

void main() {
  testWidgets('a live fix shows its own coordinates and accuracy',
      (tester) async {
    await _pump(
      tester,
      const SosTelemetryCard(
        reading: null,
        surface: Colors.black,
        fix: LocationFix(
          latitude: 6.6899,
          longitude: 124.6761,
          accuracyM: 12.4,
          quality: FixQuality.live,
        ),
      ),
    );

    expect(find.textContaining('6.68990, 124.67610'), findsOneWidget);
    expect(find.textContaining('±12 m'), findsOneWidget);
    expect(find.textContaining('Tacurong'), findsNothing);
  });

  testWidgets('a stale fix is labelled as last known', (tester) async {
    await _pump(
      tester,
      const SosTelemetryCard(
        reading: null,
        surface: Colors.black,
        fix: LocationFix(
          latitude: 1,
          longitude: 2,
          quality: FixQuality.lastKnown,
        ),
      ),
    );

    expect(find.textContaining('last known'), findsOneWidget);
  });

  testWidgets('no fix reports the problem rather than a location',
      (tester) async {
    await _pump(
      tester,
      const SosTelemetryCard(
        reading: null,
        surface: Colors.black,
        fix: LocationFix.unavailable(problem: 'Location is switched off.'),
      ),
    );

    expect(find.textContaining('Location is switched off.'), findsOneWidget);
  });

  testWidgets('while locating it says so', (tester) async {
    await _pump(
      tester,
      const SosTelemetryCard(
        reading: null,
        surface: Colors.black,
        locating: true,
      ),
    );

    expect(find.textContaining('acquiring fix'), findsOneWidget);
  });
}
