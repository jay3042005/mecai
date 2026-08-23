// GENERATED FILE — DO NOT EDIT.
// Source: packages/tokens/tokens.json  (spec: docs/design.md §3)
// Regenerate: node packages/tokens/generate.mjs
//

import 'package:flutter/widgets.dart';

/// Dark-mode surfaces and ink.
abstract final class MecSurfaceDark {
  static const Color page = Color(0xFF0D0D0D);
  static const Color card = Color(0xFF1A1A19);
  static const Color elevated = Color(0xFF242422);
  static const Color inkPrimary = Color(0xFFFFFFFF);
  static const Color inkSecondary = Color(0xFFC3C2B7);
  static const Color inkMuted = Color(0xFF898781);
  static const Color gridline = Color(0xFF2C2C2A);
  static const Color baseline = Color(0xFF383835);
  static const Color hairline = Color(0x1AFFFFFF);
}

/// Light-mode surfaces and ink.
abstract final class MecSurfaceLight {
  static const Color page = Color(0xFFF9F9F7);
  static const Color card = Color(0xFFFCFCFB);
  static const Color elevated = Color(0xFFFFFFFF);
  static const Color inkPrimary = Color(0xFF0B0B0B);
  static const Color inkSecondary = Color(0xFF52514E);
  static const Color inkMuted = Color(0xFF898781);
  static const Color gridline = Color(0xFFE1E0D9);
  static const Color baseline = Color(0xFFC3C2B7);
  static const Color hairline = Color(0x1A0B0B0B);
}

/// A risk band carries FOUR redundant channels (docs/design.md §4):
/// word + icon + arc length + colour. Colour is never load-bearing alone —
/// low↔high measures ΔE 4.1 under deuteranopia (validator FAIL).
enum MecRiskBand {
  low(
    color: Color(0xFF0CA30C),
    label: "Low",
    iconName: "shield-check",
  ),
  moderate(
    color: Color(0xFFFAB219),
    label: "Moderate",
    iconName: "alert-triangle",
  ),
  high(
    color: Color(0xFFD03B3B),
    label: "High",
    iconName: "alert-octagon",
  ),
  unknown(
    color: Color(0xFF898781),
    label: "Incomplete profile",
    iconName: "help-circle",
  );

  const MecRiskBand({
    required this.color,
    required this.label,
    required this.iconName,
  });

  final Color color;
  final String label;
  final String iconName;
}

/// Acute SOS/alarm state. NOT a risk band — carried by motion + siren icon.
abstract final class MecAlarm {
  static const Color color = Color(0xFFD03B3B);
}

/// Categorical series slots. Blue = data; status colours = risk. Never mix.
abstract final class MecSeries {
  /// Systolic; all single-series vitals
  static const Color s1Dark = Color(0xFF3987E5);
  static const Color s1Light = Color(0xFF2A78D6);
  /// Diastolic
  static const Color s2Dark = Color(0xFF9EC5F4);
  static const Color s2Light = Color(0xFF104281);
}

/// Single-hue sequential ramp, light→dark. Never a rainbow.
abstract final class MecSequential {
  static const List<Color> blue = <Color>[
    Color(0xFFCDE2FB),
    Color(0xFFB7D3F6),
    Color(0xFF9EC5F4),
    Color(0xFF86B6EF),
    Color(0xFF6DA7EC),
    Color(0xFF5598E7),
    Color(0xFF3987E5),
    Color(0xFF2A78D6),
    Color(0xFF256ABF),
    Color(0xFF1C5CAB),
    Color(0xFF184F95),
    Color(0xFF104281),
    Color(0xFF0D366B),
  ];
}

/// Reference lines drawn on trend charts. Muted hairlines, never dashed,
/// never in a series colour (docs/design.md §8).
abstract final class MecChartReference {
  static const double spo2Min = 95;
  static const double tempNormalMin = 36.1;
  static const double tempNormalMax = 37.2;
  static const double bpRefSystolic = 130;
  static const double bpRefDiastolic = 80;
  static const double hrNormalMin = 60;
  static const double hrNormalMax = 100;
}

/// Clinical alert cut-points, shared byte-for-byte with the Python service.
///
/// These exist on the client because an alert must fire without a network:
/// an SpO2 of 88% is an emergency whether or not the phone has signal. The
/// ten-year risk score still requires the server (that is where the model
/// lives), but immediate danger does not.
abstract final class MecAlert {
  static const double spo2Warning = 95.0;
  static const double spo2Critical = 90.0;
  static const double heartRateNormalMin = 60.0;
  static const double heartRateNormalMax = 100.0;
  static const double heartRateLowWarning = 50.0;
  static const double heartRateLowCritical = 40.0;
  static const double heartRateHighWarning = 120.0;
  static const double heartRateHighCritical = 150.0;
  static const double temperatureNormalMin = 36.1;
  static const double temperatureNormalMax = 37.2;
  static const double temperatureFeverWarning = 37.5;
  static const double temperatureFeverCritical = 39.0;
  static const double temperatureHypothermiaCritical = 35.0;
  static const double bloodPressureStage1Systolic = 130.0;
  static const double bloodPressureStage1Diastolic = 80.0;
  static const double bloodPressureStage2Systolic = 140.0;
  static const double bloodPressureStage2Diastolic = 90.0;
  static const double bloodPressureCrisisSystolic = 180.0;
  static const double bloodPressureCrisisDiastolic = 120.0;
}

