/// Live measurement visualization.
///
/// Occupies the same footprint as [RiskRing] and shares its geometry — same
/// diameter, stroke, sweep, and start angle — so beginning a measurement swaps the
/// ring's *contents* rather than shifting the page. The risk figure and the
/// measurement are the same object in two states, and the layout should say so.
///
/// ### Why this replaced a progress bar
///
/// A linear bar below the vitals grid put the primary action at the bottom of a
/// scroll view, and told the user nothing except "wait". A cuff measurement has
/// real structure worth showing: pressure climbs, then bleeds down while the
/// oscillometric signal is read. The arc traces that, so the wait is legible.
///
/// ### Motion budget
///
/// The pressure arc is **data**, so it animates even under reduced motion — it just
/// stops interpolating between ticks. The pulse ripples are **decoration** and stop
/// entirely (docs/design.md §3.6).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/vitals_source.dart';
import '../design/theme.dart';
import '../design/tokens.dart';

/// Matches RiskRing exactly. Any change here must be mirrored there.
const double _startAngle = math.pi * 0.75;
const double _sweepAngle = math.pi * 1.5;
const double _strokeWidth = 14.0;

class MeasureRing extends StatefulWidget {
  const MeasureRing({
    super.key,
    required this.progress,
    this.diameter = 260,
  });

  final MeasureProgress progress;
  final double diameter;

  @override
  State<MeasureRing> createState() => _MeasureRingState();
}

class _MeasureRingState extends State<MeasureRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    // One controller drives all three ripples via phase offsets.
    _pulse = AnimationController(
      duration: const Duration(milliseconds: 2400),
      vsync: this,
    );
  }

  @override
  void didUpdateWidget(MeasureRing old) {
    super.didUpdateWidget(old);
    _syncPulse();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  /// Ripples run only while sensing, and never under reduced motion.
  void _syncPulse() {
    final wanted = widget.progress.phase.isSensing && !context.reduceMotion;
    if (wanted && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!wanted && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final p = widget.progress;
    final reduced = context.reduceMotion;

    return Semantics(
      label: '${p.phase.shortLabel}. Cuff pressure '
          '${p.cuffPressureMmHg.round()} millimetres of mercury. ${p.phase.label}.',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: widget.diameter,
            height: widget.diameter,
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) {
                // Smooth the 120ms progress ticks into a continuous sweep. Under
                // reduced motion the value is applied directly — the arc still
                // moves, it just doesn't interpolate.
                return TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: p.inflationFraction),
                  duration: reduced ? Duration.zero : const Duration(milliseconds: 180),
                  curve: MecEasing.standard,
                  builder: (context, fraction, child) => CustomPaint(
                    painter: _MeasurePainter(
                      fraction: fraction,
                      arcColor: c.series1,
                      trackColor: c.gridline,
                      surfaceColor: c.card,
                      rippleT: _pulse.value,
                      showRipples: p.phase.isSensing && !reduced,
                    ),
                    child: child,
                  ),
                  child: Center(child: _MeasureContent(progress: p)),
                );
              },
            ),
          ),
          const SizedBox(height: MecSpace.s16),
          // Sits where the risk ring's factor chip sits, so the column below the
          // ring does not jump when the measurement finishes.
          _PhaseHint(phase: p.phase),
        ],
      ),
    );
  }
}

class _MeasureContent extends StatelessWidget {
  const _MeasureContent({required this.progress});

  final MeasureProgress progress;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Same slot as the risk band word.
        Text(
          progress.phase.shortLabel,
          style: MecType.sectionTitle.copyWith(
            color: c.inkSecondary,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: MecSpace.s4),
        // Same slot as the hero risk figure. Proportional figures, as there.
        Text(
          progress.cuffPressureMmHg.round().toString(),
          style: MecType.heroFigure.copyWith(color: c.inkPrimary, height: 1.0),
        ),
        const SizedBox(height: MecSpace.s4),
        Text(
          'mmHg cuff pressure',
          style: MecType.label.copyWith(color: c.inkSecondary),
        ),
      ],
    );
  }
}

/// Coaching line under the ring, cross-fading on phase change.
///
/// Sits in the same slot as the risk ring's factor chip so the column below does
/// not jump when a measurement starts or finishes.
class _PhaseHint extends StatelessWidget {
  const _PhaseHint({required this.phase});

  final MeasurePhase phase;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    final row = Row(
      key: ValueKey(phase),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          phase.isSensing ? Icons.favorite_outline : Icons.info_outline,
          size: 14,
          color: c.inkMuted,
        ),
        const SizedBox(width: MecSpace.s8),
        Text(phase.label, style: MecType.label.copyWith(color: c.inkSecondary)),
      ],
    );

    if (context.reduceMotion) return row;

    return AnimatedSwitcher(
      duration: MecMotion.fast,
      // Fade only — a sliding hint would be motion for its own sake.
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: row,
    );
  }
}

class _MeasurePainter extends CustomPainter {
  const _MeasurePainter({
    required this.fraction,
    required this.arcColor,
    required this.trackColor,
    required this.surfaceColor,
    required this.rippleT,
    required this.showRipples,
  });

  final double fraction;
  final Color arcColor;
  final Color trackColor;
  final Color surfaceColor;
  final double rippleT;
  final bool showRipples;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height)
        .deflate(_strokeWidth / 2 + 2);
    final center = rect.center;
    final radius = rect.width / 2;

    // ── Pulse ripples, behind the ring ──
    // Three staggered expansions reading as "listening for a pulse". Decoration,
    // so this whole block is skipped under reduced motion.
    if (showRipples) {
      for (var i = 0; i < 3; i++) {
        final t = (rippleT + i / 3) % 1.0;
        final r = radius * (0.88 + 0.30 * t);
        final opacity = (1.0 - t) * 0.28;
        canvas.drawCircle(
          center,
          r,
          Paint()
            ..color = arcColor.withValues(alpha: opacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }

    // ── Track ──
    canvas.drawArc(
      rect,
      _startAngle,
      _sweepAngle,
      false,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth
        ..strokeCap = StrokeCap.round,
    );

    if (fraction <= 0) return;

    // ── Pressure arc ──
    final swept = _sweepAngle * fraction.clamp(0.0, 1.0);
    canvas.drawArc(
      rect,
      _startAngle,
      swept,
      false,
      Paint()
        ..color = arcColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth
        ..strokeCap = StrokeCap.round,
    );

    // ── Leading dot ──
    // Marks where the pressure currently is, which makes the direction of travel
    // readable — climbing during inflation, receding during the measurement.
    final tipAngle = _startAngle + swept;
    final tip = Offset(
      center.dx + math.cos(tipAngle) * radius,
      center.dy + math.sin(tipAngle) * radius,
    );
    canvas.drawCircle(
      tip,
      _strokeWidth / 2 + MecChart.surfaceRing,
      Paint()..color = surfaceColor,
    );
    canvas.drawCircle(tip, _strokeWidth / 2 - 1, Paint()..color = arcColor);
  }

  @override
  bool shouldRepaint(_MeasurePainter old) =>
      old.fraction != fraction ||
      old.rippleT != rippleT ||
      old.showRipples != showRipples ||
      old.arcColor != arcColor;
}
