"""Risk scoring orchestration.

Two independent paths, deliberately not merged:

``assess``
    Ten-year *chronic* risk via the validated Framingham model. Requires
    questionnaire inputs. Answers "what is my outlook?"

``acute_flags``
    Immediate out-of-range vitals from the current reading alone. Requires no
    questionnaire. Answers "is something wrong right now?"

Conflating these is the most likely way this system misleads someone. A 4% ten-year
risk score says nothing about an SpO2 of 88% this minute, and a reassuring band must
never suppress an acute warning.
"""

from __future__ import annotations

from mecai_api.generated_thresholds import (
    BLOOD_PRESSURE_CRISIS_DIASTOLIC,
    BLOOD_PRESSURE_CRISIS_SYSTOLIC,
    BLOOD_PRESSURE_STAGE1_DIASTOLIC,
    BLOOD_PRESSURE_STAGE1_SYSTOLIC,
    BLOOD_PRESSURE_STAGE2_DIASTOLIC,
    BLOOD_PRESSURE_STAGE2_SYSTOLIC,
    HEART_RATE_HIGH_CRITICAL,
    HEART_RATE_HIGH_WARNING,
    HEART_RATE_LOW_CRITICAL,
    HEART_RATE_LOW_WARNING,
    SPO2_CRITICAL,
    SPO2_WARNING,
    TEMPERATURE_FEVER_CRITICAL,
    TEMPERATURE_FEVER_WARNING,
    TEMPERATURE_HYPOTHERMIA_CRITICAL,
    TEMPERATURE_NORMAL_MIN,
)
from mecai_api.models import (
    AcuteFlag,
    Confidence,
    FactorSource,
    RiskAssessment,
    RiskBand,
    RiskFactor,
    RiskProfile,
    Severity,
    VitalsReading,
)
from mecai_api.risk import framingham

# Threshold constants are generated from packages/tokens/tokens.json and shared
# with the Flutter client, which evaluates these same rules locally so an alert
# fires without a network. Both implementations are held to
# packages/tokens/alert-conformance.json — see tests/test_conformance.py.
#
# These pairs only shorten the comparisons below; the values are still the
# generated ones and must not be edited here.
_BP_CRISIS = (BLOOD_PRESSURE_CRISIS_SYSTOLIC, BLOOD_PRESSURE_CRISIS_DIASTOLIC)
_BP_STAGE2 = (BLOOD_PRESSURE_STAGE2_SYSTOLIC, BLOOD_PRESSURE_STAGE2_DIASTOLIC)
_BP_STAGE1 = (BLOOD_PRESSURE_STAGE1_SYSTOLIC, BLOOD_PRESSURE_STAGE1_DIASTOLIC)
_HR_CRITICAL = (HEART_RATE_LOW_CRITICAL, HEART_RATE_HIGH_CRITICAL)
_HR_WARNING = (HEART_RATE_LOW_WARNING, HEART_RATE_HIGH_WARNING)

#: Human-readable labels for Framingham's internal term names.
_FACTOR_LABELS = {
    "age": ("Age", FactorSource.profile, False),
    "total_cholesterol": ("Total cholesterol", FactorSource.profile, True),
    "hdl_cholesterol": ("HDL cholesterol", FactorSource.profile, True),
    "systolic_bp": ("Systolic blood pressure", FactorSource.device, True),
    "smoking": ("Smoking", FactorSource.profile, True),
    "diabetes": ("Diabetes", FactorSource.profile, True),
}


def _format_factor_value(
    term: str,
    profile: RiskProfile,
    reading: VitalsReading,
    systolic: float | None = None,
) -> str:
    match term:
        case "age":
            return f"{profile.age} years"
        case "total_cholesterol":
            return f"{profile.total_cholesterol_mgdl:.0f} mg/dL"
        case "hdl_cholesterol":
            return f"{profile.hdl_cholesterol_mgdl:.0f} mg/dL"
        case "systolic_bp":
            # `systolic` rather than `reading.systolic_mmhg`: the scored value may
            # have come from the profile baseline, and displaying an em-dash under
            # a factor that carries real weight in the score would be wrong.
            value = systolic if systolic is not None else reading.systolic_mmhg
            return "—" if value is None else f"{value:.0f} mmHg"
        case "smoking":
            return "Yes" if profile.smoker else "No"
        case "diabetes":
            return "Yes" if profile.diabetic else "No"
    return ""


def effective_systolic(profile: RiskProfile, reading: VitalsReading) -> tuple[float | None, bool]:
    """The systolic pressure to score with, and whether the device measured it.

    A live cuff reading always wins. Failing that, the resting systolic the user
    entered in their questionnaire is used — which is what makes scoring possible
    at all on the current hardware, since the MEC-AI watch has no pressure sensor.

    This is not a substituted population mean. It is a measurement the user
    reports from a clinic visit or a home cuff, and the returned flag is what lets
    the factor breakdown label it ``profile`` rather than ``device`` so nobody
    mistakes it for something the watch measured.

    Mirrors ``evaluateRiskLocally`` in ``apps/mobile/lib/data/local_risk_engine.dart``.
    The two must agree: a patient seeing 14.2% on the phone and ``unknown`` on the
    clinician's dashboard is the exact failure the single-source-of-truth rule
    exists to prevent.
    """
    if reading.systolic_mmhg is not None:
        return reading.systolic_mmhg, True
    return profile.baseline_systolic_mmhg, False


