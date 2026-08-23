/// Local acute-alert evaluation.
///
/// This mirrors `services/api/src/mecai_api/risk/engine.py::acute_flags`, and the
/// duplication is deliberate.
///
/// An SpO2 of 88% is an emergency whether or not the phone has signal. Routing that
/// judgement through the network would mean the alarm fails exactly when someone is
/// somewhere remote — which is when a rural health device matters most. So immediate
/// danger is evaluated on-device; the ten-year risk score still requires the server,
/// because that is where the Framingham model lives and a client-side port of
/// clinical coefficients would drift.
///
/// **The drift risk is handled, not ignored.** Both implementations read their
/// cut-points from generated constants (`MecAlert`, from
/// `packages/tokens/tokens.json`) and both are tested against the same contract in
/// `packages/tokens/alert-conformance.json`. If the two ever disagree,
/// `test/conformance_test.dart` fails.
library;

import '../design/tokens.dart';
import '../models/vitals.dart';

/// Evaluates [reading] against the clinical cut-points.
///
/// Absent vitals are skipped, not treated as zero — a device with no pressure
/// sensor must never produce a blood-pressure finding. [VitalsReading.ambientTempC]
/// is excluded entirely: it measures room air, and a cold room is not a clinical
/// event.
///
/// Returns flags ordered most severe first, so `.first` is the worst finding.
List<AcuteFlag> evaluateAcuteFlags(VitalsReading reading) {
  final flags = <AcuteFlag>[];

  // ── SpO2 ──
  final spo2 = reading.spo2Pct;
  if (spo2 != null) {
    if (spo2 < MecAlert.spo2Critical) {
      flags.add(AcuteFlag(
        severity: Severity.critical,
        vital: 'SpO2',
        displayValue: '${spo2.round()}%',
        threshold: 'below ${MecAlert.spo2Critical.round()}%',
        message: 'Blood oxygen is critically low.',
        recommendation:
            'Seek emergency care now. Use the SOS button if you feel unwell.',
      ));
    } else if (spo2 < MecAlert.spo2Warning) {
      flags.add(AcuteFlag(
        severity: Severity.warning,
        vital: 'SpO2',
        displayValue: '${spo2.round()}%',
        threshold: 'below ${MecAlert.spo2Warning.round()}%',
        message: 'Blood oxygen is below the normal range.',
        recommendation:
            'Rest and re-measure in 5 minutes. Contact a physician if it stays low.',
      ));
    }
  }

  // ── Blood pressure ──
  // Needs both halves: a lone systolic cannot be staged.
  final systolic = reading.systolicMmHg;
  final diastolic = reading.diastolicMmHg;
  if (systolic != null && diastolic != null) {
    final display = '${systolic.round()}/${diastolic.round()} mmHg';

    // A stage fires when EITHER half reaches its cut-point.
    bool atLeast(double sys, double dia) => systolic >= sys || diastolic >= dia;
    String label(double sys, double dia) =>
        'at or above ${sys.round()}/${dia.round()}';

    if (atLeast(MecAlert.bloodPressureCrisisSystolic,
        MecAlert.bloodPressureCrisisDiastolic)) {
      flags.add(AcuteFlag(
        severity: Severity.critical,
        vital: 'Blood pressure',
        displayValue: display,
        threshold: label(MecAlert.bloodPressureCrisisSystolic,
            MecAlert.bloodPressureCrisisDiastolic),
        message: 'Blood pressure is in the hypertensive crisis range.',
        recommendation: 'Seek emergency care now, especially with chest pain, '
            'breathlessness, or vision changes.',
      ));
    } else if (atLeast(MecAlert.bloodPressureStage2Systolic,
        MecAlert.bloodPressureStage2Diastolic)) {
      flags.add(AcuteFlag(
        severity: Severity.warning,
        vital: 'Blood pressure',
        displayValue: display,
        threshold: label(MecAlert.bloodPressureStage2Systolic,
            MecAlert.bloodPressureStage2Diastolic),
        message: 'Blood pressure is elevated (stage 2 range).',
        recommendation:
            'Re-measure after 5 minutes of rest. Consult a physician if it persists.',
      ));
    } else if (atLeast(MecAlert.bloodPressureStage1Systolic,
        MecAlert.bloodPressureStage1Diastolic)) {
      flags.add(AcuteFlag(
        severity: Severity.info,
        vital: 'Blood pressure',
        displayValue: display,
        threshold: label(MecAlert.bloodPressureStage1Systolic,
            MecAlert.bloodPressureStage1Diastolic),
        message: 'Blood pressure is slightly above target (stage 1 range).',
        recommendation: 'Keep monitoring. Reducing salt and staying active both help.',
      ));
    }
  }

  // ── Heart rate ──
  final hr = reading.heartRateBpm;
  if (hr != null) {
    if (hr >= MecAlert.heartRateHighCritical || hr <= MecAlert.heartRateLowCritical) {
      flags.add(AcuteFlag(
        severity: Severity.critical,
        vital: 'Heart rate',
        displayValue: '${hr.round()} bpm',
        threshold: 'outside ${MecAlert.heartRateLowCritical.round()}'
            '-${MecAlert.heartRateHighCritical.round()} bpm',
        message: 'Heart rate is dangerously outside the normal range.',
        recommendation:
            'Seek emergency care now, especially with dizziness or chest pain.',
      ));
    } else if (hr >= MecAlert.heartRateHighWarning ||
        hr <= MecAlert.heartRateLowWarning) {
      flags.add(AcuteFlag(
        severity: Severity.warning,
        vital: 'Heart rate',
        displayValue: '${hr.round()} bpm',
        threshold: 'outside ${MecAlert.heartRateLowWarning.round()}'
            '-${MecAlert.heartRateHighWarning.round()} bpm',
        message: 'Heart rate is outside the normal resting range.',
        recommendation:
            'Rest for 5 minutes and re-measure. Avoid caffeine before measuring.',
      ));
    }
  }

  // ── Body temperature ──
  // Only a contact sensor reaches here. ambientTempC is deliberately excluded:
  // a 24 C room would otherwise read as critical hypothermia.
  final temp = reading.temperatureC;
  if (temp != null) {
    if (temp <= MecAlert.temperatureHypothermiaCritical) {
      flags.add(AcuteFlag(
        severity: Severity.critical,
        vital: 'Temperature',
        displayValue: '${temp.toStringAsFixed(1)} C',
        threshold: 'at or below '
            '${MecAlert.temperatureHypothermiaCritical.toStringAsFixed(1)} C',
        message: 'Body temperature is critically low.',
        recommendation: 'Seek emergency care now and get warm.',
      ));
    } else if (temp >= MecAlert.temperatureFeverCritical) {
      flags.add(AcuteFlag(
        severity: Severity.critical,
        vital: 'Temperature',
        displayValue: '${temp.toStringAsFixed(1)} C',
        threshold:
            'at or above ${MecAlert.temperatureFeverCritical.toStringAsFixed(1)} C',
        message: 'High fever detected.',
        recommendation: 'Seek medical care now.',
      ));
    } else if (temp >= MecAlert.temperatureFeverWarning) {
      flags.add(AcuteFlag(
        severity: Severity.warning,
        vital: 'Temperature',
        displayValue: '${temp.toStringAsFixed(1)} C',
        threshold:
            'at or above ${MecAlert.temperatureFeverWarning.toStringAsFixed(1)} C',
        message: 'Body temperature suggests a fever.',
        recommendation: 'Rest, take fluids, and re-measure in an hour.',
      ));
    } else if (temp < MecAlert.temperatureNormalMin) {
      flags.add(AcuteFlag(
        severity: Severity.info,
        vital: 'Temperature',
        displayValue: '${temp.toStringAsFixed(1)} C',
        threshold: 'below ${MecAlert.temperatureNormalMin.toStringAsFixed(1)} C',
        message: 'Body temperature is slightly below normal.',
        recommendation: 'Skin-surface sensors read low when cold. Warm up and re-measure.',
      ));
    }
  }

  const order = <Severity, int>{
    Severity.critical: 0,
    Severity.warning: 1,
    Severity.info: 2,
  };
  flags.sort((a, b) => order[a.severity]!.compareTo(order[b.severity]!));
  return flags;
}
