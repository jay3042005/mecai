/// The risk indicator — the one component that must not be gotten wrong.
///
/// Carries four redundant channels (docs/design.md §4):
///
/// 1. **Word** — the band label, always visible.
/// 2. **Icon** — a distinct silhouette per band.
/// 3. **Arc length** — proportional fill, readable with zero colour.
/// 4. **Colour** — last, and never load-bearing alone.
///
/// The redundancy is not defensive over-engineering. Measured with
/// `validate_palette.js`, the low↔high pair sits at **ΔE 4.1 under
/// deuteranopia** — roughly 8% of men cannot distinguish "Low" from "High" by
/// colour. In a cardiovascular app that is a safety defect, so the word, the
/// icon, and the arc all carry the same meaning independently.
///
/// ### Why the ring is scaled 0–40%, not 0–100%
///
/// Ten-year CVD risk is banded at <10 / 10–20 / >=20. On a 0–100 ring a 42% risk
/// renders as "less than half full", which reads as reassuring and is the
/// opposite of true. Sweeping 0–40% instead — with tick marks at the two band
/// boundaries — makes arc length mean something clinical. Above 40% the arc pegs,
/// because the exact figure has stopped mattering by then.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vitals.dart';
import 'mec_press.dart';

/// Top of the display scale. Values above this peg the arc.
const double _displayMaxPct = 40.0;

/// 270° sweep starting at the lower-left, leaving the bottom open for the caption.
const double _startAngle = math.pi * 0.75;
const double _sweepAngle = math.pi * 1.5;

class RiskRing extends StatefulWidget {
  const RiskRing({
    super.key,
    required this.assessment,
    this.onTapFactors,
    this.onCompleteProfile,
    this.diameter = 260,
  });

  final RiskAssessment assessment;

  /// Opens the factor breakdown. A score the user cannot interrogate is not
  /// trustworthy, so this should always be wired.
  final VoidCallback? onTapFactors;

  /// Shown instead of the factor chip when the profile is incomplete.
  final VoidCallback? onCompleteProfile;

  final double diameter;

  @override
  State<RiskRing> createState() => _RiskRingState();
}

class _RiskRingState extends State<RiskRing> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _fill;

  double get _targetFraction {
    final pct = widget.assessment.valuePct;
    if (pct == null) return 0;
    return (pct / _displayMaxPct).clamp(0.0, 1.0);
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: MecMotion.value, vsync: this);
    _fill = Tween<double>(begin: 0, end: _targetFraction)
        .animate(CurvedAnimation(parent: _controller, curve: MecEasing.decelerate));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion means the ring arrives already filled — no sweep.
    if (context.reduceMotion) {
      _controller.value = 1.0;
    } else if (!_controller.isAnimating && _controller.value == 0) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(RiskRing old) {
    super.didUpdateWidget(old);
    if (old.assessment.valuePct == widget.assessment.valuePct) return;

    // Animate from wherever the arc currently is, so a re-score slides rather
    // than snapping back to zero first.
    _fill = Tween<double>(begin: _fill.value, end: _targetFraction)
        .animate(CurvedAnimation(parent: _controller, curve: MecEasing.decelerate));
    if (context.reduceMotion) {
      _controller.value = 1.0;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final a = widget.assessment;
    final scored = a.isScored;

    return Semantics(
      // One flat sentence, so a screen reader conveys the same meaning the
      // sighted redundancy does.
      label: scored
          ? '${a.band.label} cardiovascular risk. '
              '${a.valuePct!.toStringAsFixed(1)} percent ${a.valueCaption}.'
          : 'Cardiovascular risk cannot be calculated. ${a.band.label}.',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: widget.diameter,
            height: widget.diameter,
            child: AnimatedBuilder(
              animation: _fill,
              builder: (context, _) => CustomPaint(
                painter: _RingPainter(
                  fraction: scored ? _fill.value : 0,
                  bandColor: a.band.color,
                  trackColor: c.gridline,
                  tickColor: c.baseline,
                  dashed: !scored,
                  displayMaxPct: _displayMaxPct,
                ),
                child: Center(child: _RingContent(assessment: a)),
              ),
            ),
          ),
          const SizedBox(height: MecSpace.s16),
          if (scored)
            _FactorChip(count: a.factors.length, onTap: widget.onTapFactors)
          else
            _CompleteProfileChip(
              missingCount: a.missingFields.length,
              onTap: widget.onCompleteProfile,
            ),
          const SizedBox(height: MecSpace.s12),
          // Persistent, never a dismissible toast.
          Text(
            a.disclaimer,
            textAlign: TextAlign.center,
            style: MecType.axisTick.copyWith(color: c.inkMuted),
          ),
        ],
      ),
    );
  }
}

/// Band word, icon, hero figure, and the figure's meaning.
class _RingContent extends StatelessWidget {
  const _RingContent({required this.assessment});

