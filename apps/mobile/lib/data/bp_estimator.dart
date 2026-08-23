/// Cuffless blood-pressure **estimate** from heart rate and SpO₂.
///
/// ### What this is, and what it is not
///
/// The MEC-AI watch has no cuff and no second PPG site, so it cannot measure
/// blood pressure. Pulse transit time — the one cuffless method with a defensible
/// physiological basis — needs two sensors at a known separation, and this unit
/// has one MAX30102. So there is no measurement to be had here, and this file
/// does not pretend otherwise: it produces an **estimate**, and every value it
/// emits is labelled as one all the way to the screen.
///
/// The estimate is a *deviation model*, not a prediction from nothing. It starts
/// from the resting pressure the user entered from a real cuff and moves it with
/// the two signals the watch actually has:
///
/// * **Heart rate above the user's own resting rate.** Cardiac output rises with
///   rate, and systolic pressure rises with it — roughly linearly across the
///   normal range. Diastolic moves far less, because peripheral resistance falls
///   as rate rises and partly cancels the effect. Hence the very different
///   coefficients below.
/// * **SpO₂ below normal.** Acute hypoxia drives a sympathetic response —
///   vasoconstriction and a rise in pressure. Only applied below
///   [MecAlert.spo2Warning]; above it the term is noise.
///
/// ### Why it refuses to guess
///
/// Without a cuff baseline there is no anchor, and an estimate anchored to a
/// population average would be a number about a *typical person*, presented on a
/// screen next to this person's real heart rate. [estimateBloodPressure] returns
/// [BpEstimate.unavailable] instead, naming what it needs.
///
/// ### It must never become a measurement
///
/// The result is deliberately **not** written into [VitalsReading.systolicMmHg].
/// That field means "a cuff measured this", and three things read it: the acute
/// alert engine (which would then raise hypertensive-crisis alarms from an
/// estimate), the upload payload (which would put estimates in the clinician's
/// record as measurements), and the Framingham path (which would score a
/// ten-year risk from them). An estimate driving an emergency alert is the
/// specific failure this separation exists to prevent.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;

import '../design/tokens.dart';
import '../models/vitals.dart';

/// How much to trust an estimate — driven by how far it had to extrapolate.
enum BpConfidence {
  /// Heart rate near the user's resting rate, SpO₂ normal. The estimate is close
  /// to the entered baseline and is mostly repeating it back.
  good,

  /// Extrapolated some distance from the baseline, or SpO₂ is low.
  fair,

  /// Far from resting, or the reading is motion-affected. Directional only.
  poor;

  String get label => switch (this) {
        BpConfidence.good => 'Close to your resting baseline',
        BpConfidence.fair => 'Extrapolated from your baseline',
        BpConfidence.poor => 'Rough — direction only',
      };
}

/// Where an estimated pressure sits, in three words.
///
/// Low / Medium / High rather than the AHA's five stage names. This is an
/// estimate: "Stage 1 hypertension" is a clinical diagnosis made from a measured
/// pressure, and printing it beside a figure derived from a heart rate would put
/// a diagnostic label on something that cannot support one. Three bands say the
/// same actionable thing — is this in range, drifting, or worth a cuff — without
/// claiming a stage.
///
/// Maps onto [MecRiskBand] for its colour, so the estimate reads in the same
/// vocabulary as the risk ring rather than inventing a fourth palette.
enum BpLevel {
  low(MecRiskBand.low, 'Low'),
  medium(MecRiskBand.moderate, 'Medium'),
  high(MecRiskBand.high, 'High');

  const BpLevel(this.band, this.label);

  final MecRiskBand band;
  final String label;

  Color get color => band.color;
}

/// Blood-pressure stage, by the AHA cut-points already in [MecAlert].
///
/// Reported for context only. This does **not** feed `evaluateAcuteFlags`: those
/// cut-points are for a measured pressure, and an estimate crossing 180/120 is a
/// reason to use a cuff, not a reason to raise a hypertensive-crisis alarm.
enum BpStage {
  normal,
  elevated,
  stage1,
  stage2,
  crisisRange;

