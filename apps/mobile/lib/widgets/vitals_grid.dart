/// The 2×2 grid of vital stat tiles.
///
/// Four vitals means four independent tiles, never one chart with four y-scales
/// (docs/design.md §8). Extracted from `home_screen.dart` along with the sampling
/// and flag-matching logic that feeds it.
///
/// Geometry is pinned: `crossAxisCount: 2`, 12px gutters, `childAspectRatio: 1.15`.
/// `SkeletonVitalsGrid` mirrors these exactly so nothing shifts when data lands,
/// and `test/widget_test.dart` asserts a tile fits the 158×137 cell that results.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import '../models/vitals.dart';
import 'mec_stagger.dart';
import 'vital_tile.dart';

class VitalsGrid extends StatelessWidget {
  const VitalsGrid({super.key, required this.history, required this.flags});

  final List<VitalsReading> history;
  final List<AcuteFlag> flags;

  /// Keep the last ~120 readings (a minute at 2Hz), thinned 4:1 for the sparkline.
  List<double> _trend(double? Function(VitalsReading) pick) {
    const maxSamples = 120;
    final tail = history.length <= maxSamples
        ? history
        : history.sublist(history.length - maxSamples);

    final sampled = <double>[];
    for (var i = 0; i < tail.length; i += 4) {
      final v = pick(tail[i]);
      if (v != null) sampled.add(v);
    }
    return sampled;
  }

  AcuteFlag? _flagFor(String vital) =>
      flags.where((f) => f.vital == vital).firstOrNull;

  VitalRange _rangeFor(String vital) => switch (_flagFor(vital)?.severity) {
        Severity.critical => VitalRange.outOfRange,
        Severity.warning => VitalRange.outOfRange,
        Severity.info => VitalRange.watch,
        null => VitalRange.normal,
      };

  @override
  Widget build(BuildContext context) {
    final latest = history.isEmpty ? null : history.last;
    if (latest == null) return const SizedBox.shrink();

    final tiles = <Widget>[
      VitalTile(
        label: 'Heart rate',
        value: latest.heartRateDisplay,
        unit: latest.heartRateBpm == null ? '' : 'bpm',
        trend: _trend((r) => r.heartRateBpm),
        range: _rangeFor('Heart rate'),
        thresholdNote: _flagFor('Heart rate')?.threshold,
      ),
      VitalTile(
        label: 'Blood oxygen',
        value: latest.spo2Display,
        unit: latest.spo2Pct == null ? '' : '%',
        trend: _trend((r) => r.spo2Pct),
        range: _rangeFor('SpO2'),
        thresholdNote: _flagFor('SpO2')?.threshold,
      ),
      VitalTile(
        label: 'Body temperature',
        value: latest.bodyTempDisplay,
        unit: latest.bodyTempC == null ? '' : '°C',
        trend: _trend((r) => r.bodyTempC),
        range: _rangeFor('Temperature'),
        thresholdNote: _flagFor('Temperature')?.threshold,
      ),
    ];

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: MecSpace.s12,
      crossAxisSpacing: MecSpace.s12,
      childAspectRatio: 1.15,
      children: [
        for (var i = 0; i < tiles.length; i++)
          MecStagger(index: i, child: tiles[i]),
      ],
    );
  }
}