  final RiskAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final a = assessment;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MecSpace.s32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Channels 1 and 2: icon + word, together, always visible.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(riskBandIcon(a.band), size: 18, color: a.band.color),
              const SizedBox(width: MecSpace.s8),
              Flexible(
                child: Text(
                  a.band.label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MecType.sectionTitle.copyWith(
                    color: c.inkPrimary,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s4),
          if (a.isScored) ...[
            // Hero figure. Proportional figures, never tabular — tabular makes a
            // number like 121 look loose at display sizes.
            Text(
              '${a.valuePct!.toStringAsFixed(a.valuePct! < 10 ? 1 : 0)}%',
              style: MecType.heroFigure.copyWith(color: c.inkPrimary, height: 1.0),
            ),
            const SizedBox(height: MecSpace.s4),
            // The number's meaning. Never a bare percentage.
            Text(
              a.valueCaption,
              textAlign: TextAlign.center,
              style: MecType.label.copyWith(color: c.inkSecondary),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: MecSpace.s8),
              child: Text(
                'Add a lipid panel to\nenable risk scoring',
                textAlign: TextAlign.center,
                style: MecType.body.copyWith(color: c.inkSecondary, height: 1.35),
              ),
            ),
        ],
      ),
    );
  }
}

class _FactorChip extends StatelessWidget {
  const _FactorChip({required this.count, this.onTap});

  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return _Chip(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.tune, size: 14, color: c.inkSecondary),
          const SizedBox(width: MecSpace.s8),
          Text(
            '$count factors',
            style: MecType.label.copyWith(color: c.inkSecondary),
          ),
          if (onTap != null) ...[
            const SizedBox(width: MecSpace.s4),
            Icon(Icons.chevron_right, size: 16, color: c.inkMuted),
          ],
        ],
      ),
    );
  }
}

class _CompleteProfileChip extends StatelessWidget {
  const _CompleteProfileChip({required this.missingCount, this.onTap});

  final int missingCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return _Chip(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit_outlined, size: 14, color: c.inkSecondary),
          const SizedBox(width: MecSpace.s8),
          Text(
            missingCount == 0
                ? 'Complete your profile'
                : 'Complete your profile ($missingCount missing)',
            style: MecType.label.copyWith(color: c.inkSecondary),
          ),
          if (onTap != null) ...[
            const SizedBox(width: MecSpace.s4),
            Icon(Icons.chevron_right, size: 16, color: c.inkMuted),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return MecPress(
      enabled: onTap != null,
      child: Material(
        color: c.card,
        shape: StadiumBorder(side: BorderSide(color: c.hairline)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          overlayColor: mecStateLayer(c.series1),
          // Comfortably above the 24px minimum hit target.
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MecSpace.s16,
              vertical: MecSpace.s12,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.fraction,
    required this.bandColor,
    required this.trackColor,
    required this.tickColor,
    required this.dashed,
    required this.displayMaxPct,
  });

  final double fraction;
  final Color bandColor;
  final Color trackColor;
  final Color tickColor;

  /// Incomplete profile: a dashed neutral ring, no band colour, no value arc.
  final bool dashed;

  final double displayMaxPct;

  static const double _strokeWidth = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height)
        .deflate(_strokeWidth / 2 + 2);

    if (dashed) {
      _paintDashedTrack(canvas, rect);
      return;
    }

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

    // Band boundaries as ticks, so arc length reads against the clinical bands
    // rather than an arbitrary 0-100 scale.
    for (final boundaryPct in <double>[10, 20]) {
      _paintTick(canvas, rect, boundaryPct / displayMaxPct);
    }

    if (fraction > 0) {
      canvas.drawArc(
        rect,
        _startAngle,
        _sweepAngle * fraction,
        false,
        Paint()
          ..color = bandColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = _strokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _paintTick(Canvas canvas, Rect rect, double at) {
    final angle = _startAngle + _sweepAngle * at;
    final center = rect.center;
    final outer = rect.width / 2 + _strokeWidth / 2;
    final inner = rect.width / 2 - _strokeWidth / 2;

    canvas.drawLine(
      Offset(center.dx + math.cos(angle) * inner, center.dy + math.sin(angle) * inner),
      Offset(center.dx + math.cos(angle) * outer, center.dy + math.sin(angle) * outer),
      Paint()
        ..color = tickColor
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  void _paintDashedTrack(Canvas canvas, Rect rect) {
    const dashCount = 40;
    final paint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.butt;

    final dash = _sweepAngle / (dashCount * 2 - 1);
    for (var i = 0; i < dashCount; i++) {
      canvas.drawArc(rect, _startAngle + dash * 2 * i, dash, false, paint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction ||
      old.bandColor != bandColor ||
      old.trackColor != trackColor ||
      old.dashed != dashed;
}