  String get label => switch (this) {
        BpStage.normal => 'Normal range',
        BpStage.elevated => 'Elevated range',
        BpStage.stage1 => 'Stage 1 range',
        BpStage.stage2 => 'Stage 2 range',
        BpStage.crisisRange => 'Very high — measure with a cuff',
      };

  /// The three-band summary shown on the card. See [BpLevel].
  ///
  /// Elevated counts as medium, not low: it is the band where the advice changes
  /// from "nothing to do" to "keep an eye on it", and folding it into low would
  /// lose exactly that.
  BpLevel get level => switch (this) {
        BpStage.normal => BpLevel.low,
        BpStage.elevated => BpLevel.medium,
        BpStage.stage1 => BpLevel.medium,
        BpStage.stage2 => BpLevel.high,
        BpStage.crisisRange => BpLevel.high,
      };

  static BpStage of(double systolic, double diastolic) {
    if (systolic >= MecAlert.bloodPressureCrisisSystolic ||
        diastolic >= MecAlert.bloodPressureCrisisDiastolic) {
      return BpStage.crisisRange;
    }
    if (systolic >= MecAlert.bloodPressureStage2Systolic ||
        diastolic >= MecAlert.bloodPressureStage2Diastolic) {
      return BpStage.stage2;
    }
    if (systolic >= MecAlert.bloodPressureStage1Systolic ||
        diastolic >= MecAlert.bloodPressureStage1Diastolic) {
      return BpStage.stage1;
    }
    // Elevated is systolic-only in the AHA table: 120-129 with a normal
    // diastolic. A raised diastolic alone is already stage 1 above.
    if (systolic >= 120) return BpStage.elevated;
    return BpStage.normal;
  }
}

@immutable
class BpEstimate {
  const BpEstimate({
    required this.systolicMmHg,
    required this.diastolicMmHg,
    required this.confidence,
    required this.restingHeartRateBpm,
    required this.heartRateBpm,
    this.motionAffected = false,
  }) : problem = null;

  const BpEstimate.unavailable(this.problem)
      : systolicMmHg = null,
        diastolicMmHg = null,
        confidence = BpConfidence.poor,
        restingHeartRateBpm = null,
        heartRateBpm = null,
        motionAffected = false;

  final double? systolicMmHg;
  final double? diastolicMmHg;
  final BpConfidence confidence;

  /// The resting rate the estimate was anchored to, so the screen can show what
  /// the deviation was measured from rather than presenting a bare number.
  final double? restingHeartRateBpm;

  final double? heartRateBpm;
  final bool motionAffected;

  /// What is missing, when there is no estimate. Null when there is one.
  final String? problem;

  bool get hasEstimate => systolicMmHg != null && diastolicMmHg != null;

  BpStage? get stage =>
      hasEstimate ? BpStage.of(systolicMmHg!, diastolicMmHg!) : null;

  /// The three-band summary — Low, Medium or High. See [BpLevel].
  BpLevel? get level => stage?.level;

  /// `128/82`, or the absent marker.
  String get display => hasEstimate
      ? '${systolicMmHg!.round()}/${diastolicMmHg!.round()}'
      : VitalsReading.absent;
}

/// mmHg of systolic per bpm above the user's resting rate.
///
/// 0.35 is the low end of the reported range for the normal (non-exercise)
/// band. Understating the slope is the safer error: this estimate must not be
/// the thing that tells someone their pressure is fine, and it must not
/// manufacture an alarming number either.
const double _systolicPerBpm = 0.35;

/// Diastolic per bpm. Much flatter — peripheral resistance falls as rate rises
/// and largely offsets the increase in output.
const double _diastolicPerBpm = 0.12;

/// mmHg of systolic per % of SpO₂ below [MecAlert.spo2Warning].
const double _systolicPerSpo2Deficit = 0.8;

const double _diastolicPerSpo2Deficit = 0.4;

