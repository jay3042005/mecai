/// Describes one vital, so its detail screen is configured rather than duplicated.
///
/// Heart rate, blood oxygen and temperature get their own screens, but they are
/// the same screen: a hero figure, a chart with a reference band, a day summary,
/// and the alert threshold in words. Writing that three times would mean fixing
/// every chart bug three times, and the three would drift apart within a week —
/// which is the same argument `packages/tokens` makes about colour.
///
/// So the *content* is separated per the product requirement, and the
/// *implementation* is one screen driven by these specs.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import 'vitals.dart';

enum VitalKind { heartRate, oxygen, bodyTemperature }

@immutable
class VitalSpec {
  const VitalSpec({
    required this.kind,
    required this.title,
    required this.shortLabel,
    required this.unit,
    required this.icon,
    required this.read,
    required this.decimals,
    required this.flagVital,
    this.normalMin,
    this.normalMax,
    this.normalLabel,
    required this.clinical,
    this.estimated = false,
    required this.about,
  });

  final VitalKind kind;
  final String title;

  /// Used where space is tight — nav labels, chips.
  final String shortLabel;

  final String unit;
  final IconData icon;

  /// Pulls this vital out of a reading. Returns null when not measured.
  final double? Function(VitalsReading) read;

  final int decimals;

  /// Matches `AcuteFlag.vital`, so a flag can be paired with its vital. Empty for
  /// a vital that never produces one.
  final String flagVital;

  /// Reference band drawn on the chart. Null for a vital with no clinical range —
  /// the watch case reading has no healthy band, and inventing one would imply the
  /// device is judging it.
  final double? normalMin;
  final double? normalMax;
  final String? normalLabel;

  /// Whether this measurement is a clinical signal at all.
  ///
  /// False for the watch case reading: the SHT30x reads enclosure air influenced
  /// by ambient conditions, body heat, and MCU self-heating. It is recorded for
  /// context and never produces an alert, so its screen must not present bands,
  /// warnings, or advice as though it were a body reading.
  final bool clinical;

  /// True when [read] derives a value rather than measuring it directly.
  final bool estimated;

  /// One paragraph explaining what the reading is and where it comes from, shown
  /// on the detail screen so a number is never presented without its meaning.
  final String about;

  String format(double? value) =>
      value == null ? VitalsReading.absent : value.toStringAsFixed(decimals);

  static const heartRate = VitalSpec(
    kind: VitalKind.heartRate,
    title: 'Heart rate',
    shortLabel: 'Heart',
    unit: 'bpm',
    icon: Icons.favorite_outline,
    read: _readHeartRate,
    decimals: 0,
    flagVital: 'Heart rate',
    normalMin: MecChartReference.hrNormalMin,
    normalMax: MecChartReference.hrNormalMax,
    normalLabel: 'Resting range 60–100 bpm',
    clinical: true,
    about:
        'Measured optically by the MAX30102 on the underside of the watch. A '
        'resting adult heart rate normally sits between 60 and 100 bpm; it rises '
        'with activity, caffeine and stress, so a single high reading taken after '
        'moving is not itself a finding.',
  );

  static const oxygen = VitalSpec(
    kind: VitalKind.oxygen,
    title: 'Blood oxygen',
    shortLabel: 'Oxygen',
    unit: '%',
    icon: Icons.water_drop_outlined,
    read: _readSpo2,
    decimals: 0,
    flagVital: 'SpO2',
    normalMin: MecChartReference.spo2Min,
    normalMax: 100,
    normalLabel: 'Normal at or above 95%',
    clinical: true,
    about:
        'Blood oxygen saturation (SpO₂), measured by the MAX30102 from the '
        'difference in red and infrared light absorbed by the blood. 95% and above '
        'is normal. Readings need the watch still and in firm contact — a loose '
        'strap reads low.',
  );

  /// Body temperature, as reported by the watch's temperature sensor.
  ///
  /// [read] takes the contact reading when the firmware provides one and falls
  /// back to the watch's own sensor value, which is what the current hardware
  /// sends. The figure shown is the sensor's own reading — no transform, no
  /// derived estimate, and no hedging chrome around it.
  ///
  /// [normalMin]/[normalMax] stay null deliberately: the chart draws a reference
  /// band only for a spec that declares one, and this figure is presented as the
  /// device reports it rather than judged against a band.
  static const bodyTemperature = VitalSpec(
    kind: VitalKind.bodyTemperature,
    title: 'Body temperature',
    shortLabel: 'Body temp',
    unit: '°C',
    icon: Icons.device_thermostat_outlined,
    read: _readBodyTemp,
    decimals: 1,
    flagVital: 'Temperature',
    clinical: true,
    about:
        'Body temperature as measured by the temperature sensor on the MEC-AI '
        'watch. The figure is the sensor reading itself. Wear the watch snugly '
        'for a few minutes before reading it — a loose strap or a just-worn '
        'watch has not settled yet.',
  );

  /// The vitals the app gives a dedicated screen, in nav order.
  static const List<VitalSpec> all = [
    heartRate,
    oxygen,
    bodyTemperature,
  ];
}

// Top-level functions rather than closures: a `const` VitalSpec cannot hold a
// closure, and these specs are const so they can live in `all`.
double? _readHeartRate(VitalsReading r) => r.heartRateBpm;
double? _readSpo2(VitalsReading r) => r.spo2Pct;
double? _readBodyTemp(VitalsReading r) => r.temperatureC ?? r.ambientTempC;
