"""Tests for the risk scoring engine and API contract.

The anchor values in ``test_known_profiles`` are regression guards, captured from
the implementation once its behaviour was checked against published Framingham
characteristics (a 55-year-old man with average lipids and SBP 125 scores ~11%;
women score materially lower on identical inputs; stacked risk factors push into
the high band). They exist to catch a coefficient typo, not to re-derive the paper.
"""

from __future__ import annotations

import random
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from mecai_api import mock
from mecai_api.models import (
    Confidence,
    FactorSource,
    RiskAssessment,
    RiskBand,
    RiskProfile,
    Severity,
    Sex,
    VitalsReading,
)
from mecai_api.risk import engine, framingham


def _reading(**overrides) -> VitalsReading:
    base = {
        "systolic_mmhg": 118.0,
        "diastolic_mmhg": 76.0,
        "heart_rate_bpm": 72.0,
        "spo2_pct": 98.0,
        "temperature_c": 36.8,
        "measured_at": datetime(2026, 8, 18, 9, 0, tzinfo=UTC),
    }
    return VitalsReading(**(base | overrides))


def _profile(**overrides) -> RiskProfile:
    base = {
        "age": 55,
        "sex": Sex.male,
        "smoker": False,
        "diabetic": False,
        "total_cholesterol_mgdl": 213.0,
        "hdl_cholesterol_mgdl": 50.0,
    }
    return RiskProfile(**(base | overrides))


# ───────────────────────── Framingham backbone ─────────────────────────


@pytest.mark.parametrize(
    ("kwargs", "expected_pct", "expected_band"),
    [
        (
            dict(age=55, sex=Sex.male, systolic_mmhg=125, total_cholesterol_mgdl=213,
                 hdl_cholesterol_mgdl=50, smoker=False, diabetic=False),
            11.0, "moderate",
        ),
        (
            dict(age=55, sex=Sex.female, systolic_mmhg=125, total_cholesterol_mgdl=213,
                 hdl_cholesterol_mgdl=50, smoker=False, diabetic=False),
            6.0, "low",
        ),
        (
            dict(age=40, sex=Sex.male, systolic_mmhg=115, total_cholesterol_mgdl=180,
                 hdl_cholesterol_mgdl=60, smoker=False, diabetic=False),
            2.6, "low",
        ),
        (
            dict(age=65, sex=Sex.male, systolic_mmhg=160, total_cholesterol_mgdl=260,
                 hdl_cholesterol_mgdl=35, smoker=True, diabetic=True),
            84.6, "high",
        ),
    ],
)
def test_known_profiles(kwargs, expected_pct, expected_band):
    result = framingham.score(**kwargs)
    assert result.risk_pct == pytest.approx(expected_pct, abs=0.15)
    assert framingham.band_for(result.risk_pct) == expected_band


def test_risk_rises_monotonically_with_systolic():
    base = dict(age=55, sex=Sex.male, total_cholesterol_mgdl=200, hdl_cholesterol_mgdl=50,
                smoker=False, diabetic=False)
    risks = [framingham.score(**base, systolic_mmhg=sbp).risk_pct
             for sbp in (110, 120, 130, 140, 150, 160)]
    assert risks == sorted(risks)
    assert risks[-1] > risks[0]


def test_men_score_higher_than_women_on_identical_inputs():
    base = dict(age=60, systolic_mmhg=135, total_cholesterol_mgdl=220,
                hdl_cholesterol_mgdl=45, smoker=False, diabetic=False)
    assert (framingham.score(**base, sex=Sex.male).risk_pct
            > framingham.score(**base, sex=Sex.female).risk_pct)


@pytest.mark.parametrize("factor", ["smoker", "diabetic"])
def test_each_risk_factor_increases_risk(factor):
    base = dict(age=55, sex=Sex.male, systolic_mmhg=130, total_cholesterol_mgdl=210,
                hdl_cholesterol_mgdl=48, smoker=False, diabetic=False)
    assert framingham.score(**(base | {factor: True})).risk_pct > framingham.score(**base).risk_pct


def test_higher_hdl_is_protective():
    base = dict(age=55, sex=Sex.male, systolic_mmhg=130, total_cholesterol_mgdl=210,
                smoker=False, diabetic=False)
    assert (framingham.score(**base, hdl_cholesterol_mgdl=70).risk_pct
            < framingham.score(**base, hdl_cholesterol_mgdl=35).risk_pct)