def assess(profile: RiskProfile, reading: VitalsReading) -> RiskAssessment:
    """Score ten-year CVD risk, or report why it cannot be scored.

    Two independent reasons scoring can be impossible, both reported the same way:

    * The questionnaire lacks a lipid panel. No substituting a population mean — a
      guessed input yields a confident-looking figure with no validity behind it,
      and the user cannot tell the difference.
    * Neither the reading nor the profile carries a systolic pressure. The current
      firmware has no pressure sensor, so a user who has never entered a resting
      systolic cannot be scored — normal today, not an edge case.
    """
    systolic, systolic_from_device = effective_systolic(profile, reading)
    missing = profile.missing_for_scoring(reading)

    if missing:
        # Report whatever is known, so the breakdown is not empty while the
        # profile is being completed.
        measured: list[RiskFactor] = []
        if systolic is not None:
            measured.append(
                RiskFactor(
                    name="Systolic blood pressure",
                    display_value=f"{systolic:.0f} mmHg",
                    contribution=1.0,
                    source=(
                        FactorSource.device if systolic_from_device else FactorSource.profile
                    ),
                    modifiable=True,
                )
            )

        return RiskAssessment(
            band=RiskBand.unknown,
            value_pct=None,
            factors=measured,
            confidence=Confidence.incomplete,
            missing_fields=missing,
            model_version=framingham.MODEL_VERSION,
        )

    # Narrowed by the guards above.
    assert profile.total_cholesterol_mgdl is not None
    assert profile.hdl_cholesterol_mgdl is not None
    assert systolic is not None

    result = framingham.score(
        age=profile.age,
        sex=profile.sex,
        systolic_mmhg=systolic,
        total_cholesterol_mgdl=profile.total_cholesterol_mgdl,
        hdl_cholesterol_mgdl=profile.hdl_cholesterol_mgdl,
        smoker=profile.smoker,
        diabetic=profile.diabetic,
        on_bp_medication=profile.on_bp_medication,
    )

    # Normalise |contribution| so factors sum to 1.0. HDL's beta is negative
    # (protective), so magnitude is what ranks the terms, not signed value.
    magnitudes = {k: abs(v) for k, v in result.terms.items()}
    total = sum(magnitudes.values()) or 1.0

    factors = [
        RiskFactor(
            name=_FACTOR_LABELS[term][0],
            display_value=_format_factor_value(term, profile, reading, systolic),
            contribution=magnitude / total,
            # Blood pressure is the one factor whose source varies per reading:
            # measured when a cuff supplied it, self-reported otherwise. The rest
            # are fixed by which side of the boundary they come from.
            source=(
                (FactorSource.device if systolic_from_device else FactorSource.profile)
                if term == "systolic_bp"
                else _FACTOR_LABELS[term][1]
            ),
            modifiable=_FACTOR_LABELS[term][2],
        )
        for term, magnitude in sorted(magnitudes.items(), key=lambda kv: -kv[1])
    ]

    return RiskAssessment(
        band=RiskBand(framingham.band_for(result.risk_pct)),
        value_pct=round(result.risk_pct, 1),
        factors=factors,
        confidence=Confidence.complete,
        missing_fields=[],
        model_version=framingham.MODEL_VERSION,
    )


