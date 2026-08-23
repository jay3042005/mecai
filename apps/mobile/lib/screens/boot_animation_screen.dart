/// Re-creation of the MEC-AI watch boot animation.
///
/// Reproduces the six-stage startup sequence from `MEC-AI3/MEC-AI3.ino`:
///
/// 1. Concentric rings burst outward from the centre.
/// 2. The letters of "MEC-AI" pop in one at a time, each a palette colour.
/// 3. The whole word pulses through the palette.
/// 4. It settle-flickers into steady white with an electric glow.
/// 5. Sparkles twinkle across the canvas.
/// 6. The BLE subtitle fades in, then the app takes over.
///
/// The drawing lives in `widgets/mec_boot_fx.dart` so the pairing screen shares
/// this exact vocabulary rather than imitating it. What stays here is the
/// choreography — the pipeline that walks the stages.
///
/// The palette is the product's blue/green/red/white rather than the firmware's
/// seven-colour rainbow, so the first frame the user sees already belongs to the
/// app it is opening. See [MecBootPalette].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../widgets/mec_boot_fx.dart';

class BootAnimationScreen extends StatefulWidget {
  const BootAnimationScreen({
    super.key,
    required this.onAnimationComplete,
  });

  final VoidCallback onAnimationComplete;

  @override
  State<BootAnimationScreen> createState() => _BootAnimationScreenState();
}

class _BootAnimationScreenState extends State<BootAnimationScreen>
    with TickerProviderStateMixin {
  static const String _word = 'MEC-AI';
  static const String _subtitle = 'BLE: MECAI-Watch';

  late final AnimationController _rings;
  late final AnimationController _paletteCycle;
  late final AnimationController _flicker;
  late final AnimationController _sparkles;

  bool _showRings = true;
  int _visibleLetters = 0;
  MecWordmarkTone _tone = MecWordmarkTone.palette;
  bool _showSparkles = false;
  bool _showSubtitle = false;

  /// Guards the pipeline against a second run and against firing the callback
  /// after the screen is gone.
  bool _finished = false;

  @override
  void initState() {
    super.initState();

    _rings = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _paletteCycle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _flicker = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _sparkles = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
  }

  bool _gatedOnce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery is only readable from here, and the reduced-motion answer
    // decides which of the two paths below we take. Run once.
    if (_gatedOnce) return;
    _gatedOnce = true;

    if (context.reduceMotion) {
      _arriveSettled();
    } else {
      _run();
    }
  }

  /// Reduced motion: no burst, no strobe, no sparkles.
  ///
  /// The wordmark simply *is* there, held long enough to read, and then the app
  /// opens. docs/design.md §3.6 treats this as a hard requirement rather than a
  /// nicety — and a strobing wordmark is among the worst offenders.
  Future<void> _arriveSettled() async {
    setState(() {
      _showRings = false;
      _visibleLetters = _word.length;
      _tone = MecWordmarkTone.settled;
      _showSubtitle = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 900));
    _complete();
  }

  Future<void> _run() async {
    // ── Stage 1: rings burst outward ──
    HapticFeedback.lightImpact();
    await _rings.forward();
    if (!mounted) return;
    setState(() => _showRings = false);

    // ── Stage 2: letters pop in, one at a time ──
    for (var i = 1; i <= _word.length; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 90));
      if (!mounted) return;
      HapticFeedback.selectionClick();
      setState(() => _visibleLetters = i);
    }

    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;

    // ── Stage 3: the word pulses through the palette ──
    _paletteCycle.repeat();
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (!mounted) return;
    _paletteCycle.stop();

    // ── Stage 4: settle-flicker into steady white ──
    setState(() => _tone = MecWordmarkTone.flicker);
    await _flicker.forward();
    if (!mounted) return;
    setState(() => _tone = MecWordmarkTone.settled);
    HapticFeedback.mediumImpact();

    // ── Stage 5 & 6: sparkles, then the subtitle ──
    setState(() {
      _showSparkles = true;
      _showSubtitle = true;
    });
    await _sparkles.forward();
    if (!mounted) return;

    await Future<void>.delayed(const Duration(milliseconds: 250));
    _complete();
  }

  void _complete() {
    if (_finished || !mounted) return;
    _finished = true;
    widget.onAnimationComplete();
  }

  @override
  void dispose() {
    _rings.dispose();
    _paletteCycle.dispose();
    _flicker.dispose();
    _sparkles.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Scaffold(
      // The page surface, not pure black, so the hand-off into the app has no
      // seam. The tonal system starts on the very first frame.
      backgroundColor: c.page,
      body: Stack(
        alignment: Alignment.center,
        children: [
          if (_showRings)
            AnimatedBuilder(
              animation: _rings,
              builder: (context, _) => MecRingBurst(progress: _rings.value),
            ),

          if (_showSparkles)
            AnimatedBuilder(
              animation: _sparkles,
              builder: (context, _) =>
                  MecSparkleField(progress: _sparkles.value),
            ),

          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: Listenable.merge([_paletteCycle, _flicker]),
                  builder: (context, _) => MecWordmark(
                    text: _word,
                    visibleLetters: _visibleLetters,
                    tone: _tone,
                    paletteOffset:
                        (_paletteCycle.value * MecBootPalette.brand.length)
                            .toInt(),
                    flickerPhase: (_flicker.value * 10).toInt(),
                  ),
                ),
                const SizedBox(height: MecSpace.s16),
                AnimatedOpacity(
                  opacity: _showSubtitle ? 1 : 0,
                  duration: context.stilled(MecMotion.fast),
                  curve: MecEasing.decelerate,
                  child: Text(
                    _subtitle,
                    style: MecType.label.copyWith(
                      color: c.inkMuted,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
