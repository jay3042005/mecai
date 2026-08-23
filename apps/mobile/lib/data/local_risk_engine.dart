/// Pure Dart implementation of the Framingham General CVD 10-Year Risk Model (2008).
///
/// Enables 100% offline-first risk scoring directly on the mobile device
/// without requiring internet connectivity or an active API server.
///
/// Reference:
/// D'Agostino RB Sr, Vasan RS, et al. "General Cardiovascular Risk Profile
/// for Use in Primary Care: The Framingham Heart Study." Circulation. 2008;117(6):743-753.
library;

import 'dart:math';

import '../design/tokens.dart';
import '../models/vitals.dart';
import 'acute_flags.dart';

const String localModelVersion = "framingham-general-cvd-2008";

class _FraminghamCoefficients {
  const _FraminghamCoefficients({
    required this.lnAge,
    required this.lnTotalChol,
    required this.lnHdl,
    required this.lnSbpUntreated,
    required this.lnSbpTreated,
    required this.smoker,
    required this.diabetic,
    required this.meanLinearPredictor,
    required this.baselineSurvival10yr,
  });

  final double lnAge;
  final double lnTotalChol;
  final double lnHdl;
  final double lnSbpUntreated;
  final double lnSbpTreated;
  final double smoker;
  final double diabetic;
  final double meanLinearPredictor;
  final double baselineSurvival10yr;
}

const _femaleCoeffs = _FraminghamCoefficients(
  lnAge: 2.32888,
  lnTotalChol: 1.20904,
  lnHdl: -0.70833,
  lnSbpUntreated: 2.76157,
  lnSbpTreated: 2.82263,
  smoker: 0.52873,
  diabetic: 0.69154,
  meanLinearPredictor: 26.1931,
  baselineSurvival10yr: 0.95012,
);

const _maleCoeffs = _FraminghamCoefficients(
  lnAge: 3.06117,
  lnTotalChol: 1.12370,
  lnHdl: -0.93263,
  lnSbpUntreated: 1.93303,
  lnSbpTreated: 1.99881,
  smoker: 0.65451,
  diabetic: 0.57367,
  meanLinearPredictor: 23.9802,
  baselineSurvival10yr: 0.88936,
);

MecRiskBand _bandFor(double riskPct) {
  if (riskPct < 10.0) return MecRiskBand.low;
  if (riskPct < 20.0) return MecRiskBand.moderate;
  return MecRiskBand.high;
}