def test_bp_medication_uses_treated_coefficient():
    base = dict(age=58, sex=Sex.female, systolic_mmhg=145, total_cholesterol_mgdl=225,
                hdl_cholesterol_mgdl=50, smoker=False, diabetic=False)
    assert (framingham.score(**base, on_bp_medication=True).risk_pct
            != framingham.score(**base, on_bp_medication=False).risk_pct)


@pytest.mark.parametrize(
    ("pct", "band"),
    [(0.0, "low"), (9.99, "low"), (10.0, "moderate"), (19.99, "moderate"),
     (20.0, "high"), (99.0, "high")],
)
def test_band_cut_points(pct, band):
    assert framingham.band_for(pct) == band


@pytest.mark.parametrize(("age", "flagged"), [(25, True), (30, False), (74, False), (80, True)])
def test_validated_age_range_flag(age, flagged):
    result = framingham.score(
        age=age, sex=Sex.male, systolic_mmhg=125, total_cholesterol_mgdl=200,
        hdl_cholesterol_mgdl=50, smoker=False, diabetic=False,
    )
    assert result.age_out_of_validated_range is flagged


# ──────────────────────────── engine.assess ────────────────────────────


def test_complete_profile_yields_scored_band():
    a = engine.assess(_profile(), _reading())
    assert a.confidence is Confidence.complete
    assert a.band in {RiskBand.low, RiskBand.moderate, RiskBand.high}
    assert a.value_pct is not None
    assert a.horizon == "10-year"
    assert a.missing_fields == []


def test_missing_lipids_refuses_to_score():
    """The engine must not substitute a population mean for an unknown input."""
    a = engine.assess(_profile(total_cholesterol_mgdl=None, hdl_cholesterol_mgdl=None), _reading())
    assert a.confidence is Confidence.incomplete
    assert a.band is RiskBand.unknown
    assert a.value_pct is None
    assert set(a.missing_fields) == {"total_cholesterol_mgdl", "hdl_cholesterol_mgdl"}


def test_partial_lipids_still_incomplete():
    a = engine.assess(_profile(hdl_cholesterol_mgdl=None), _reading())
    assert a.confidence is Confidence.incomplete
    assert a.missing_fields == ["hdl_cholesterol_mgdl"]


def test_factor_contributions_sum_to_one():
    a = engine.assess(_profile(), _reading())
    assert sum(f.contribution for f in a.factors) == pytest.approx(1.0, abs=1e-9)


def test_factors_are_ranked_by_contribution():
    contributions = [f.contribution for f in engine.assess(_profile(), _reading()).factors]
    assert contributions == sorted(contributions, reverse=True)


def test_factor_sources_distinguish_device_from_questionnaire():
    """docs/design.md §4 — the user is entitled to see which inputs the cuff measured."""
    factors = {f.name: f for f in engine.assess(_profile(), _reading()).factors}
    assert factors["Systolic blood pressure"].source is FactorSource.device
    assert factors["Age"].source is FactorSource.profile
    assert factors["Total cholesterol"].source is FactorSource.profile
    assert factors["Age"].modifiable is False
    assert factors["Smoking"].modifiable is True


# ─────────────────── structural guards on the response ─────────────────


def test_incomplete_confidence_cannot_carry_a_percentage():
    with pytest.raises(ValidationError, match="must not carry a value_pct"):
        RiskAssessment(
            band=RiskBand.unknown, value_pct=12.0, factors=[],
            confidence=Confidence.incomplete, model_version="x",
        )


def test_incomplete_confidence_cannot_carry_a_coloured_band():
    with pytest.raises(ValidationError, match="must report band=unknown"):
        RiskAssessment(
            band=RiskBand.moderate, value_pct=None, factors=[],
            confidence=Confidence.incomplete, model_version="x",
        )


def test_complete_confidence_requires_a_percentage():
    with pytest.raises(ValidationError, match="requires a value_pct"):
        RiskAssessment(
            band=RiskBand.low, value_pct=None, factors=[],
            confidence=Confidence.complete, model_version="x",
        )


# ───────────────────────── reading validation ──────────────────────────


