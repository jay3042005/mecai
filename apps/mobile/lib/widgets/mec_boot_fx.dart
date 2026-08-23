/// The MEC-AI boot animation's visual vocabulary, extracted so the pairing flow
/// can *be* its sibling rather than a copy of it.
///
/// The watch firmware (`MEC-AI3/MEC-AI3.ino`) opens with a six-stage sequence:
/// concentric rings burst outward, the letters of "MEC-AI" pop in one at a time,
/// the word pulses through a palette, settles to white, and sparkles twinkle.
/// The pieces live here as three primitives — [MecRingBurst], [MecSparkleField]
/// and [MecWordmark] — so both screens draw from one implementation.
///
/// ### Palette
///
/// The firmware cycles a seven-colour rainbow (magenta, cyan, yellow…). This
/// deliberately narrows that to the **product palette — blue, green, red and
/// white** — so the splash reads as MEC-AI rather than as a test pattern, and so
/// the app's first frame and its steady state belong to each other.
///
/// Red appears here and nowhere else outside an actual alarm. That is safe
/// precisely because a splash carries **no clinical state**: there is no reading
/// on screen for it to be mistaken for. [MecBootPalette.calm] drops it anyway for
/// the pairing radar, where a pulsing red ring during a connection attempt would
/// read as a failure that has not happened.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';

abstract final class MecBootPalette {
  /// Blue → green → white → red. The full product palette, for the splash.
  ///
  /// `final`, not `const`: `MecRiskBand.low.color` is an enum field access, which
  /// Dart cannot evaluate at compile time. Widgets here therefore take a nullable
  /// palette and resolve it at use rather than as a default argument.
  static final List<Color> brand = <Color>[
    MecSeries.s1Dark,
    MecSeries.s2Dark,
    MecRiskBand.low.color,
    MecSurfaceDark.inkPrimary,
    MecAlarm.color,
  ];

  /// The same sweep with the alarm red removed, for anything that is *working*
  /// rather than celebrating — scanning, connecting, waiting.
  static final List<Color> calm = <Color>[
    MecSeries.s1Dark,
    MecSeries.s2Dark,
    MecRiskBand.low.color,
    MecSurfaceDark.inkPrimary,
  ];
}

// ═══════════════════════════════════════════════════════════════
// RING BURST
// ═══════════════════════════════════════════════════════════════

/// Concentric rings expanding from the centre, each trailing the last.
///
/// Drive [progress] once for the splash's outward burst, or repeat it for the
/// pairing screen's radar. [settle] blends every ring toward [settleColor],
/// which lets colour drain out of the palette as a connection firms up.
class MecRingBurst extends StatelessWidget {
  const MecRingBurst({
    super.key,
    required this.progress,
    this.palette,
    this.ringCount = 18,
    this.strokeWidth = 3,
    this.maxRadiusFactor = 0.7,
    this.spacing = 0.03,
    this.settle = 0,
    this.settleColor,
  });

  final double progress;

  /// Defaults to [MecBootPalette.brand].
  final List<Color>? palette;

  final int ringCount;
  final double strokeWidth;

  /// Outermost radius, as a fraction of the box's longest side.
  final double maxRadiusFactor;

  /// Delay between successive rings, in units of [progress].
  final double spacing;

  /// 0 = full palette, 1 = every ring is [settleColor].
  final double settle;

  final Color? settleColor;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.infinite,
        painter: _RingBurstPainter(
          progress: progress,
          palette: palette ?? MecBootPalette.brand,
          ringCount: ringCount,
          strokeWidth: strokeWidth,
          maxRadiusFactor: maxRadiusFactor,
          spacing: spacing,
          settle: settle,
          settleColor: settleColor ?? context.mec.series1,
        ),
      ),
    );
  }
}

class _RingBurstPainter extends CustomPainter {
  const _RingBurstPainter({
    required this.progress,
    required this.palette,
    required this.ringCount,
    required this.strokeWidth,
    required this.maxRadiusFactor,
    required this.spacing,
    required this.settle,
    required this.settleColor,
  });

  final double progress;
  final List<Color> palette;
  final int ringCount;
  final double strokeWidth;
  final double maxRadiusFactor;
  final double spacing;
  final double settle;
  final Color settleColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = math.max(size.width, size.height) * maxRadiusFactor;

    for (var i = 0; i < ringCount; i++) {
      final t = (progress - i * spacing).clamp(0.0, 1.0);
      if (t <= 0) continue;

      final base = palette[i % palette.length];
      final color = settle <= 0
          ? base
          : Color.lerp(base, settleColor, settle.clamp(0.0, 1.0))!;

      canvas.drawCircle(
        center,
        t * maxRadius,
        Paint()
          ..color = color.withValues(alpha: (1.0 - t).clamp(0.0, 0.85))
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth,
      );
    }
  }

  @override
  bool shouldRepaint(_RingBurstPainter old) =>
      old.progress != progress ||
      old.settle != settle ||
      old.palette != palette ||
      old.settleColor != settleColor;
}

// ═══════════════════════════════════════════════════════════════
// SPARKLE FIELD
// ═══════════════════════════════════════════════════════════════

