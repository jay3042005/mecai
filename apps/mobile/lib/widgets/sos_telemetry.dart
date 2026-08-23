/// The live telemetry block on the SOS screen — what dispatch is receiving.
///
/// Extracted from `sos_emergency_screen.dart`.
///
/// The three readings wear the **data hue**, not one accent each. The version
/// this replaces used `Colors.redAccent`, `Colors.cyanAccent` and
/// `Colors.orangeAccent`, which put three off-palette hues on the one screen
/// where red already means something specific. Blue is data; red and green are
/// reserved for clinical status (docs/design.md §3.3).
library;

import 'package:flutter/material.dart';

import '../data/location_service.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/vitals.dart';

class SosTelemetryCard extends StatelessWidget {
  const SosTelemetryCard({
    super.key,
    required this.reading,
    required this.surface,
    this.fix,
    this.locating = false,
  });

  final VitalsReading? reading;

  /// The real fix that was captured for this SOS, or null while it is being
  /// acquired / if none could be had. This line used to be the literal string
  /// 'GPS: Tacurong City, Sultan Kudarat (High accuracy)' — a hardcoded place
  /// name shown regardless of where the phone was or whether the GPS had read
  /// anything at all. On an emergency screen that is a lie about the one field a
  /// responder acts on.
  final LocationFix? fix;

  /// True while the fix attempt is still running.
  final bool locating;

  /// The SOS screen's own tinted surface, so the nested card steps up from it.
  final Color surface;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Container(
      padding: const EdgeInsets.all(MecSpace.s12),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(MecRadius.card),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.satellite_alt_rounded, size: 15, color: c.series1),
              const SizedBox(width: MecSpace.s8),
              Text(
                'Vitals included in the alert',
                style: MecType.label.copyWith(
                  color: c.inkPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _Item(
                label: 'HEART RATE',
                value: reading?.heartRateDisplay ?? '—',
                unit: 'bpm',
                icon: Icons.favorite,
              ),
              _Item(
                label: 'BLOOD OXYGEN',
                value: reading?.spo2Display ?? '—',
                unit: '%',
                icon: Icons.water_drop,
              ),
              _Item(
                label: 'TEMPERATURE',
                value: reading?.bodyTempDisplay ?? '—',
                unit: '°C',
                icon: Icons.thermostat,
              ),
            ],
          ),
          const SizedBox(height: MecSpace.s8),
          Divider(height: 1, color: c.hairline),
          const SizedBox(height: MecSpace.s8),
          Row(
            children: [
              Icon(_gpsIcon, size: 14, color: _gpsColor),
              const SizedBox(width: MecSpace.s6),
              Expanded(
                child: Text(
                  _gpsLabel,
                  style: MecType.axisTick.copyWith(
                    color: c.inkSecondary,
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData get _gpsIcon {
    if (locating) return Icons.location_searching;
    return fix?.hasPosition ?? false
        ? Icons.location_on
        : Icons.location_disabled;
  }

  /// Green only for a live fix. A stale position is amber and no position is red,
  /// so the colour cannot say "good" about a location that is not.
  Color get _gpsColor => switch (fix?.quality) {
        FixQuality.live => MecRiskBand.low.color,
        FixQuality.lastKnown => MecRiskBand.moderate.color,
        _ => locating ? MecRiskBand.moderate.color : MecRiskBand.high.color,
      };

  String get _gpsLabel {
    if (locating) return 'GPS: acquiring fix…';
    final f = fix;
    if (f == null || !f.hasPosition) {
      return 'GPS: ${f?.problem ?? 'no fix'}';
    }
    final accuracy = f.accuracyM;
    return 'GPS: ${f.coordinatesLabel}'
        '${accuracy == null ? '' : ' (±${accuracy.round()} m)'}'
        '${f.quality == FixQuality.lastKnown ? ' · last known' : ''}';
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
  });

  final String label;
  final String value;
  final String unit;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = context.mec;

    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: c.series1),
            const SizedBox(width: MecSpace.s4),
            Text(
              label,
              style: MecType.axisTick.copyWith(
                color: c.inkMuted,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: MecSpace.s4),
        RichText(
          text: TextSpan(
            text: value,
            style: MecType.statValue.copyWith(
              color: c.inkPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
            children: [
              TextSpan(
                text: ' $unit',
                style: MecType.axisTick.copyWith(
                  color: c.inkMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
