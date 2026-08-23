/// Reduced-motion gating for the Material You additions.
///
/// docs/design.md §3.6 treats `prefers-reduced-motion` as a hard requirement, not
/// a nicety: "A pulsing red full-screen alert is a vestibular hazard and is
/// exactly the wrong thing to show someone who may be having a cardiac event."
///
/// The boot animation used to ignore it entirely — a six-stage burst-and-strobe
/// sequence played regardless. These tests keep that from coming back.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mecai_mobile/design/theme.dart';
import 'package:mecai_mobile/screens/boot_animation_screen.dart';
import 'package:mecai_mobile/widgets/mec_boot_fx.dart';
import 'package:mecai_mobile/widgets/mec_press.dart';
import 'package:mecai_mobile/widgets/mec_stagger.dart';

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
      theme: MecTheme.dark(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  group('press feedback', () {
    testWidgets('scales when motion is allowed', (tester) async {
      await tester.pumpWidget(_host(const MecPress(child: Text('tap'))));
      expect(find.byType(AnimatedScale), findsOneWidget);
    });

    testWidgets('is dropped under reduced motion', (tester) async {
      await tester.pumpWidget(
        _host(const MecPress(child: Text('tap')), disableAnimations: true),
      );

      // A shrinking target is movement, so it goes — the child stays.
      expect(find.byType(AnimatedScale), findsNothing);
      expect(find.text('tap'), findsOneWidget);
    });

    testWidgets('a disabled control never scales', (tester) async {
      await tester.pumpWidget(
        _host(const MecPress(enabled: false, child: Text('tap'))),
      );
      expect(find.byType(AnimatedScale), findsNothing);
    });
  });

  group('staggered entrance', () {
    testWidgets('slides and fades when motion is allowed', (tester) async {
      await tester.pumpWidget(
        _host(const MecStagger(index: 0, child: Text('row'))),
      );
      expect(find.byType(AnimatedSlide), findsOneWidget);
    });

    testWidgets('arrives instantly under reduced motion', (tester) async {
      await tester.pumpWidget(
        _host(
          const MecStagger(index: 3, child: Text('row')),
          disableAnimations: true,
        ),
      );

      expect(find.byType(AnimatedSlide), findsNothing);
      // Instantly, not merely quickly: no delay to wait out.
      expect(find.text('row'), findsOneWidget);
    });
  });

  group('boot animation', () {
    testWidgets('plays the ring burst when motion is allowed', (tester) async {
      await tester.pumpWidget(_host(BootAnimationScreen(onAnimationComplete: () {})));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(MecRingBurst), findsOneWidget);

      // Drain in steps: each stage awaits before scheduling the next, so a
      // single large pump would leave a later timer pending.
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    });

    testWidgets('skips straight to the settled wordmark under reduced motion',
        (tester) async {
      var completed = false;
      await tester.pumpWidget(
        _host(
          BootAnimationScreen(onAnimationComplete: () => completed = true),
          disableAnimations: true,
        ),
      );
      await tester.pump();

      // No burst, no sparkles, no strobe — just the word, already there.
      expect(find.byType(MecRingBurst), findsNothing);
      expect(find.byType(MecSparkleField), findsNothing);
      expect(find.byType(MecWordmark), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1000));
      expect(completed, isTrue, reason: 'the app must still open');
    });

    testWidgets('hands off exactly once', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _host(
          BootAnimationScreen(onAnimationComplete: () => calls++),
          disableAnimations: true,
        ),
      );
      await tester.pump(const Duration(seconds: 3));

      expect(calls, 1);
    });
  });

  group('wordmark', () {
    testWidgets('holds its full width while letters are still arriving',
        (tester) async {
      await tester.pumpWidget(
        _host(const MecWordmark(visibleLetters: 6, animatePop: false)),
      );
      final full = tester.getSize(find.byType(MecWordmark));

      await tester.pumpWidget(
        _host(const MecWordmark(visibleLetters: 2, animatePop: false)),
      );
      await tester.pump();
      final partial = tester.getSize(find.byType(MecWordmark));

      // Hidden letters render transparent rather than absent, so the word does
      // not grow and shift as it pops in.
      expect(partial.width, full.width);
    });
  });
}
