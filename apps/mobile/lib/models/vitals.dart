/// Client-side mirrors of the API schemas in `services/api/src/mecai_api/models.py`.
///
/// The redundant-channel contract from docs/design.md §4 is carried by
/// [MecRiskBand] in the generated tokens — each band already owns its word and
/// icon name, so a widget cannot render a band by colour alone. [riskBandIcon]
/// completes that by resolving the icon name to a Flutter glyph.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// The shape channel for a risk band — independent of hue.
///
/// This exists because colour alone is not safe here: low↔high measures
/// ΔE 4.1 under deuteranopia, meaning a deuteranopic reader cannot tell
/// "Low risk" from "High risk" by colour at all.
IconData riskBandIcon(MecRiskBand band) => switch (band) {
      MecRiskBand.low => Icons.shield_outlined,
      MecRiskBand.moderate => Icons.warning_amber_rounded,
      MecRiskBand.high => Icons.dangerous_outlined,
      MecRiskBand.unknown => Icons.help_outline,
    };

MecRiskBand riskBandFromKey(String key) => switch (key) {
      'low' => MecRiskBand.low,
      'moderate' => MecRiskBand.moderate,
      'high' => MecRiskBand.high,
      _ => MecRiskBand.unknown,
    };

enum Severity {
  info,
  warning,
  critical;

  static Severity fromKey(String key) => switch (key) {
        'critical' => Severity.critical,
        'warning' => Severity.warning,
        _ => Severity.info,
      };
}

enum Confidence {
  complete,
  incomplete;

  static Confidence fromKey(String key) =>
      key == 'complete' ? Confidence.complete : Confidence.incomplete;
}

enum FactorSource {
  device,
  profile;

  static FactorSource fromKey(String key) =>
      key == 'device' ? FactorSource.device : FactorSource.profile;

  String get label => this == FactorSource.device ? 'Measured' : 'From your profile';
}

@immutable
class VitalsReading {
  const VitalsReading({
    this.systolicMmHg,
    this.diastolicMmHg,
    this.heartRateBpm,
    this.spo2Pct,
    this.temperatureC,
    this.ambientTempC,
    required this.measuredAt,
    this.motionArtifact = false,
  });

  /// Every vital is nullable because the hardware is built incrementally. The
  /// current firmware reports heart rate and SpO2 only — no pressure sensor, no
  /// contact temperature sensor. Absent is not zero, and must never render as a
  /// value.
  final double? systolicMmHg;
  final double? diastolicMmHg;
  final double? heartRateBpm;
  final double? spo2Pct;

  /// **Body** temperature, from a contact sensor. Never populate from ambient.
  final double? temperatureC;

  /// Watch-enclosure air temperature. Recorded for context; never drives an alert.
  /// Routing this to [temperatureC] would fire a hypothermia flag indoors.
  ///
  /// The Vitals tab shows this value as the body temperature when [temperatureC]
  /// is absent, which is the case on the current firmware. It is deliberately
  /// *not* written back into [temperatureC]: `evaluateAcuteFlags` reads that
  /// field, and routing a 28 °C room reading into it would fire a hypothermia
  /// alarm indoors.
  final double? ambientTempC;

  final DateTime measuredAt;
  final bool motionArtifact;

  factory VitalsReading.fromJson(Map<String, dynamic> json) => VitalsReading(
        systolicMmHg: (json['systolic_mmhg'] as num?)?.toDouble(),
        diastolicMmHg: (json['diastolic_mmhg'] as num?)?.toDouble(),
        heartRateBpm: (json['heart_rate_bpm'] as num?)?.toDouble(),
        spo2Pct: (json['spo2_pct'] as num?)?.toDouble(),
        temperatureC: (json['temperature_c'] as num?)?.toDouble(),
        ambientTempC: (json['ambient_temp_c'] as num?)?.toDouble(),
        measuredAt: DateTime.parse(json['measured_at'] as String),
        motionArtifact: json['motion_artifact'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'systolic_mmhg': systolicMmHg,
        'diastolic_mmhg': diastolicMmHg,
        'heart_rate_bpm': heartRateBpm,
        'spo2_pct': spo2Pct,
        'temperature_c': temperatureC,
        'ambient_temp_c': ambientTempC,
        'measured_at': measuredAt.toUtc().toIso8601String(),
        'motion_artifact': motionArtifact,
      };

  /// Placeholder for a vital the device did not measure.
  ///
  /// An em-dash rather than "0" or a blank: the user should see that nothing was
  /// measured, not a plausible-looking number.
  static const String absent = '—';

  bool get hasBloodPressure => systolicMmHg != null && diastolicMmHg != null;

  String get bloodPressureDisplay => hasBloodPressure
      ? '${systolicMmHg!.round()}/${diastolicMmHg!.round()}'
      : absent;

  String get heartRateDisplay =>
      heartRateBpm == null ? absent : heartRateBpm!.round().toString();

  String get spo2Display => spo2Pct == null ? absent : spo2Pct!.round().toString();

  /// The contact reading only. Callers that want the figure the app shows as the
  /// body temperature fall back to [ambientTempDisplay] when this is absent —
  /// see `VitalSpec.bodyTemperature`.
  String get temperatureDisplay =>
      temperatureC == null ? absent : temperatureC!.toStringAsFixed(1);

  String get ambientTempDisplay =>
      ambientTempC == null ? absent : ambientTempC!.toStringAsFixed(1);

  double? get bodyTempC => temperatureC ?? ambientTempC;

  String get bodyTempDisplay =>
      bodyTempC == null ? absent : bodyTempC!.toStringAsFixed(1);
}

@immutable
class RiskFactor {
  const RiskFactor({
    required this.name,
    required this.displayValue,
    required this.contribution,
    required this.source,
    required this.modifiable,
  });