def test_systolic_must_exceed_diastolic():
    with pytest.raises(ValidationError, match="must exceed diastolic"):
        _reading(systolic_mmhg=80.0, diastolic_mmhg=90.0)


@pytest.mark.parametrize(
    "override",
    [{"spo2_pct": 40.0}, {"temperature_c": 50.0}, {"heart_rate_bpm": 300.0},
     {"systolic_mmhg": 400.0}],
)
def test_implausible_readings_are_rejected_as_sensor_faults(override):
    with pytest.raises(ValidationError):
        _reading(**override)


# ──────────────────────────── acute flags ──────────────────────────────


def test_normal_reading_raises_no_flags():
    assert engine.acute_flags(_reading()) == []


def test_critical_hypoxia_flagged():
    flags = engine.acute_flags(_reading(spo2_pct=86.0))
    assert flags[0].severity is Severity.critical
    assert flags[0].vital == "SpO2"
    assert "emergency" in flags[0].recommendation.lower()


def test_borderline_hypoxia_is_warning_not_critical():
    flags = engine.acute_flags(_reading(spo2_pct=93.0))
    assert [f.severity for f in flags] == [Severity.warning]


def test_hypertensive_crisis_flagged():
    flags = engine.acute_flags(_reading(systolic_mmhg=190.0, diastolic_mmhg=125.0))
    bp = next(f for f in flags if f.vital == "Blood pressure")
    assert bp.severity is Severity.critical


def test_stage_one_hypertension_is_info_only():
    flags = engine.acute_flags(_reading(systolic_mmhg=132.0, diastolic_mmhg=82.0))
    bp = next(f for f in flags if f.vital == "Blood pressure")
    assert bp.severity is Severity.info


def test_flags_are_ordered_most_severe_first():
    flags = engine.acute_flags(
        _reading(systolic_mmhg=134.0, diastolic_mmhg=84.0, spo2_pct=87.0, temperature_c=37.8)
    )
    order = {Severity.critical: 0, Severity.warning: 1, Severity.info: 2}
    assert [order[f.severity] for f in flags] == sorted(order[f.severity] for f in flags)
    assert flags[0].severity is Severity.critical


def test_acute_flags_do_not_require_a_questionnaire():
    """An incomplete profile must still produce immediate warnings."""
    incomplete = _profile(total_cholesterol_mgdl=None, hdl_cholesterol_mgdl=None)
    reading = _reading(spo2_pct=85.0)
    assert engine.assess(incomplete, reading).confidence is Confidence.incomplete
    assert engine.acute_flags(reading)[0].severity is Severity.critical


# ──────────────────────────── mock source ──────────────────────────────


@pytest.mark.parametrize("scenario", list(mock.Scenario))
def test_every_mock_scenario_produces_a_valid_reading(scenario):
    r = mock.reading(scenario)
    assert r.systolic_mmhg > r.diastolic_mmhg


def test_mock_scenarios_trigger_their_intended_flags():
    """Every seed, not a lucky one.

    A scenario baseline must sit far enough from its own cut-point that noise
    cannot contradict the name — a "crisis" preset that draws 176/119 breaks both
    this test and the demo. Sweeping 50 seeds asserts that margin rather than
    pinning one draw.
    """
    for seed in range(50):
        hypoxic = engine.acute_flags(
            mock.reading(mock.Scenario.hypoxic, rng=random.Random(seed))
        )
        assert any(f.vital == "SpO2" for f in hypoxic), f"hypoxic, seed {seed}"

        crisis = engine.acute_flags(
            mock.reading(mock.Scenario.crisis, rng=random.Random(seed))
        )
        assert any(
            f.vital == "Blood pressure" and f.severity is Severity.critical
            for f in crisis
        ), f"crisis, seed {seed}"

        hypertensive = engine.acute_flags(
            mock.reading(mock.Scenario.hypertensive, rng=random.Random(seed))
        )
        assert any(
            f.vital == "Blood pressure" for f in hypertensive
        ), f"hypertensive, seed {seed}"

        febrile = engine.acute_flags(
            mock.reading(mock.Scenario.febrile, rng=random.Random(seed))
        )
        assert any(f.vital == "Temperature" for f in febrile), f"febrile, seed {seed}"