/// Physiological-plausibility bounds. A reading outside these is a sensor
/// fault, rejected rather than displayed.
abstract final class MecPlausible {
  static const double systolicMin = 50.0;
  static const double systolicMax = 300.0;
  static const double diastolicMin = 25.0;
  static const double diastolicMax = 200.0;
  static const double heartRateMin = 25.0;
  static const double heartRateMax = 250.0;
  static const double spo2Min = 50.0;
  static const double spo2Max = 100.0;
  static const double temperatureMin = 30.0;
  static const double temperatureMax = 45.0;
  static const double ambientTemperatureMin = 0.0;
  static const double ambientTemperatureMax = 60.0;
}

abstract final class MecSpace {
  static const double s2 = 2;
  static const double s4 = 4;
  static const double s6 = 6;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s48 = 48;
  static const double s64 = 64;
}

abstract final class MecRadius {
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 28;
  static const double xxl = 32;
  static const double hero = 48;
  static const double pill = 999;

  // Semantic mappings
  static const double card = 24;
  static const double control = 999;
  static const double chip = 999;
  static const double ring = 999;
}

/// Material You (MD3) easing curves.
abstract final class MecEasing {
  /// MD3 Emphasized. Default for every state, shape and position change.
  static const Curve standard = Cubic(0.2, 0.0, 0.0, 1.0);
  /// MD3 Emphasized Decelerate. Elements entering the screen.
  static const Curve decelerate = Cubic(0.05, 0.7, 0.1, 1.0);
  /// MD3 Emphasized Accelerate. Elements leaving the screen.
  static const Curve accelerate = Cubic(0.3, 0.0, 0.8, 0.15);
}

/// Motion tokens. Every ambient/looping animation MUST be gated on
/// MediaQuery.disableAnimationsOf(context) — a pulsing red alert is a
/// vestibular hazard for someone who may be having a cardiac event.
abstract final class MecMotion {
  /// Press feedback, toggles
  static const Duration instant = Duration(milliseconds: 120);
  /// Cards, sheets, tab change
  static const Duration fast = Duration(milliseconds: 220);
  /// Number roll-up, ring fill
  static const Duration value = Duration(milliseconds: 900);
  /// Heartbeat pulse, live link
  static const Duration ambient = Duration(milliseconds: 1600);
  /// Per-item delay in lists/grids
  static const Duration stagger = Duration(milliseconds: 60);
}

/// MD3 state-layer opacities.
///
/// MD3 state layers are opacity overlays over the base colour, never a different hue. Reserved status colours (risk, alarm) keep their hue and take the same overlay.
abstract final class MecState {
  static const double hover = 0.08;
  static const double focus = 0.1;
  static const double press = 0.12;
  static const double drag = 0.16;
  static const double disabled = 0.38;
}

/// Drop shadows for genuinely floating surfaces.
///
/// Elevation is a hairline ring + tonal surface step (docs/design.md §3.5). These two shadows are for genuinely floating surfaces ONLY — never on a card at rest.
abstract final class MecElevation {
  /// FAB, snackbar
  static const List<BoxShadow> raised = <BoxShadow>[
    BoxShadow(
      color: Color(0x52000000),
      blurRadius: 8.0,
      offset: Offset(0, 2.0),
    ),
  ];
  /// Bottom sheet, dialog, SOS hero
  static const List<BoxShadow> floating = <BoxShadow>[
    BoxShadow(
      color: Color(0x7A000000),
      blurRadius: 32.0,
      offset: Offset(0, 8.0),
    ),
  ];
}

/// Type scale. tabularFigures is true for axis ticks and table cells ONLY —
/// equal-width digits make a hero figure like 121 look loose.
abstract final class MecType {
  static const String family = "Inter";

  static const TextStyle heroFigure = TextStyle(
    fontFamily: family,
    fontSize: 64,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle statValue = TextStyle(
    fontFamily: family,
    fontSize: 28,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle sectionTitle = TextStyle(
    fontFamily: family,
    fontSize: 18,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle body = TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle label = TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle axisTick = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );
}

/// Chart mark specs (docs/design.md §8). Hard rule: no dual-axis charts.
abstract final class MecChart {
  static const double lineWidth = 2;
  static const double markerMinSize = 8;
  static const double surfaceRing = 2;
  static const double surfaceGap = 2;
  static const double areaFillOpacity = 0.1;
  static const double barMaxThickness = 24;
  static const double barDataEndRadius = 4;
  static const double gridlineWidth = 1;
  static const double minHitTarget = 24;
}
