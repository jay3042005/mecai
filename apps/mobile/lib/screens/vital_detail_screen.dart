/// One vital, in full: current value, trend, day summary, and what it means.
///
/// Driven by a [VitalSpec] so heart rate, blood oxygen and the estimated body
/// temperature each get their own screen without three copies of the same chart
/// and layout code. The thin per-vital entry points are `heart_rate_screen.dart`,
/// `oxygen_screen.dart` and `temperature_screen.dart`.
///
/// ### Alarms are visual
///
/// An out-of-range reading raises a persistent banner and a coloured range chip,
/// each carrying an icon and the threshold **in words**. No sound: this screen can
/// be open in a shared room, and browsers and phones both gate audio behind
/// permissions that would make the alarm unreliable — an alarm that sometimes does
/// not fire is worse than one that never claims to.
///
/// The banner does not disappear on its own. An alert the user has not
/// acknowledged is still true, and auto-dismissing it after a few seconds would
/// mean the one glance they took was the one that missed it.
library;

import 'package:flutter/material.dart';

import '../data/monitor_controller.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vital_spec.dart';
import '../models/vitals.dart';
import '../widgets/mec_card.dart';
import '../widgets/mec_stagger.dart';
import '../widgets/vital_chart.dart';

/// Trend windows offered on the detail screen.
enum VitalWindow {
  hour(Duration(hours: 1), '1H'),
  sixHours(Duration(hours: 6), '6H'),
  day(Duration(hours: 24), '24H'),
  week(Duration(days: 7), '7D');

  const VitalWindow(this.span, this.label);
  final Duration span;
  final String label;
}

class VitalDetailScreen extends StatefulWidget {
  const VitalDetailScreen({
    super.key,
    required this.spec,
    required this.controller,
  });

  final VitalSpec spec;
  final MonitorController controller;

  @override
  State<VitalDetailScreen> createState() => _VitalDetailScreenState();
}

class _VitalDetailScreenState extends State<VitalDetailScreen> {
  VitalWindow _window = VitalWindow.sixHours;
  List<VitalsReading> _readings = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onLive);
    _load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onLive);
    super.dispose();
  }

  /// The live stream only ever appends, so a new packet does not need a reload of
  /// the window — the in-memory tail already carries it.
  void _onLive() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final store = widget.controller.store;
    if (store == null) {
      // No archive: fall back to the in-memory window, which is all that exists.
      setState(() {
        _readings = widget.controller.history;
        _loading = false;
      });
      return;
    }

    setState(() => _loading = true);
    try {
      final rows = await store.recent(window: _window.span, limit: 2000);
      if (!mounted) return;
      setState(() {
        _readings = rows;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _readings = widget.controller.history;
        _loading = false;
      });
    }
  }

  /// Archive rows plus anything that has arrived since they were read.
  ///
  /// Without the tail, a chart on a live screen would freeze at whatever the last
  /// query returned and only move when the window changed.
  List<VitalsReading> get _series {
    if (_readings.isEmpty) return widget.controller.history;
    final cutoff = _readings.last.measuredAt;
    final tail = widget.controller.history
        .where((r) => r.measuredAt.isAfter(cutoff))
        .toList(growable: false);
    return [..._readings, ...tail];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final spec = widget.spec;
    final controller = widget.controller;

    final series = _series;
    final current = controller.latest == null ? null : spec.read(controller.latest!);
    final flag = spec.flagVital.isEmpty
        ? null
        : controller.acuteFlags.where((f) => f.vital == spec.flagVital).firstOrNull;

    final values = [
      for (final reading in series)
        if (spec.read(reading) != null) spec.read(reading)!,
    ];

    return Scaffold(
      appBar: AppBar(title: Text(spec.title)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            MecSpace.s16,
            MecSpace.s16,
            MecSpace.s16,
            MecSpace.s48,
          ),
          children: [
            if (flag != null) ...[
              _AlarmBanner(flag: flag),
              const SizedBox(height: MecSpace.s16),
            ],

            _CurrentValue(spec: spec, value: current, flag: flag),
            const SizedBox(height: MecSpace.s20),

            _WindowPicker(
              selected: _window,
              onSelect: (window) {
                setState(() => _window = window);
                _load();
              },
            ),
            const SizedBox(height: MecSpace.s12),

            MecCard(
              child: AnimatedOpacity(
                // Held at reduced opacity rather than replaced by a skeleton:
                // swapping live content for a placeholder reads as data loss.
                opacity: _loading && _readings.isNotEmpty ? 0.55 : 1,
                duration: context.stilled(MecMotion.fast),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Last ${_window.label}',
                          style: MecType.label.copyWith(color: c.inkSecondary),
                        ),
                        if (spec.normalLabel != null)
                          Text(
                            spec.normalLabel!,
                            style: MecType.label.copyWith(color: c.inkMuted),
                          ),
                      ],
                    ),
                    const SizedBox(height: MecSpace.s12),
                    VitalChart(spec: spec, readings: series),
                  ],
                ),
              ),
            ),

            const SizedBox(height: MecSpace.s16),
            _Summary(spec: spec, values: values, readingCount: series.length),

            const SizedBox(height: MecSpace.s16),
            _About(spec: spec),
          ],
        ),
      ),
    );
  }
}