def test_normal_mock_scenario_raises_nothing_actionable():
    """The converse: the normal preset must not manufacture actionable alerts.

    Scoped to warning/critical deliberately. An occasional ``info`` stage-1 note is
    correct behaviour, not a defect — ACC/AHA stage 1 starts at 80 diastolic, so a
    draw of 117/80 genuinely is stage 1 and the engine is right to say so. Asserting
    zero flags of any severity would be testing the noise, not the preset.
    """
    actionable = {
        seed: [f.vital for f in flags if f.severity is not Severity.info]
        for seed in range(50)
        if (
            flags := engine.acute_flags(
                mock.reading(mock.Scenario.normal, rng=random.Random(seed))
            )
        )
    }
    offenders = {s: v for s, v in actionable.items() if v}
    assert offenders == {}, f"normal scenario raised actionable flags: {offenders}"


def test_mock_series_is_ordered_and_seeded():
    a = mock.series(24, seed=7)
    assert len(a) == 24
    assert [r.measured_at for r in a] == sorted(r.measured_at for r in a)
    assert [r.systolic_mmhg for r in a] == [r.systolic_mmhg for r in mock.series(24, seed=7)]


# ─────────────── partial readings (real hardware today) ───────────────


def test_firmware_reading_carries_only_what_the_device_measures():
    r = mock.firmware_reading(mock.Scenario.normal, rng=random.Random(1))
    assert r.heart_rate_bpm is not None
    assert r.spo2_pct is not None
    assert r.ambient_temp_c is not None
    # MEC-AI3.ino has no pressure sensor and no contact temperature sensor.
    assert r.systolic_mmhg is None
    assert r.diastolic_mmhg is None
    assert r.temperature_c is None


def test_missing_systolic_blocks_scoring_but_is_reported():
    """The normal case for the current firmware, not an edge case."""
    a = engine.assess(_profile(), mock.firmware_reading(rng=random.Random(1)))
    assert a.confidence is Confidence.incomplete
    assert a.band is RiskBand.unknown
    assert a.value_pct is None
    assert "systolic_mmhg" in a.missing_fields


def test_both_causes_of_incompleteness_are_reported_together():
    a = engine.assess(
        _profile(total_cholesterol_mgdl=None, hdl_cholesterol_mgdl=None),
        mock.firmware_reading(rng=random.Random(1)),
    )
    assert set(a.missing_fields) == {
        "total_cholesterol_mgdl",
        "hdl_cholesterol_mgdl",
        "systolic_mmhg",
    }


def test_acute_flags_still_fire_on_a_partial_reading():
    """An absent pressure sensor must not silence the SpO2 alarm."""
    flags = engine.acute_flags(
        mock.firmware_reading(mock.Scenario.hypoxic, rng=random.Random(1))
    )
    assert any(f.vital == "SpO2" for f in flags)
    assert not any(f.vital == "Blood pressure" for f in flags)


def test_absent_vitals_are_never_flagged_as_zero():
    r = VitalsReading(heart_rate_bpm=72.0, measured_at=datetime(2026, 8, 18, tzinfo=UTC))
    vitals = {f.vital for f in engine.acute_flags(r)}
    assert vitals == set(), f"absent vitals produced flags: {vitals}"


def test_ambient_temperature_never_produces_a_clinical_flag():
    """A 24 C room is not hypothermia.

    This is the specific integration bug the separate field exists to prevent:
    the firmware's SHT30x reads enclosure air, and routing it to ``temperature_c``
    would fire a critical hypothermia alert indoors.
    """
    for ambient in (18.0, 24.0, 28.0, 34.0, 41.0):
        r = VitalsReading(
            heart_rate_bpm=72.0,
            spo2_pct=98.0,
            ambient_temp_c=ambient,
            measured_at=datetime(2026, 8, 18, tzinfo=UTC),
        )
        assert engine.acute_flags(r) == [], f"ambient {ambient} C produced a flag"


def test_lone_systolic_cannot_be_staged():
    """Staging needs both halves; a single number must not invent a category."""
    r = VitalsReading(
        systolic_mmhg=185.0, measured_at=datetime(2026, 8, 18, tzinfo=UTC)
    )
    assert not any(f.vital == "Blood pressure" for f in engine.acute_flags(r))