/// Palette specks that twinkle up and back down across one pass of [progress].
///
/// One pass only. A looping sparkle field would be ambient decoration, and
/// docs/design.md §7 rejects particle effects that keep running.
class MecSparkleField extends StatelessWidget {
  const MecSparkleField({
    super.key,
    required this.progress,
    this.palette,
    this.count = 22,
    this.seed = 42,
    this.area = const Rect.fromLTWH(0.1, 0.2, 0.8, 0.6),
  });

  final double progress;

  /// Defaults to [MecBootPalette.brand].
  final List<Color>? palette;

  final int count;

  /// Fixed so the layout is identical every run — and stable under test.
  final int seed;

  /// Where specks may land, in fractions of the box.
  final Rect area;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.infinite,
        painter: _SparklePainter(
          progress: progress,
          sparkles: _build(),
        ),
      ),
    );
  }

  List<_Sparkle> _build() {
    final hues = palette ?? MecBootPalette.brand;
    final rng = math.Random(seed);
    return List<_Sparkle>.generate(count, (i) {
      return _Sparkle(
        x: area.left + rng.nextDouble() * area.width,
        y: area.top + rng.nextDouble() * area.height,
        size: 2.0 + rng.nextDouble() * 4.0,
        // Each speck peaks at its own moment rather than all at once.
        phase: rng.nextDouble() * 0.4,
        color: hues[i % hues.length],
      );
    });
  }
}

@immutable
class _Sparkle {
  const _Sparkle({
    required this.x,
    required this.y,
    required this.size,
    required this.phase,
    required this.color,
  });

  final double x;
  final double y;
  final double size;
  final double phase;
  final Color color;
}

class _SparklePainter extends CustomPainter {
  const _SparklePainter({required this.progress, required this.sparkles});

  final double progress;
  final List<_Sparkle> sparkles;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in sparkles) {
      final t = ((progress - s.phase) / (1 - s.phase)).clamp(0.0, 1.0);
      if (t <= 0) continue;

      final alpha = math.sin(t * math.pi).clamp(0.0, 1.0);
      canvas.drawCircle(
        Offset(s.x * size.width, s.y * size.height),
        s.size,
        Paint()..color = s.color.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_SparklePainter old) => old.progress != progress;
}

// ═══════════════════════════════════════════════════════════════
// WORDMARK
// ═══════════════════════════════════════════════════════════════

/// How the wordmark is currently coloured.
enum MecWordmarkTone {
  /// Each letter takes a palette colour, rotating by `paletteOffset`.
  palette,

  /// Mid-settle: letters strobe between white and nothing.
  flicker,

  /// Steady crisp white with an electric glow. Where the sequence lands.
  settled,
}

/// "MEC-AI", letter by letter — a pure renderer driven by its arguments.
///
/// Stateless so the splash's six-stage pipeline and the pairing screen's simple
/// entrance can both drive it without either inheriting the other's timing.
///
/// Letters past [visibleLetters] render fully transparent rather than as a gap,
/// so the word occupies its final width from the first frame and nothing shifts
/// as letters arrive.
class MecWordmark extends StatelessWidget {
  const MecWordmark({
    super.key,
    this.text = 'MEC-AI',
    this.visibleLetters,
    this.tone = MecWordmarkTone.settled,
    this.paletteOffset = 0,
    this.flickerPhase = 0,
    this.fontSize = 52,
    this.palette,
    this.animatePop = true,
  });

  final String text;

  /// How many leading letters are shown. Null shows all of them.
  final int? visibleLetters;

  final MecWordmarkTone tone;

  /// Rotates the palette across letters, which is what makes the colour travel.
  final int paletteOffset;

  /// Drives [MecWordmarkTone.flicker]; even values are lit.
  final int flickerPhase;

  final double fontSize;

  /// Defaults to [MecBootPalette.brand].
  final List<Color>? palette;

  /// The elastic pop as each letter appears. Off under reduced motion.
  final bool animatePop;

  List<Color> get _hues => palette ?? MecBootPalette.brand;

  Color _colorFor(int i, Color settled) => switch (tone) {
        MecWordmarkTone.settled => settled,
        MecWordmarkTone.flicker =>
          flickerPhase.isEven ? settled : Colors.transparent,
        MecWordmarkTone.palette => _hues[(i + paletteOffset) % _hues.length],
      };

  @override
  Widget build(BuildContext context) {
    final settled = context.mec.inkPrimary;
    final shown = visibleLetters ?? text.length;
    final pop = animatePop && !context.reduceMotion;

    return Semantics(
      label: text,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(text.length, (i) {
            final visible = i < shown;
            final color = _colorFor(i, settled);

            final glyph = Text(
              text[i],
              style: MecType.heroFigure.copyWith(
                color: color,
                fontSize: fontSize,
                fontWeight: FontWeight.w800,
                letterSpacing: 2.0,
                height: 1.1,
                shadows: color == Colors.transparent
                    ? null
                    : [
                        Shadow(
                          color: color.withValues(alpha: 0.6),
                          blurRadius: 18,
                        ),
                      ],
              ),
            );

            // Transparent rather than absent: the word keeps its final width.
            if (!visible) return Opacity(opacity: 0, child: glyph);
            if (!pop) return glyph;

            return TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0.3, end: 1.0),
              duration: MecMotion.instant,
              curve: Curves.elasticOut,
              builder: (context, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: glyph,
            );
          }),
        ),
      ),
    );
  }
}
