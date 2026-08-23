/// Stat tile for a single vital.
///
/// A vital is one current value plus a trend, which is a stat tile — not a
/// one-bar bar chart (docs/design.md §8). Four vitals means four independent
/// tiles, never one chart with four y-scales.
///
/// Out-of-range state is carried by an **icon plus the threshold text**, not by
/// colour. Same reasoning as the risk band: colour alone is not a safe channel
/// for clinical meaning.
///
/// That rule now also buys contrast. The flagged label and threshold note used to
/// be drawn *in* the status hue, which put 13px text at 3.62:1 for the High red —
/// under AA. The words are `inkPrimary` on the tonal fill instead (15.1:1), and
/// the hue is carried by the icon and the chip, which need 3:1.
library;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'mec_card.dart';

enum VitalRange {
  normal,
  watch,
  outOfRange;

  IconData? get icon => switch (this) {
        VitalRange.normal => null,
        VitalRange.watch => Icons.trending_up,
        VitalRange.outOfRange => Icons.warning_amber_rounded,
      };
}

class VitalTile extends StatelessWidget {
  const VitalTile({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    this.trend = const <double>[],
    this.range = VitalRange.normal,
    this.thresholdNote,
    this.onTap,
  });

  final String label;
  final String value;
  final String unit;

  /// Recent history, oldest first. Rendered as a sparkline; 12 points is plenty.
  final List<double> trend;

  final VitalRange range;

  /// Shown when [range] is not normal — e.g. "below 95%". The threshold in words,
  /// so the tile never relies on colour to say something is wrong.
  final String? thresholdNote;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final flagged = range != VitalRange.normal;
    final accent = range == VitalRange.outOfRange
        ? MecRiskBand.high.color
        : range == VitalRange.watch
            ? MecRiskBand.moderate.color
            : c.series1;

    return MecCard(
      onTap: onTap,
      surface: flagged ? c.containerFor(accent) : c.card,
      border: flagged ? accent.withValues(alpha: 0.3) : c.hairline,
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MecType.label.copyWith(
                    color: flagged ? c.inkPrimary : c.inkSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (flagged)
                Container(
                  padding: const EdgeInsets.all(MecSpace.s4),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: MecState.drag),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(range.icon, size: 14, color: accent),
                ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          // Value and unit on one baseline.
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MecType.statValue.copyWith(
                    color: c.inkPrimary,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: MecSpace.s4),
                Text(
                  unit,
                  style: MecType.label.copyWith(
                    color: c.inkMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
          if (flagged && thresholdNote != null) ...[
            const SizedBox(height: MecSpace.s6),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: MecSpace.s8,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: MecState.drag),
                borderRadius: BorderRadius.circular(MecRadius.chip),
              ),
              child: Text(
                thresholdNote!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MecType.axisTick.copyWith(
                  color: c.inkPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (trend.length >= 2)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: MecSpace.s8),
                child: SizedBox(
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _SparklinePainter(
                      points: trend,
                      color: c.series1,
                      endDotColor: accent,
                      surfaceColor: c.card,
                    ),
                  ),
                ),
              ),
            )
          else
            const Spacer(),
        ],
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({
    required this.points,
    required this.color,
    required this.endDotColor,
    required this.surfaceColor,
  });

  final List<double> points;
  final Color color;
  final Color endDotColor;
  final Color surfaceColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final lo = points.reduce((a, b) => a < b ? a : b);
    final hi = points.reduce((a, b) => a > b ? a : b);
    // A flat series would divide by zero; centre it instead.
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;

    final dx = size.width / (points.length - 1);
    // Inset so the 2px surface ring on the end dot is never clipped.
    const inset = 5.0;
    final usable = size.height - inset * 2;

    final path = Path();
    late Offset last;
    for (var i = 0; i < points.length; i++) {
      final x = dx * i;
      final y = inset + usable * (1 - (points[i] - lo) / span);
      final p = Offset(x, y);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
      last = p;
    }

    // Area wash at 10% — a wash, never a saturated block.
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.10));

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = MecChart.lineWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // End marker: >=8px diameter, with a 2px surface ring so it stays legible
    // where it crosses the line.
    canvas.drawCircle(last, MecChart.markerMinSize / 2 + MecChart.surfaceRing,
        Paint()..color = surfaceColor);
    canvas.drawCircle(last, MecChart.markerMinSize / 2, Paint()..color = endDotColor);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.points != points || old.color != color || old.endDotColor != endDotColor;
}
