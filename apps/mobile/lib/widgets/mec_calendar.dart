/// Month calendar for browsing recorded days.
///
/// ### Encoding
///
/// Coverage — how much of a day the watch recorded — is a **magnitude**, so it uses
/// one hue light→dark from `MecSequential.blue` rather than a set of unrelated
/// colours. A rainbow of day colours would imply the days differ in kind when they
/// differ only in amount.
///
/// A day carrying an out-of-range reading is a **state**, not a magnitude, so it
/// gets the status palette *plus a dot marker* — never hue alone. Low↔high measures
/// ΔE 4.1 under deuteranopia (see `packages/tokens/tokens.json` → `$meta.validation`),
/// so a reader who cannot separate red from green still sees the marker.
///
/// ### Days with nothing
///
/// Rendered as an outline, not as a zero-value step of the ramp. "The watch was not
/// worn" and "the watch recorded a quiet day" are different facts, and the palest
/// step of a sequential ramp reads as the second.
library;

import 'package:flutter/material.dart';

import '../data/reading_store.dart';
import '../design/theme.dart';
import '../design/tokens.dart';

class MecCalendar extends StatelessWidget {
  const MecCalendar({
    super.key,
    required this.month,
    required this.stats,
    required this.selected,
    required this.onSelect,
    required this.onMonthChange,
    this.alertDays = const {},
  });

  /// Any date inside the month being shown.
  final DateTime month;

  /// Per-day aggregates, keyed by midnight-local.
  final Map<DateTime, DayStats> stats;

  final DateTime selected;
  final ValueChanged<DateTime> onSelect;
  final ValueChanged<DateTime> onMonthChange;

  /// Days holding at least one out-of-range reading.
  final Set<DateTime> alertDays;

  static const _weekdayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  DateTime get _firstOfMonth => DateTime(month.year, month.month);

  int get _daysInMonth => DateTime(month.year, month.month + 1, 0).day;

  /// Monday-first offset for the 1st of the month.
  int get _leadingBlanks => (_firstOfMonth.weekday - DateTime.monday) % 7;

  /// The highest single-day reading count in view, so the ramp is scaled to what
  /// is actually here. A fixed maximum would render a sparse month as uniformly
  /// pale and hide the variation within it.
  int get _peak {
    var peak = 0;
    for (final entry in stats.values) {
      if (entry.readingCount > peak) peak = entry.readingCount;
    }
    return peak;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final today = DateTime.now();
    final startOfToday = DateTime(today.year, today.month, today.day);

    return Column(
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => onMonthChange(
                DateTime(month.year, month.month - 1),
              ),
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous month',
            ),
            Expanded(
              child: Text(
                '${_monthNames[month.month - 1]} ${month.year}',
                textAlign: TextAlign.center,
                style: MecType.sectionTitle.copyWith(color: c.inkPrimary),
              ),
            ),
            IconButton(
              // Never past the current month: there is no data in the future, and
              // an empty grid for next March is a dead end.
              onPressed: (month.year == today.year && month.month == today.month)
                  ? null
                  : () => onMonthChange(DateTime(month.year, month.month + 1)),
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next month',
            ),
          ],
        ),
        const SizedBox(height: MecSpace.s8),
        Row(
          children: [
            for (final label in _weekdayLabels)
              Expanded(
                child: Center(
                  child: Text(
                    label,
                    style: MecType.axisTick.copyWith(color: c.inkMuted),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: MecSpace.s6),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisSpacing: MecSpace.s4,
            crossAxisSpacing: MecSpace.s4,
            childAspectRatio: 1,
          ),
          itemCount: _leadingBlanks + _daysInMonth,
          itemBuilder: (context, index) {
            if (index < _leadingBlanks) return const SizedBox.shrink();

            final day = DateTime(month.year, month.month, index - _leadingBlanks + 1);
            final entry = stats[day];
            final isFuture = day.isAfter(startOfToday);

            return _DayCell(
              day: day,
              stats: entry,
              peak: _peak,
              selected: day == selected,
              isToday: day == startOfToday,
              hasAlert: alertDays.contains(day),
              enabled: !isFuture,
              onTap: () => onSelect(day),
            );
          },
        ),
        const SizedBox(height: MecSpace.s12),
        _Legend(),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.stats,
    required this.peak,
    required this.selected,
    required this.isToday,
    required this.hasAlert,
    required this.enabled,
    required this.onTap,
  });

  final DateTime day;
  final DayStats? stats;
  final int peak;
  final bool selected;
  final bool isToday;
  final bool hasAlert;
  final bool enabled;
  final VoidCallback onTap;

  /// Position on the sequential ramp for this day's coverage.
  ///
  /// Starts at index 2 rather than 0: the first two steps are so pale against the
  /// card that a day with real readings would look like a day with none.
  Color? _fill() {
    final count = stats?.readingCount ?? 0;
    if (count == 0 || peak == 0) return null;
    const lowest = 2;
    final highest = MecSequential.blue.length - 1;
    final ratio = (count / peak).clamp(0.0, 1.0);
    final step = lowest + ((highest - lowest) * ratio).round();
    return MecSequential.blue[step];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final fill = _fill();
    final hasData = fill != null;

    // Ink chosen by the fill's luminance so the numeral clears contrast at both
    // ends of the ramp — the pale steps need dark ink, the deep steps need light.
    final numeralColor = !enabled
        ? c.inkMuted.withValues(alpha: 0.4)
        : hasData
            ? (ThemeData.estimateBrightnessForColor(fill) == Brightness.light
                ? MecSurfaceDark.page
                : Colors.white)
            : c.inkSecondary;

    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: fill ?? Colors.transparent,
        borderRadius: BorderRadius.circular(MecRadius.control),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(MecRadius.control),
              border: Border.all(
                color: selected
                    ? c.series1
                    : isToday
                        ? c.inkSecondary
                        : hasData
                            ? Colors.transparent
                            : c.hairline,
                width: selected ? 2 : 1,
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Text(
                  '${day.day}',
                  style: MecType.axisTick.copyWith(
                    color: numeralColor,
                    fontWeight: selected || isToday ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
                if (hasAlert)
                  Positioned(
                    bottom: 3,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: MecRiskBand.high.color,
                        shape: BoxShape.circle,
                        // A ring in the fill colour keeps the marker legible on
                        // the deepest steps of the ramp.
                        border: Border.all(color: fill ?? c.card, width: 1),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final style = MecType.label.copyWith(color: c.inkMuted, fontSize: 11);

    return Row(
      children: [
        Text('Less', style: style),
        const SizedBox(width: MecSpace.s6),
        for (final step in [2, 5, 8, 11])
          Container(
            width: 12,
            height: 12,
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              color: MecSequential.blue[step],
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        const SizedBox(width: MecSpace.s2),
        Text('More', style: style),
        const Spacer(),
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: MecRiskBand.high.color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: MecSpace.s4),
        Text('Alert', style: style),
      ],
    );
  }
}
