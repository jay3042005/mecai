/// Analytics — browse recorded days and read back what the watch measured.
///
/// The live screens answer "what is happening now". This answers "what happened on
/// the 14th", which needs a different shape: a calendar to pick the day, then that
/// day's charts and summary.
///
/// ### Read from the archive, not from the live buffer
///
/// Every figure here comes from local SQLite, so it works with no network and shows
/// the same numbers whether or not the phone has ever reached the server. The
/// archive is the phone's own record; the server holds a backup copy of it.
library;

import 'package:flutter/material.dart';

import '../data/acute_flags.dart';
import '../data/monitor_controller.dart';
import '../data/reading_store.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vital_spec.dart';
import '../models/vitals.dart';
import '../widgets/mec_bottom_nav.dart';
import '../widgets/mec_calendar.dart';
import '../widgets/mec_card.dart';
import '../widgets/mec_stagger.dart';
import '../widgets/vital_chart.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key, required this.controller});

  final MonitorController controller;

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  late DateTime _month;
  late DateTime _selected;

  Map<DateTime, DayStats> _stats = const {};
  Set<DateTime> _alertDays = const {};
  List<VitalsReading> _dayReadings = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selected = DateTime(now.year, now.month, now.day);
    _month = DateTime(now.year, now.month);
    _load();
  }

  Future<void> _load() async {
    final store = widget.controller.store;
    if (store == null) {
      setState(() => _loading = false);
      return;
    }

    setState(() => _loading = true);
    try {
      final monthEnd = DateTime(_month.year, _month.month + 1, 0);
      final stats = await store.dailyStats(from: _month, to: monthEnd);
      final readings = await store.readingsForDay(_selected);
      if (!mounted) return;

      setState(() {
        _stats = stats;
        _alertDays = _flagDays(stats);
        _dayReadings = readings;
        _loading = false;
      });
    } on Object catch (error) {
      debugPrint('AnalyticsScreen: could not read the archive. $error');
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Days whose aggregates already breach an alert threshold.
  ///
  /// Derived from the day's *extremes* (lowest SpO₂, highest and lowest heart rate),
  /// not its averages: a day averaging 97% with one dip to 86% is exactly the day
  /// worth marking, and the average conceals it.
  ///
  /// Evaluated through the same `evaluateAcuteFlags` the live path uses, so the
  /// calendar's dots and the alert cards can never disagree about what counts as
  /// out of range.
  Set<DateTime> _flagDays(Map<DateTime, DayStats> stats) {
    final days = <DateTime>{};
    for (final entry in stats.entries) {
      final day = entry.value;
      final probes = <VitalsReading>[
        if (day.spo2Min != null)
          VitalsReading(spo2Pct: day.spo2Min, measuredAt: entry.key),
        if (day.heartRateMin != null)
          VitalsReading(heartRateBpm: day.heartRateMin, measuredAt: entry.key),
        if (day.heartRateMax != null)
          VitalsReading(heartRateBpm: day.heartRateMax, measuredAt: entry.key),
        if (day.bodyTempMax != null)
          VitalsReading(temperatureC: day.bodyTempMax, measuredAt: entry.key),
      ];
      if (probes.any((reading) => evaluateAcuteFlags(reading).isNotEmpty)) {
        days.add(entry.key);
      }
    }
    return days;
  }

  void _selectDay(DateTime day) {
    setState(() => _selected = day);
    _load();
  }

  void _changeMonth(DateTime month) {
    setState(() => _month = month);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final entry = _stats[_selected];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          MecSpace.s16,
          MecSpace.s24,
          MecSpace.s16,
          // Clears the floating nav, so the last card is reachable.
          MecBottomNav.reservedHeight,
        ),
        children: [
          Text(
            'Analytics',
            style: MecType.sectionTitle.copyWith(
              color: c.inkPrimary,
              fontSize: 24,
            ),
          ),
          const SizedBox(height: MecSpace.s4),
          Text(
            'Pick a day to read back what the watch recorded.',
            style: MecType.label.copyWith(color: c.inkSecondary),
          ),
          const SizedBox(height: MecSpace.s16),

          if (widget.controller.store == null)
            const _NoArchive()
          else ...[
            MecCard(
              child: MecCalendar(
                month: _month,
                stats: _stats,
                selected: _selected,
                alertDays: _alertDays,
                onSelect: _selectDay,
                onMonthChange: _changeMonth,
              ),
            ),
            const SizedBox(height: MecSpace.s16),

            AnimatedOpacity(
              opacity: _loading ? 0.55 : 1,
              duration: context.stilled(MecMotion.fast),
              child: Column(
                children: [
                  _DaySummary(day: _selected, stats: entry),
                  const SizedBox(height: MecSpace.s12),
                  if (_dayReadings.isNotEmpty)
                    for (var i = 0; i < VitalSpec.all.length; i++) ...[
                      MecStagger(
                        index: i,
                        child: MecCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    VitalSpec.all[i].icon,
                                    size: 16,
                                    color: c.inkSecondary,
                                  ),
                                  const SizedBox(width: MecSpace.s8),
                                  Text(
                                    VitalSpec.all[i].title,
                                    style: MecType.body.copyWith(
                                      color: c.inkPrimary,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: MecSpace.s8),
                              VitalChart(
                                spec: VitalSpec.all[i],
                                readings: _dayReadings,
                                height: 140,
                                // A whole day is on screen, so only a real
                                // absence should break the line.
                                gapThreshold: const Duration(minutes: 30),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: MecSpace.s12),
                    ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DaySummary extends StatelessWidget {
  const _DaySummary({required this.day, required this.stats});

  final DateTime day;
  final DayStats? stats;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String get _label {
    final today = DateTime.now();
    final startOfToday = DateTime(today.year, today.month, today.day);
    if (day == startOfToday) return 'Today';
    if (day == startOfToday.subtract(const Duration(days: 1))) return 'Yesterday';
    return '${day.day} ${_months[day.month - 1]} ${day.year}';
  }

  /// The day's body temperature, from the watch's temperature sensor.
  ///
  /// Prefers [DayStats.bodyTempMax] when the firmware recorded a contact reading,
  /// and otherwise reports the watch sensor average — the same precedence
  /// `VitalSpec.bodyTemperature` uses, so the day summary and the Vitals tab
  /// report the same source.
  ///
  /// Averaged over **worn readings only** ([DayStats.ambientWornAvg]). The
  /// whole-day average includes hours the watch sat on a table, which is not the
  /// wearer's temperature at all; restricting to worn samples means a day the
  /// user wore the watch for two hours is summarised from those two hours.
  Widget _tempStat(DayStats entry) {
    final worn = entry.ambientWornAvg;
    final value = entry.bodyTempMax ?? worn;

    return _Stat(
      label: 'Body temp',
      value: value == null
          ? VitalsReading.absent
          : value.toStringAsFixed(1),
      unit: '°C avg',
      // Says why there is no figure, rather than leaving a bare em-dash that
      // reads as a broken sensor.
      detail: value != null
          ? null
          : entry.ambientAvg == null
              ? null
              : 'watch not worn',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final entry = stats;

    if (entry == null || entry.readingCount == 0) {
      return MecCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_label, style: MecType.sectionTitle.copyWith(color: c.inkPrimary)),
            const SizedBox(height: MecSpace.s8),
            Text(
              'No readings recorded. The watch was either not worn or not '
              'connected to the phone.',
              style: MecType.label.copyWith(color: c.inkMuted, height: 1.4),
            ),
          ],
        ),
      );
    }

    return MecCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _label,
                  style: MecType.sectionTitle.copyWith(color: c.inkPrimary),
                ),
              ),
              Text(
                '${entry.readingCount} readings',
                style: MecType.label.copyWith(color: c.inkMuted),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s12),
          Wrap(
            spacing: MecSpace.s24,
            runSpacing: MecSpace.s12,
            children: [
              _Stat(
                label: 'Heart rate',
                value: entry.heartRateAvg == null
                    ? VitalsReading.absent
                    : entry.heartRateAvg!.toStringAsFixed(0),
                unit: 'bpm avg',
                detail: entry.heartRateMin == null || entry.heartRateMax == null
                    ? null
                    : '${entry.heartRateMin!.toStringAsFixed(0)}–'
                        '${entry.heartRateMax!.toStringAsFixed(0)}',
              ),
              _Stat(
                label: 'Blood oxygen',
                // The day's minimum, not its mean: for oxygen the extreme is the
                // clinically interesting figure.
                value: entry.spo2Min == null
                    ? VitalsReading.absent
                    : entry.spo2Min!.toStringAsFixed(0),
                unit: '% lowest',
                detail: entry.spo2Avg == null
                    ? null
                    : '${entry.spo2Avg!.toStringAsFixed(0)}% average',
              ),
              _tempStat(entry),
            ],
          ),
          if (entry.mostlyWorn == false) ...[
            const SizedBox(height: MecSpace.s12),
            Row(
              children: [
                Icon(Icons.watch_off_outlined, size: 14, color: c.inkMuted),
                const SizedBox(width: MecSpace.s6),
                Expanded(
                  child: Text(
                    'The watch reported no skin contact for most of this day, so '
                    'these readings may not reflect you.',
                    style: MecType.label.copyWith(color: c.inkMuted, height: 1.4),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.unit,
    this.detail,
  });

  final String label;
  final String value;
  final String unit;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: MecType.label.copyWith(color: c.inkSecondary)),
        const SizedBox(height: MecSpace.s2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value, style: MecType.statValue.copyWith(color: c.inkPrimary)),
            const SizedBox(width: MecSpace.s4),
            Text(unit, style: MecType.label.copyWith(color: c.inkMuted)),
          ],
        ),
        if (detail != null)
          Text(detail!, style: MecType.label.copyWith(color: c.inkMuted)),
      ],
    );
  }
}

class _NoArchive extends StatelessWidget {
  const _NoArchive();

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return MecCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sd_card_alert_outlined, size: 18, color: c.inkSecondary),
              const SizedBox(width: MecSpace.s8),
              Text(
                'No archive on this device',
                style: MecType.body.copyWith(color: c.inkPrimary),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          Text(
            'Local storage could not be opened, so past days cannot be read back. '
            'Live monitoring and alerts are unaffected.',
            style: MecType.label.copyWith(color: c.inkMuted, height: 1.4),
          ),
        ],
      ),
    );
  }
}
