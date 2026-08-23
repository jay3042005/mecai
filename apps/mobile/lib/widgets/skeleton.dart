/// Skeleton loading placeholders.
///
/// **When to use a skeleton, and when not to.** A skeleton is for the *first* load,
/// where there is genuinely nothing to show. On a refetch — when data is already on
/// screen — hold the previous render at reduced opacity instead. Swapping real
/// content for a skeleton on refresh causes a layout jump and reads as data loss
/// (docs/design.md §8).
///
/// Shapes here mirror the real content's geometry so nothing shifts when data
/// arrives. A skeleton whose dimensions differ from what replaces it is worse than
/// a spinner.
///
/// All colours come from tokens — `gridline` for the base, `baseline` for the
/// shimmer highlight. No new greys are invented.
library;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';

/// Sweeps a highlight across every descendant skeleton shape.
///
/// One controller for the whole subtree rather than one per box. Under reduced
/// motion the sweep is dropped entirely and children render as flat blocks — a
/// looping gradient is exactly the kind of ambient motion §3.6 requires stopping.
class SkeletonShimmer extends StatefulWidget {
  const SkeletonShimmer({super.key, required this.child});

  final Widget child;

  @override
  State<SkeletonShimmer> createState() => _SkeletonShimmerState();
}

class _SkeletonShimmerState extends State<SkeletonShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: MecMotion.ambient, vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.reduceMotion) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (context.reduceMotion) return widget.child;

    final c = context.mec;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment(-1.0 + 3 * t, 0),
            end: Alignment(1.0 + 3 * t, 0),
            colors: <Color>[c.gridline, c.baseline, c.gridline],
          ).createShader(bounds),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// A rounded placeholder block.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.radius = 4,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: context.mec.gridline,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Placeholder for the risk ring.
///
/// Draws the same 270° track at the same stroke width and diameter as the real
/// ring, so the layout is identical before and after the score arrives. No band
/// colour appears — a skeleton must never suggest a risk level.
class SkeletonRiskRing extends StatelessWidget {
  const SkeletonRiskRing({super.key, this.diameter = 260});

  final double diameter;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: diameter,
          height: diameter,
          child: CustomPaint(
            painter: _RingTrackPainter(color: context.mec.gridline),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: const [
                  SkeletonBox(width: 108, height: 18, radius: MecRadius.pill),
                  SizedBox(height: MecSpace.s12),
                  SkeletonBox(width: 132, height: 52, radius: MecRadius.xs),
                  SizedBox(height: MecSpace.s12),
                  SkeletonBox(width: 96, height: 13, radius: MecRadius.pill),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: MecSpace.s16),
        const SkeletonBox(width: 128, height: 42, radius: MecRadius.pill),
        const SizedBox(height: MecSpace.s12),
        const SkeletonBox(width: 220, height: 12, radius: MecRadius.pill),
      ],
    );
  }
}

class _RingTrackPainter extends CustomPainter {
  const _RingTrackPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 14.0;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height)
        .deflate(strokeWidth / 2 + 2);

    // Same geometry as RiskRing: 270° starting lower-left.
    canvas.drawArc(
      rect,
      3.14159 * 0.75,
      3.14159 * 1.5,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingTrackPainter old) => old.color != color;
}

/// Placeholder matching [VitalTile]'s internal layout.
class SkeletonVitalTile extends StatelessWidget {
  const SkeletonVitalTile({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(MecRadius.card),
        border: Border.all(color: c.hairline),
      ),
      padding: const EdgeInsets.all(MecSpace.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: const [
          SkeletonBox(width: 84, height: 13, radius: MecRadius.pill),
          SizedBox(height: MecSpace.s12),
          SkeletonBox(width: 68, height: 26, radius: 6),
          SizedBox(height: MecSpace.s16),
          SkeletonBox(height: 28, radius: 6),
        ],
      ),
    );
  }
}

/// The 2×2 vitals grid as skeletons, matching the real grid's spacing and ratio.
class SkeletonVitalsGrid extends StatelessWidget {
  const SkeletonVitalsGrid({super.key});

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: MecSpace.s12,
      crossAxisSpacing: MecSpace.s12,
      childAspectRatio: 1.15,
      children: const [
        SkeletonVitalTile(),
        SkeletonVitalTile(),
        SkeletonVitalTile(),
      ],
    );
  }
}
