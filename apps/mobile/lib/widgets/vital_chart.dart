/// Full-size trend chart for one vital.
///
/// Larger sibling of the sparkline in `vital_tile.dart`: axis labels, a reference
/// band, and gaps where the device was not reporting.
///
/// ### One vital per chart
///
/// Deliberately single-series. Two vitals on one plot needs two y-scales, and the
/// alignment between them is arbitrary — the chart then invents a correlation that
/// is not in the data (docs/design.md §8). Heart rate and SpO₂ get separate charts
/// on separate screens.
///
/// ### Gaps are drawn as gaps
///
/// X position is proportional to **time**, not to array index, and a break longer
/// than [gapThreshold] leaves the line broken rather than joined. The watch is
/// removed at night and the phone loses signal; joining across an eight-hour
/// absence would draw a confident straight line through hours when nothing was
/// measured, which is the chart asserting data it does not have.
library;

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vital_spec.dart';
import '../models/vitals.dart';

class VitalChart extends StatelessWidget {
  const VitalChart({
    super.key,
    required this.spec,
    required this.readings,
    this.height = 200,
    this.gapThreshold = const Duration(minutes: 12),
  });

  final VitalSpec spec;

  /// Oldest first.
  final List<VitalsReading> readings;

  final double height;

  /// A break longer than this is drawn as a break in the line.
  final Duration gapThreshold;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    final points = <_Point>[];
    for (final reading in readings) {
      final value = spec.read(reading);
      if (value != null) {
        points.add(_Point(reading.measuredAt, value));
      }
    }

    if (points.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            points.isEmpty
                ? 'No ${spec.title.toLowerCase()} recorded in this period'
                : 'Only one reading in this period — not enough for a trend',
            textAlign: TextAlign.center,
            style: MecType.label.copyWith(color: c.inkMuted),
          ),
        ),
      );
    }

    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _VitalChartPainter(
          spec: spec,
          points: points,
          gapThreshold: gapThreshold,
          line: c.series1,
          gridline: c.gridline,
          baseline: c.baseline,
          ink: c.inkMuted,
          surface: c.card,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

@immutable
class _Point {
  const _Point(this.at, this.value);
  final DateTime at;
  final double value;
}

class _VitalChartPainter extends CustomPainter {
  const _VitalChartPainter({
    required this.spec,
    required this.points,
    required this.gapThreshold,
    required this.line,
    required this.gridline,
    required this.baseline,
    required this.ink,
    required this.surface,
  });

  final VitalSpec spec;
  final List<_Point> points;
  final Duration gapThreshold;
  final Color line;
  final Color gridline;
  final Color baseline;
  final Color ink;
  final Color surface;

  /// Room for the y-axis labels and the time labels below the plot.
  static const double _leftGutter = 34;
  static const double _bottomGutter = 18;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
      _leftGutter,
      6,
      size.width - 6,
      size.height - _bottomGutter,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    var minValue = points.first.value;
    var maxValue = points.first.value;
    for (final point in points) {
      minValue = point.value < minValue ? point.value : minValue;
      maxValue = point.value > maxValue ? point.value : maxValue;
    }

    // The reference band is inside the scale, so a reading sitting outside the
    // normal range is visibly outside it rather than rescaling the band away.
    final refMin = spec.normalMin;
    final refMax = spec.normalMax;
    if (refMin != null) minValue = refMin < minValue ? refMin : minValue;
    if (refMax != null && refMax <= 100) {
      maxValue = refMax > maxValue ? refMax : maxValue;
    }

    // A flat series would divide by zero and draw on the top edge.
    final span = (maxValue - minValue).abs() < 0.5 ? 1.0 : maxValue - minValue;
    final pad = span * 0.12;
    final lo = minValue - pad;
    final hi = maxValue + pad;

    final tMin = points.first.at.millisecondsSinceEpoch;
    final tMax = points.last.at.millisecondsSinceEpoch;
    final tSpan = (tMax - tMin) == 0 ? 1 : tMax - tMin;

    double xFor(DateTime at) =>
        plot.left + ((at.millisecondsSinceEpoch - tMin) / tSpan) * plot.width;
    double yFor(double value) =>
        plot.bottom - ((value - lo) / (hi - lo)) * plot.height;

    // ── reference band ──
    if (refMin != null && refMax != null) {
      final top = yFor(refMax.clamp(lo, hi));
      final bottom = yFor(refMin.clamp(lo, hi));
      canvas.drawRect(
        Rect.fromLTRB(plot.left, top, plot.right, bottom),
        Paint()..color = line.withValues(alpha: 0.06),
      );
    }

    // ── gridlines: solid hairlines, one step off the surface ──
    final gridPaint = Paint()
      ..color = gridline
      ..strokeWidth = 1;
    final labelStyle = MecType.axisTick.copyWith(color: ink);

    for (var i = 0; i <= 3; i++) {
      final value = lo + (i / 3) * (hi - lo);
      final y = yFor(value);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _text(
        canvas,
        value.toStringAsFixed(spec.decimals),
        Offset(plot.left - 6, y),
        labelStyle,
        alignRight: true,
      );
    }

    canvas.drawLine(
      Offset(plot.left, plot.bottom),
      Offset(plot.right, plot.bottom),
      Paint()
        ..color = baseline
        ..strokeWidth = 1,
    );

    // ── the series, broken across gaps ──
    final linePaint = Paint()
      ..color = line
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    var path = Path();
    var started = false;
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final offset = Offset(xFor(point.at), yFor(point.value));

      final brokeAfterGap = i > 0 &&
          point.at.difference(points[i - 1].at).abs() > gapThreshold;

      if (!started || brokeAfterGap) {
        if (started) canvas.drawPath(path, linePaint);
        path = Path()..moveTo(offset.dx, offset.dy);
        started = true;
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
    }
    if (started) canvas.drawPath(path, linePaint);

    // ── end marker: 8px with a 2px surface ring ──
    final last = points.last;
    final endpoint = Offset(xFor(last.at), yFor(last.value));
    canvas.drawCircle(endpoint, 4, Paint()..color = line);
    canvas.drawCircle(
      endpoint,
      4,
      Paint()
        ..color = surface
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );

    // ── time labels: first and last only ──
    _text(canvas, _clock(points.first.at), Offset(plot.left, plot.bottom + 4), labelStyle);
    _text(
      canvas,
      _clock(points.last.at),
      Offset(plot.right, plot.bottom + 4),
      labelStyle,
      alignRight: true,
    );
  }

  static String _clock(DateTime at) {
    final local = at.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  void _text(
    Canvas canvas,
    String value,
    Offset at,
    TextStyle style, {
    bool alignRight = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(alignRight ? at.dx - painter.width : at.dx, at.dy - painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(_VitalChartPainter old) =>
      old.points.length != points.length ||
      old.spec.kind != spec.kind ||
      (points.isNotEmpty &&
          old.points.isNotEmpty &&
          old.points.last.at != points.last.at);
}