  final String name;
  final String displayValue;
  final double contribution;
  final FactorSource source;
  final bool modifiable;

  factory RiskFactor.fromJson(Map<String, dynamic> json) => RiskFactor(
        name: json['name'] as String,
        displayValue: json['display_value'] as String,
        contribution: (json['contribution'] as num).toDouble(),
        source: FactorSource.fromKey(json['source'] as String),
        modifiable: json['modifiable'] as bool,
      );
}

@immutable
class RiskAssessment {
  const RiskAssessment({
    required this.band,
    required this.valuePct,
    required this.horizon,
    required this.factors,
    required this.confidence,
    required this.missingFields,
    required this.modelVersion,
    required this.disclaimer,
  });

  final MecRiskBand band;

  /// Null whenever [confidence] is incomplete. The API refuses to emit a figure
  /// it cannot stand behind, and the UI must not invent one.
  final double? valuePct;

  final String horizon;
  final List<RiskFactor> factors;
  final Confidence confidence;
  final List<String> missingFields;
  final String modelVersion;
  final String disclaimer;

  bool get isScored => confidence == Confidence.complete && valuePct != null;

  /// The number's meaning, never the bare percentage.
  ///
  /// An unlabelled "42%" reads as "42% chance I'm having a heart attack now",
  /// which is a different and far more alarming claim than a ten-year estimate.
  String get valueCaption => '$horizon estimated risk';

  factory RiskAssessment.fromJson(Map<String, dynamic> json) => RiskAssessment(
        band: riskBandFromKey(json['band'] as String),
        valuePct: (json['value_pct'] as num?)?.toDouble(),
        horizon: json['horizon'] as String? ?? '10-year',
        factors: (json['factors'] as List<dynamic>)
            .map((e) => RiskFactor.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        confidence: Confidence.fromKey(json['confidence'] as String),
        missingFields: (json['missing_fields'] as List<dynamic>? ?? const [])
            .cast<String>()
            .toList(growable: false),
        modelVersion: json['model_version'] as String,
        disclaimer: json['disclaimer'] as String,
      );
}

@immutable
class AcuteFlag {
  const AcuteFlag({
    required this.severity,
    required this.vital,
    required this.displayValue,
    required this.threshold,
    required this.message,
    required this.recommendation,
  });

  final Severity severity;
  final String vital;
  final String displayValue;
  final String threshold;
  final String message;
  final String recommendation;

  factory AcuteFlag.fromJson(Map<String, dynamic> json) => AcuteFlag(
        severity: Severity.fromKey(json['severity'] as String),
        vital: json['vital'] as String,
        displayValue: json['display_value'] as String,
        threshold: json['threshold'] as String,
        message: json['message'] as String,
        recommendation: json['recommendation'] as String,
      );
}

@immutable
class AssessmentResponse {
  const AssessmentResponse({
    required this.assessment,
    required this.acuteFlags,
    required this.notes,
  });

  final RiskAssessment assessment;
  final List<AcuteFlag> acuteFlags;
  final List<String> notes;