/// Persistent, dismiss-free alert. See the library docstring on why it stays put.
class _AlarmBanner extends StatelessWidget {
  const _AlarmBanner({required this.flag});

  final AcuteFlag flag;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final (color, icon, word) = switch (flag.severity) {
      Severity.critical =>
        (MecRiskBand.high.color, Icons.dangerous_outlined, 'CRITICAL'),
      Severity.warning =>
        (MecRiskBand.moderate.color, Icons.warning_amber_rounded, 'WARNING'),
      Severity.info => (c.series1, Icons.info_outline, 'NOTE'),
    };

    return Container(
      padding: const EdgeInsets.all(MecSpace.s16),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: MecState.press), c.card),
        borderRadius: BorderRadius.circular(MecRadius.card),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: MecSpace.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The word, not just the hue: low↔high measures ΔE 4.1 under
                // deuteranopia, so severity is never carried by colour alone.
                Text(
                  '$word · ${flag.displayValue}',
                  style: MecType.label.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: MecSpace.s4),
                Text(
                  flag.message,
                  style: MecType.body.copyWith(color: c.inkPrimary),
                ),
                const SizedBox(height: MecSpace.s4),
                Text(
                  '${flag.recommendation}\nThreshold: ${flag.threshold}.',
                  style: MecType.label.copyWith(color: c.inkSecondary, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CurrentValue extends StatelessWidget {
  const _CurrentValue({required this.spec, required this.value, required this.flag});

  final VitalSpec spec;
  final double? value;
  final AcuteFlag? flag;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    final flagged = flag != null;

    return MecCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(spec.icon, size: 18, color: c.inkSecondary),
              const SizedBox(width: MecSpace.s8),
              Text(
                'Current',
                style: MecType.label.copyWith(color: c.inkSecondary),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${spec.estimated && value != null ? '~' : ''}${spec.format(value)}',
                // Proportional figures: tabular digits make a large standalone
                // number look loose.
                style: MecType.heroFigure.copyWith(
                  color: c.inkPrimary,
                  fontSize: 52,
                ),
              ),
              const SizedBox(width: MecSpace.s6),
              Text(
                value == null ? '' : spec.unit,
                style: MecType.body.copyWith(color: c.inkMuted),
              ),
            ],
          ),
          if (!spec.clinical) ...[
            const SizedBox(height: MecSpace.s8),
            Row(
              children: [
                Icon(Icons.info_outline, size: 14, color: c.inkMuted),
                const SizedBox(width: MecSpace.s6),
                Expanded(
                  child: Text(
                    spec.estimated
                        ? 'Estimate only — never used for health alerts.'
                        : 'Context only — never used for health alerts.',
                    style: MecType.label.copyWith(color: c.inkMuted),
                  ),
                ),
              ],
            ),
          ] else if (!flagged && value != null && spec.normalMin != null) ...[
            const SizedBox(height: MecSpace.s8),
            Row(
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 14,
                  color: MecRiskBand.low.color,
                ),
                const SizedBox(width: MecSpace.s6),
                Text(
                  'Within the normal range',
                  style: MecType.label.copyWith(color: c.inkSecondary),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _WindowPicker extends StatelessWidget {
  const _WindowPicker({required this.selected, required this.onSelect});

  final VitalWindow selected;
  final ValueChanged<VitalWindow> onSelect;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<VitalWindow>(
      segments: [
        for (final window in VitalWindow.values)
          ButtonSegment(value: window, label: Text(window.label)),
      ],
      selected: {selected},
      showSelectedIcon: false,
      onSelectionChanged: (selection) => onSelect(selection.first),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.spec,
    required this.values,
    required this.readingCount,
  });

  final VitalSpec spec;
  final List<double> values;
  final int readingCount;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    if (values.isEmpty) {
      return MecCard(
        child: Text(
          readingCount == 0
              ? 'Nothing recorded in this period.'
              : 'The device did not report ${spec.title.toLowerCase()} in this period.',
          style: MecType.label.copyWith(color: c.inkMuted),
        ),
      );
    }

    var min = values.first;
    var max = values.first;
    var total = 0.0;
    for (final value in values) {
      if (value < min) min = value;
      if (value > max) max = value;
      total += value;
    }

    return MecCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Summary',
            style: MecType.sectionTitle.copyWith(color: c.inkPrimary),
          ),
          const SizedBox(height: MecSpace.s12),
          Row(
            children: [
              for (final entry in <(String, double)>[
                ('Lowest', min),
                ('Average', total / values.length),
                ('Highest', max),
              ])
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.$1,
                        style: MecType.label.copyWith(color: c.inkSecondary),
                      ),
                      const SizedBox(height: MecSpace.s2),
                      Text(
                        spec.format(entry.$2),
                        style: MecType.statValue.copyWith(color: c.inkPrimary),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: MecSpace.s12),
          Text(
            '$readingCount reading${readingCount == 1 ? '' : 's'} in this period.',
            style: MecType.label.copyWith(color: c.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _About extends StatelessWidget {
  const _About({required this.spec});

  final VitalSpec spec;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;
    return MecStagger(
      index: 1,
      child: MecCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'About this measurement',
              style: MecType.sectionTitle.copyWith(color: c.inkPrimary),
            ),
            const SizedBox(height: MecSpace.s8),
            Text(
              spec.about,
              style: MecType.body.copyWith(color: c.inkSecondary, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