def test_a_reading_with_no_vitals_is_rejected():
    with pytest.raises(ValidationError, match="at least one vital"):
        VitalsReading(measured_at=datetime(2026, 8, 18, tzinfo=UTC))


# ───────────────────────────── API contract ────────────────────────────


def test_health(client: TestClient):
    body = client.get("/health").json()
    assert body["status"] == "ok"
    assert body["risk_model"] == framingham.MODEL_VERSION


def test_assess_returns_both_paths(client: TestClient):
    r = client.post(
        "/v1/assess",
        json={
            "profile": _profile().model_dump(mode="json"),
            "reading": _reading(spo2_pct=88.0).model_dump(mode="json"),
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["assessment"]["confidence"] == "complete"
    assert body["assessment"]["value_pct"] is not None
    assert body["acute_flags"][0]["severity"] == "critical"
    assert "not a diagnosis" in body["assessment"]["disclaimer"]


def test_assess_notes_explain_missing_lipids(client: TestClient):
    r = client.post(
        "/v1/assess",
        json={
            "profile": _profile(
                total_cholesterol_mgdl=None, hdl_cholesterol_mgdl=None
            ).model_dump(mode="json"),
            "reading": _reading().model_dump(mode="json"),
        },
    )
    body = r.json()
    assert body["assessment"]["band"] == "unknown"
    assert any("lipid panel" in n for n in body["notes"])


def test_assess_warns_when_age_outside_validated_range(client: TestClient):
    r = client.post(
        "/v1/assess",
        json={
            "profile": _profile(age=82).model_dump(mode="json"),
            "reading": _reading().model_dump(mode="json"),
        },
    )
    assert any("extrapolation" in n for n in r.json()["notes"])


def test_assess_rejects_impossible_reading(client: TestClient):
    r = client.post(
        "/v1/assess",
        json={
            "profile": _profile().model_dump(mode="json"),
            "reading": {
                "systolic_mmhg": 90, "diastolic_mmhg": 110, "heart_rate_bpm": 70,
                "spo2_pct": 98, "temperature_c": 36.8,
                "measured_at": "2026-08-18T09:00:00Z",
            },
        },
    )
    assert r.status_code == 422


def test_mock_endpoints_serve_data(client: TestClient):
    assert client.get("/v1/mock/reading?scenario=hypoxic").status_code == 200
    assert len(client.get("/v1/mock/series?hours=6").json()) == 6


def test_firmware_endpoint_reflects_real_sensor_coverage(client: TestClient):
    body = client.get("/v1/mock/firmware-reading").json()
    assert body["systolic_mmhg"] is None
    assert body["temperature_c"] is None
    assert body["heart_rate_bpm"] is not None
    assert body["ambient_temp_c"] is not None


def test_assess_explains_a_missing_pressure_sensor(client: TestClient):
    reading = client.get("/v1/mock/firmware-reading?scenario=hypoxic").json()
    r = client.post(
        "/v1/assess",
        json={"profile": _profile().model_dump(mode="json"), "reading": reading},
    )
    assert r.status_code == 200
    body = r.json()

    assert body["assessment"]["band"] == "unknown"
    # The note must name the action that unblocks scoring. "Take another reading"
    # would be advice this hardware cannot follow — there is no cuff to re-run.
    assert any("cuff" in n and "profile" in n for n in body["notes"])
    assert any("ambient" in n for n in body["notes"])
    # The point of the whole exercise: alerts survive the missing sensor.
    assert any(f["vital"] == "SpO2" for f in body["acute_flags"])


# ──────────── systolic source: device cuff vs self-reported baseline ────────────
#
# The watch has no pressure sensor, so the profile baseline is the only path to a
# score on current hardware. These pin down that it is used, that a live cuff wins
# over it, and that the breakdown says which one the number came from — a
# self-reported figure presented as "Measured" would misrepresent the device.


def _cuffless(**overrides) -> VitalsReading:
    """What MEC-AI3.ino actually reports: HR, SpO2, ambient. No cuff."""
    base = {
        "heart_rate_bpm": 72.0,
        "spo2_pct": 98.0,
        "ambient_temp_c": 28.5,
        "measured_at": datetime(2026, 8, 20, 9, 0, tzinfo=UTC),
    }
    base.update(overrides)
    return VitalsReading(**base)


def _baseline_profile(**overrides) -> RiskProfile:
    base = {
        "age": 55,
        "sex": Sex.male,
        "smoker": False,
        "diabetic": False,
        "total_cholesterol_mgdl": 213.0,
        "hdl_cholesterol_mgdl": 50.0,
        "baseline_systolic_mmhg": 125.0,
    }
    base.update(overrides)
    return RiskProfile(**base)


def test_baseline_systolic_scores_a_cuffless_reading():
    assessment = engine.assess(_baseline_profile(), _cuffless())
    assert assessment.confidence is Confidence.complete
    assert assessment.band is not RiskBand.unknown
    assert assessment.value_pct is not None


def test_baseline_systolic_matches_a_cuff_reading_of_the_same_value():
    """Same pressure, same score, whichever side supplied it."""
    from_profile = engine.assess(_baseline_profile(), _cuffless())
    from_cuff = engine.assess(
        _baseline_profile(baseline_systolic_mmhg=None),
        _cuffless(systolic_mmhg=125.0, diastolic_mmhg=80.0),
    )
    assert from_profile.value_pct == from_cuff.value_pct


def test_a_live_cuff_reading_wins_over_the_profile_baseline():
    """The device measured now beats what the user remembered from a clinic visit."""
    assessment = engine.assess(
        _baseline_profile(baseline_systolic_mmhg=120.0),
        _cuffless(systolic_mmhg=170.0, diastolic_mmhg=100.0),
    )
    systolic = next(f for f in assessment.factors if f.name == "Systolic blood pressure")
    assert systolic.display_value == "170 mmHg"
    assert systolic.source is FactorSource.device


def test_a_baseline_derived_factor_is_labelled_as_coming_from_the_profile():
    """Showing a self-reported figure as "Measured" would misrepresent the device."""
    assessment = engine.assess(_baseline_profile(), _cuffless())
    systolic = next(f for f in assessment.factors if f.name == "Systolic blood pressure")
    assert systolic.display_value == "125 mmHg"
    assert systolic.source is FactorSource.profile


def test_no_systolic_anywhere_stays_unscorable():
    """No substituted population mean — unknown is the honest answer."""
    assessment = engine.assess(_baseline_profile(baseline_systolic_mmhg=None), _cuffless())
    assert assessment.confidence is Confidence.incomplete
    assert assessment.band is RiskBand.unknown
    assert assessment.value_pct is None
    assert "systolic_mmhg" in assessment.missing_fields


def test_an_incomplete_profile_still_reports_the_baseline_it_does_have():
    """The breakdown should not be empty while a lipid panel is outstanding."""
    assessment = engine.assess(
        _baseline_profile(total_cholesterol_mgdl=None, hdl_cholesterol_mgdl=None),
        _cuffless(),
    )
    assert assessment.confidence is Confidence.incomplete
    systolic = next(f for f in assessment.factors if f.name == "Systolic blood pressure")
    assert systolic.source is FactorSource.profile


def test_baseline_systolic_never_produces_a_blood_pressure_alert():
    """A crisis-range *self-reported baseline* is a risk-model input, not a live event.

    Staging it as acute hypertension would fire an emergency alert on a number the
    user typed in from a past clinic visit, potentially every time the app opens.
    """
    flags = engine.acute_flags(_cuffless())
    assert all(f.vital != "Blood pressure" for f in flags)

    assessment = engine.assess(_baseline_profile(baseline_systolic_mmhg=190.0), _cuffless())
    assert assessment.confidence is Confidence.complete
    assert engine.acute_flags(_cuffless()) == flags


def test_profile_completeness_without_a_reading_requires_a_baseline():
    """The mobile profile screen's meter asks the profile alone, with no reading."""
    assert _baseline_profile().missing_for_scoring() == []
    assert _baseline_profile(baseline_systolic_mmhg=None).missing_for_scoring() == [
        "systolic_mmhg"
    ]


def test_api_accepts_and_uses_baseline_systolic(client: TestClient):
    body = client.post(
        "/v1/assess",
        json={
            "profile": _baseline_profile().model_dump(mode="json"),
            "reading": _cuffless().model_dump(mode="json"),
        },
    ).json()
    assert body["assessment"]["confidence"] == "complete"
    assert body["assessment"]["value_pct"] is not None