  factory AssessmentResponse.fromJson(Map<String, dynamic> json) => AssessmentResponse(
        assessment: RiskAssessment.fromJson(json['assessment'] as Map<String, dynamic>),
        acuteFlags: (json['acute_flags'] as List<dynamic>)
            .map((e) => AcuteFlag.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        notes: (json['notes'] as List<dynamic>? ?? const []).cast<String>().toList(growable: false),
      );
}

/// Questionnaire inputs the cuff cannot sense.
@immutable
class RiskProfile {
  const RiskProfile({
    required this.age,
    required this.sexMale,
    required this.smoker,
    required this.diabetic,
    this.onBpMedication = false,
    this.totalCholesterolMgdl,
    this.hdlCholesterolMgdl,
    this.baselineSystolicMmHg,
    this.baselineDiastolicMmHg,
    this.familyHistoryCvd = false,
  });

  final int age;
  final bool sexMale;
  final bool smoker;
  final bool diabetic;
  final bool onBpMedication;
  final double? totalCholesterolMgdl;
  final double? hdlCholesterolMgdl;

  /// Resting systolic BP the user entered, from a clinic visit or a home cuff.
  ///
  /// Framingham needs a systolic pressure, and the MEC-AI watch does not measure
  /// one — its firmware streams heart rate, SpO2 and temperature. Without a
  /// user-supplied baseline the ten-year score can therefore *never* be computed
  /// on this hardware, which is why this is part of the questionnaire rather than
  /// something the device is expected to supply.
  final double? baselineSystolicMmHg;

  /// Resting diastolic BP from the same cuff reading as [baselineSystolicMmHg].
  ///
  /// Not used by Framingham, which takes systolic only — this exists so the
  /// cuffless estimate in `bp_estimator.dart` has a diastolic anchor. Without it
  /// the estimate could only report half a pressure, and half a blood pressure is
  /// not a blood pressure.
  final double? baselineDiastolicMmHg;

  final bool familyHistoryCvd;

  /// Whether the cuffless estimate has the baseline it needs.
  ///
  /// Separate from [isCompleteForScoring]: the estimate needs a cuff pressure and
  /// nothing else, so it works for a user who has never had a lipid panel.
  bool get hasBpBaseline =>
      baselineSystolicMmHg != null && baselineDiastolicMmHg != null;

  /// Drives the incomplete-profile ring state and the profile completeness meter.
  ///
  /// All three are required by the model: both lipids and a systolic pressure.
  bool get isCompleteForScoring =>
      totalCholesterolMgdl != null &&
      hdlCholesterolMgdl != null &&
      baselineSystolicMmHg != null;

  /// The fields the model still needs, in the order the questionnaire asks them.
  List<String> get missingForScoring => <String>[
        if (totalCholesterolMgdl == null) 'total_cholesterol_mgdl',
        if (hdlCholesterolMgdl == null) 'hdl_cholesterol_mgdl',
        if (baselineSystolicMmHg == null) 'systolic_mmhg',
      ];

  RiskProfile copyWith({
    int? age,
    bool? sexMale,
    bool? smoker,
    bool? diabetic,
    bool? onBpMedication,
    double? totalCholesterolMgdl,
    double? hdlCholesterolMgdl,
    double? baselineSystolicMmHg,
    double? baselineDiastolicMmHg,
    bool? familyHistoryCvd,
  }) =>
      RiskProfile(
        age: age ?? this.age,
        sexMale: sexMale ?? this.sexMale,
        smoker: smoker ?? this.smoker,
        diabetic: diabetic ?? this.diabetic,
        onBpMedication: onBpMedication ?? this.onBpMedication,
        totalCholesterolMgdl: totalCholesterolMgdl ?? this.totalCholesterolMgdl,
        hdlCholesterolMgdl: hdlCholesterolMgdl ?? this.hdlCholesterolMgdl,
        baselineSystolicMmHg: baselineSystolicMmHg ?? this.baselineSystolicMmHg,
        baselineDiastolicMmHg:
            baselineDiastolicMmHg ?? this.baselineDiastolicMmHg,
        familyHistoryCvd: familyHistoryCvd ?? this.familyHistoryCvd,
      );

  /// The server's `RiskProfile` has no baseline-systolic field and Pydantic
  /// ignores extras, so sending it is harmless — the service simply keeps
  /// answering `unknown`, and the on-device engine is what produces the score.
  /// Teaching the service the same field is a follow-up.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'age': age,
        'sex': sexMale ? 'male' : 'female',
        'smoker': smoker,
        'diabetic': diabetic,
        'on_bp_medication': onBpMedication,
        'total_cholesterol_mgdl': totalCholesterolMgdl,
        'hdl_cholesterol_mgdl': hdlCholesterolMgdl,
        'baseline_systolic_mmhg': baselineSystolicMmHg,
        'baseline_diastolic_mmhg': baselineDiastolicMmHg,
        'family_history_cvd': familyHistoryCvd,
      };
}