def acute_flags(reading: VitalsReading) -> list[AcuteFlag]:
    """Detect immediately actionable out-of-range vitals.

    Absent vitals are skipped, not treated as zero — a device without a pressure
    sensor must not produce a blood-pressure finding. ``ambient_temp_c`` never
    produces a flag at all: it measures room air, and a cold room is not a
    clinical event.

    Ordered most severe first, so a caller taking ``[0]`` gets the worst finding.
    """
    flags: list[AcuteFlag] = []

    # ── SpO2 ──
    if (spo2 := reading.spo2_pct) is not None:
        if spo2 < SPO2_CRITICAL:
            flags.append(
                AcuteFlag(
                    severity=Severity.critical,
                    vital="SpO2",
                    display_value=f"{spo2:.0f}%",
                    threshold=f"below {SPO2_CRITICAL:.0f}%",
                    message="Blood oxygen is critically low.",
                    recommendation="Seek emergency care now. Use the SOS button "
                    "if you feel unwell.",
                )
            )
        elif spo2 < SPO2_WARNING:
            flags.append(
                AcuteFlag(
                    severity=Severity.warning,
                    vital="SpO2",
                    display_value=f"{spo2:.0f}%",
                    threshold=f"below {SPO2_WARNING:.0f}%",
                    message="Blood oxygen is below the normal range.",
                    recommendation="Rest and re-measure in 5 minutes. Contact a "
                    "physician if it stays low.",
                )
            )

    # ── Blood pressure ──
    # Needs both halves: a lone systolic cannot be staged.
    if reading.systolic_mmhg is not None and reading.diastolic_mmhg is not None:
        sys_mmhg, dia_mmhg = reading.systolic_mmhg, reading.diastolic_mmhg
        display = f"{sys_mmhg:.0f}/{dia_mmhg:.0f} mmHg"

        # A stage fires when EITHER half reaches its cut-point.
        def _at_least(stage: tuple[float, float]) -> bool:
            return sys_mmhg >= stage[0] or dia_mmhg >= stage[1]

        def _label(stage: tuple[float, float]) -> str:
            return f"at or above {stage[0]:.0f}/{stage[1]:.0f}"

        if _at_least(_BP_CRISIS):
            flags.append(
                AcuteFlag(
                    severity=Severity.critical,
                    vital="Blood pressure",
                    display_value=display,
                    threshold=_label(_BP_CRISIS),
                    message="Blood pressure is in the hypertensive crisis range.",
                    recommendation="Seek emergency care now, especially with chest "
                    "pain, breathlessness, or vision changes.",
                )
            )
        elif _at_least(_BP_STAGE2):
            flags.append(
                AcuteFlag(
                    severity=Severity.warning,
                    vital="Blood pressure",
                    display_value=display,
                    threshold=_label(_BP_STAGE2),
                    message="Blood pressure is elevated (stage 2 range).",
                    recommendation="Re-measure after 5 minutes of rest. Consult a "
                    "physician if it persists.",
                )
            )
        elif _at_least(_BP_STAGE1):
            flags.append(
                AcuteFlag(
                    severity=Severity.info,
                    vital="Blood pressure",
                    display_value=display,
                    threshold=_label(_BP_STAGE1),
                    message="Blood pressure is slightly above target (stage 1 range).",
                    recommendation="Keep monitoring. Reducing salt and staying "
                    "active both help.",
                )
            )

    # ── Heart rate ──
    if (hr := reading.heart_rate_bpm) is not None:
        if hr >= _HR_CRITICAL[1] or hr <= _HR_CRITICAL[0]:
            flags.append(
                AcuteFlag(
                    severity=Severity.critical,
                    vital="Heart rate",
                    display_value=f"{hr:.0f} bpm",
                    threshold=f"outside {_HR_CRITICAL[0]:.0f}-{_HR_CRITICAL[1]:.0f} bpm",
                    message="Heart rate is dangerously outside the normal range.",
                    recommendation="Seek emergency care now, especially with "
                    "dizziness or chest pain.",
                )
            )
        elif hr >= _HR_WARNING[1] or hr <= _HR_WARNING[0]:
            flags.append(
                AcuteFlag(
                    severity=Severity.warning,
                    vital="Heart rate",
                    display_value=f"{hr:.0f} bpm",
                    threshold=f"outside {_HR_WARNING[0]:.0f}-{_HR_WARNING[1]:.0f} bpm",
                    message="Heart rate is outside the normal resting range.",
                    recommendation="Rest for 5 minutes and re-measure. Avoid "
                    "caffeine before measuring.",
                )
            )

    # ── Body temperature ──
    # Only a contact sensor reaches here. ambient_temp_c is deliberately excluded:
    # a 24 C room would otherwise read as critical hypothermia.
    if (temp := reading.temperature_c) is not None:
        if temp <= TEMPERATURE_HYPOTHERMIA_CRITICAL:
            flags.append(
                AcuteFlag(
                    severity=Severity.critical,
                    vital="Temperature",
                    display_value=f"{temp:.1f} C",
                    threshold=f"at or below {TEMPERATURE_HYPOTHERMIA_CRITICAL:.1f} C",
                    message="Body temperature is critically low.",
                    recommendation="Seek emergency care now and get warm.",
                )
            )
        elif temp >= TEMPERATURE_FEVER_CRITICAL:
            flags.append(
                AcuteFlag(
                    severity=Severity.critical,
                    vital="Temperature",
                    display_value=f"{temp:.1f} C",
                    threshold=f"at or above {TEMPERATURE_FEVER_CRITICAL:.1f} C",
                    message="High fever detected.",
                    recommendation="Seek medical care now.",
                )
            )
        elif temp >= TEMPERATURE_FEVER_WARNING:
            flags.append(
                AcuteFlag(
                    severity=Severity.warning,
                    vital="Temperature",
                    display_value=f"{temp:.1f} C",
                    threshold=f"at or above {TEMPERATURE_FEVER_WARNING:.1f} C",
                    message="Body temperature suggests a fever.",
                    recommendation="Rest, take fluids, and re-measure in an hour.",
                )
            )
        elif temp < TEMPERATURE_NORMAL_MIN:
            flags.append(
                AcuteFlag(
                    severity=Severity.info,
                    vital="Temperature",
                    display_value=f"{temp:.1f} C",
                    threshold=f"below {TEMPERATURE_NORMAL_MIN:.1f} C",
                    message="Body temperature is slightly below normal.",
                    recommendation="Skin-surface sensors read low when cold. Warm "
                    "up and re-measure.",
                )
            )

    order = {Severity.critical: 0, Severity.warning: 1, Severity.info: 2}
    flags.sort(key=lambda f: order[f.severity])
    return flags