/// Fallback resting rate when history is too short to derive one.
const double _assumedRestingHr = 70;

/// Estimates blood pressure. Never throws; returns [BpEstimate.unavailable] with
/// a reason rather than a fabricated figure.
///
/// [history] is used only to derive the user's own resting heart rate — see
/// [restingHeartRate]. Passing an empty list is fine and falls back to
/// [_assumedRestingHr], which degrades the confidence rather than the estimate.
BpEstimate estimateBloodPressure({
  required RiskProfile profile,
  required VitalsReading? reading,
  List<VitalsReading> history = const [],
}) {
  final baseSys = profile.baselineSystolicMmHg;
  final baseDia = profile.baselineDiastolicMmHg;
  if (baseSys == null || baseDia == null) {
    return const BpEstimate.unavailable(
      'Enter a resting blood pressure from a cuff in your health profile. '
      'The estimate is a change from that reading, so it needs one to start from.',
    );
  }

  final hr = reading?.heartRateBpm;
  if (hr == null) {
    return const BpEstimate.unavailable(
      'Waiting for a heart rate. Wear the watch snugly and keep still.',
    );
  }

  final restingHr = restingHeartRate(history) ?? _assumedRestingHr;
  final deltaHr = hr - restingHr;

  final spo2 = reading?.spo2Pct;
  final spo2Deficit =
      spo2 == null ? 0.0 : (MecAlert.spo2Warning - spo2).clamp(0.0, 20.0);

  final systolic = (baseSys +
          deltaHr * _systolicPerBpm +
          spo2Deficit * _systolicPerSpo2Deficit)
      .clamp(MecPlausible.systolicMin, MecPlausible.systolicMax);

  var diastolic = (baseDia +
          deltaHr * _diastolicPerBpm +
          spo2Deficit * _diastolicPerSpo2Deficit)
      .clamp(MecPlausible.diastolicMin, MecPlausible.diastolicMax);

  // A pulse pressure under 20 mmHg is not a physiological state the clamps above
  // should be allowed to produce; it is an artefact of two independent clamps.
  if (systolic - diastolic < 20) diastolic = systolic - 20;

  return BpEstimate(
    systolicMmHg: systolic,
    diastolicMmHg: diastolic,
    confidence: _confidence(
      deltaHr: deltaHr,
      spo2Deficit: spo2Deficit,
      derivedResting: restingHeartRate(history) != null,
      motion: reading?.motionArtifact ?? false,
    ),
    restingHeartRateBpm: restingHr,
    heartRateBpm: hr,
    motionAffected: reading?.motionArtifact ?? false,
  );
}

BpConfidence _confidence({
  required double deltaHr,
  required double spo2Deficit,
  required bool derivedResting,
  required bool motion,
}) {
  // A motion-affected reading makes the heart rate itself unreliable, so the
  // whole estimate is. Reported first because no amount of proximity to the
  // baseline rescues a bad input.
  if (motion) return BpConfidence.poor;

  final drift = deltaHr.abs();
  if (drift > 40 || spo2Deficit > 5) return BpConfidence.poor;
  if (drift > 15 || spo2Deficit > 0 || !derivedResting) return BpConfidence.fair;
  return BpConfidence.good;
}

/// The user's own resting heart rate, as the 10th percentile of [history].
///
/// A percentile rather than the minimum: the minimum of a 2 Hz stream is
/// whatever the noisiest single sample was, and anchoring the whole estimate to
/// an artefact would shift every figure. Returns null below [_minSamples], where
/// a percentile means nothing.
double? restingHeartRate(List<VitalsReading> history) {
  const minSamples = 30;
  final rates = history
      .map((r) => r.heartRateBpm)
      .whereType<double>()
      .where((v) => v >= MecPlausible.heartRateMin && v <= MecPlausible.heartRateMax)
      .toList()
    ..sort();
  if (rates.length < minSamples) return null;
  return rates[(rates.length * 0.1).floor()];
}