/// Evaluates cardiovascular risk completely on-device.
AssessmentResponse evaluateRiskLocally({
  required RiskProfile profile,
  required VitalsReading reading,
}) {
  final flags = evaluateAcuteFlags(reading);
  final notes = <String>[];

  if (reading.motionArtifact) {
    notes.add("Motion was detected during sensor readout.");
  }

  // Check if we have required lipid panel and systolic BP
  final missing = <String>[];
  if (profile.totalCholesterolMgdl == null) {
    missing.add("total_cholesterol_mgdl");
  }
  if (profile.hdlCholesterolMgdl == null) {
    missing.add("hdl_cholesterol_mgdl");
  }

  // A live cuff reading wins; otherwise fall back to the baseline systolic the
  // user entered in their profile.
  //
  // This fallback is what makes scoring possible at all on current hardware. The
  // MEC-AI watch streams heart rate, SpO2 and temperature — it has no cuff — so
  // without a profile baseline `missing` always contained "systolic_mmhg" and the
  // ring was permanently stuck in its incomplete state.
  final sbp = reading.systolicMmHg ?? profile.baselineSystolicMmHg;
  final sbpFromDevice = reading.systolicMmHg != null;
  if (sbp == null) {
    missing.add("systolic_mmhg");
  }

  if (missing.isNotEmpty) {
    final factors = <RiskFactor>[];
    if (sbp != null) {
      factors.add(RiskFactor(
        name: "Systolic blood pressure",
        displayValue: "${sbp.round()} mmHg",
        contribution: 1.0,
        source: sbpFromDevice ? FactorSource.device : FactorSource.profile,
        modifiable: true,
      ));
    }

    if (missing.contains("total_cholesterol_mgdl") ||
        missing.contains("hdl_cholesterol_mgdl")) {
      notes.add(
        "A 10-year risk score requires a lipid panel. Add total and HDL cholesterol in your profile.",
      );
    }
    if (missing.contains("systolic_mmhg")) {
      notes.add(
        "The MEC-AI watch streams heart rate, SpO2 and temperature — it has no "
        "blood-pressure cuff. Add a resting systolic reading in your profile to "
        "enable the 10-year score.",
      );
    }

    return AssessmentResponse(
      assessment: RiskAssessment(
        band: MecRiskBand.unknown,
        valuePct: null,
        horizon: "10-year",
        factors: factors,
        confidence: Confidence.incomplete,
        missingFields: missing,
        modelVersion: localModelVersion,
        disclaimer: "Screening indicator, not a diagnosis. Consult a physician.",
      ),
      acuteFlags: flags,
      notes: notes,
    );
  }

  // Calculate Framingham Risk
  final sbpVal = sbp!;
  final coeffs = profile.sexMale ? _maleCoeffs : _femaleCoeffs;
  final age = profile.age.clamp(30, 74).toDouble();
  final totalChol = profile.totalCholesterolMgdl!;
  final hdlChol = profile.hdlCholesterolMgdl!;
  final sbpBeta = profile.onBpMedication
      ? coeffs.lnSbpTreated
      : coeffs.lnSbpUntreated;

  final termAge = coeffs.lnAge * log(age);
  final termTotChol = coeffs.lnTotalChol * log(totalChol);
  final termHdl = coeffs.lnHdl * log(hdlChol);
  final termSbp = sbpBeta * log(sbpVal);
  final termSmoker = coeffs.smoker * (profile.smoker ? 1.0 : 0.0);
  final termDiabetic = coeffs.diabetic * (profile.diabetic ? 1.0 : 0.0);

  final linearPredictor = termAge +
      termTotChol +
      termHdl +
      termSbp +
      termSmoker +
      termDiabetic;

  final excess = linearPredictor - coeffs.meanLinearPredictor;

  double riskFraction;
  try {
    riskFraction = 1.0 - pow(coeffs.baselineSurvival10yr, exp(excess));
  } catch (_) {
    riskFraction = 1.0;
  }

  final riskPct = (riskFraction * 100.0).clamp(0.0, 100.0);

  // Normalise factor weights
  final rawWeights = <String, double>{
    "Age": termAge.abs(),
    "Total cholesterol": termTotChol.abs(),
    "HDL cholesterol": termHdl.abs(),
    "Systolic blood pressure": termSbp.abs(),
    if (profile.smoker) "Smoking": termSmoker.abs(),
    if (profile.diabetic) "Diabetes": termDiabetic.abs(),
  };

  final totalWeight = rawWeights.values.fold(0.0, (a, b) => a + b);
  final factorList = <RiskFactor>[];

  rawWeights.forEach((name, weight) {
    String displayVal = switch (name) {
      "Age" => "${profile.age} years",
      "Total cholesterol" => "${totalChol.round()} mg/dL",
      "HDL cholesterol" => "${hdlChol.round()} mg/dL",
      "Systolic blood pressure" => "${sbpVal.round()} mmHg",
      "Smoking" => profile.smoker ? "Yes" : "No",
      "Diabetes" => profile.diabetic ? "Yes" : "No",
      _ => "",
    };

    factorList.add(RiskFactor(
      name: name,
      displayValue: displayVal,
      contribution: totalWeight > 0 ? (weight / totalWeight) : 0.0,
      source: name == "Systolic blood pressure" && sbpFromDevice
          ? FactorSource.device
          : FactorSource.profile,
      modifiable: name != "Age",
    ));
  });

  factorList.sort((a, b) => b.contribution.compareTo(a.contribution));

  return AssessmentResponse(
    assessment: RiskAssessment(
      band: _bandFor(riskPct),
      valuePct: double.parse(riskPct.toStringAsFixed(1)),
      horizon: "10-year",
      factors: factorList,
      confidence: Confidence.complete,
      missingFields: const [],
      modelVersion: localModelVersion,
      disclaimer: "Screening indicator, not a diagnosis. Consult a physician.",
    ),
    acuteFlags: flags,
    notes: notes,
  );
}
