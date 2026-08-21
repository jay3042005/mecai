"""Synthetic reading generator — stands in for the ESP32 cuff.

Hardware is deferred, so both clients need a data source that behaves like the
real thing: plausible values, correlated vitals, and enough variation that charts
and trend lines are not flat.

This module is dev/demo scaffolding. It is mounted only when
``settings.enable_mock_endpoints`` is true so it cannot ship enabled by accident
and be mistaken for patient data.
"""

from __future__ import annotations

import math
import random
from datetime import UTC, datetime, timedelta
from enum import StrEnum

from mecai_api.models import VitalsReading


class Scenario(StrEnum):
    """Named presets, so a demo or test can request a specific clinical picture."""

    normal = "normal"
    prehypertensive = "prehypertensive"
    hypertensive = "hypertensive"
    crisis = "crisis"
    hypoxic = "hypoxic"
    febrile = "febrile"
    tachycardic = "tachycardic"


#: Scenario centre values.
#:
#: Each baseline sits clear of its own threshold by a comfortable margin relative
#: to the generator's noise (systolic sigma is roughly 6 mmHg once the shared
#: drift term is included). A baseline only 1 sigma from its cut-point produces
#: readings that contradict the scenario's name — a "crisis" preset showing
#: 176/119 breaks both the tests and the demo.
_BASELINES: dict[Scenario, dict[str, float]] = {
    Scenario.normal: {"sys": 114, "dia": 70, "hr": 72, "spo2": 98, "temp": 36.8},
    Scenario.prehypertensive: {"sys": 136, "dia": 85, "hr": 78, "spo2": 97, "temp": 36.9},
    Scenario.hypertensive: {"sys": 152, "dia": 96, "hr": 82, "spo2": 96, "temp": 36.9},
    Scenario.crisis: {"sys": 196, "dia": 128, "hr": 95, "spo2": 94, "temp": 37.1},
    Scenario.hypoxic: {"sys": 124, "dia": 79, "hr": 96, "spo2": 88, "temp": 37.0},
    Scenario.febrile: {"sys": 122, "dia": 78, "hr": 104, "spo2": 96, "temp": 38.6},
    Scenario.tachycardic: {"sys": 128, "dia": 82, "hr": 132, "spo2": 96, "temp": 37.0},
}


def reading(
    scenario: Scenario = Scenario.normal,
    *,
    at: datetime | None = None,
    rng: random.Random | None = None,
) -> VitalsReading:
    """Generate one plausible reading for ``scenario``."""
    r = rng or random.Random()
    b = _BASELINES[scenario]
    at = at or datetime.now(UTC)

    # Systolic and diastolic co-vary in real subjects; sharing a driver avoids
    # generating impossible pairs like 180/60.
    drift = r.gauss(0, 1)
    systolic = b["sys"] + drift * 6 + r.gauss(0, 2)
    diastolic = b["dia"] + drift * 3 + r.gauss(0, 1.5)

    # Guarantee a physiologic pulse pressure; VitalsReading rejects sys <= dia.
    if systolic - diastolic < 20:
        diastolic = systolic - 20 - abs(r.gauss(0, 2))

    return VitalsReading(
        systolic_mmhg=round(systolic, 1),
        diastolic_mmhg=round(diastolic, 1),
        heart_rate_bpm=round(b["hr"] + r.gauss(0, 4), 1),
        spo2_pct=round(min(100.0, b["spo2"] + r.gauss(0, 0.8)), 1),
        temperature_c=round(b["temp"] + r.gauss(0, 0.15), 2),
        # Typical Philippine indoor air, plus enclosure self-heating.
        ambient_temp_c=round(28.5 + r.gauss(0, 1.2), 2),
        measured_at=at,
        motion_artifact=r.random() < 0.06,
    )


def firmware_reading(
    scenario: Scenario = Scenario.normal,
    *,
    at: datetime | None = None,
    rng: random.Random | None = None,
) -> VitalsReading:
    """Only what ``MEC-AI3.ino`` actually reports today.

    Heart rate and SpO2 from the MAX30102, plus ambient air temperature from the
    SHT30x. No blood pressure (there is no pressure sensor) and no body
    temperature (the SHT30x reads enclosure air, not core).

    Use this to exercise the real integration path: the ten-year risk score
    correctly comes back ``unknown`` for want of systolic BP, while SpO2 and heart
    rate alerts still fire. ``reading()`` above simulates the *complete* device
    and will flatter the system by comparison.
    """
    full = reading(scenario, at=at, rng=rng)
    return full.model_copy(
        update={
            "systolic_mmhg": None,
            "diastolic_mmhg": None,
            "temperature_c": None,
        }
    )


def series(
    hours: int = 24,
    *,
    interval_minutes: int = 60,
    scenario: Scenario = Scenario.normal,
    seed: int | None = 42,
) -> list[VitalsReading]:
    """Generate a back-dated history for the Trends charts.

    A circadian term is layered on so the charts show real structure — blood
    pressure dipping overnight and peaking mid-morning — rather than noise around
    a flat line. Seeded by default so the demo is reproducible.
    """
    r = random.Random(seed)
    now = datetime.now(UTC)
    count = max(1, (hours * 60) // interval_minutes)
    out: list[VitalsReading] = []

    for i in range(count):
        at = now - timedelta(minutes=interval_minutes * (count - 1 - i))
        # Peak ~10:00, trough ~22:00.
        phase = math.sin((at.hour - 4) / 24 * 2 * math.pi)
        base = reading(scenario, at=at, rng=r)

        systolic = base.systolic_mmhg + phase * 5
        diastolic = base.diastolic_mmhg + phase * 3
        if systolic - diastolic < 20:
            diastolic = systolic - 20

        out.append(
            base.model_copy(
                update={
                    "systolic_mmhg": round(systolic, 1),
                    "diastolic_mmhg": round(diastolic, 1),
                    "heart_rate_bpm": round(base.heart_rate_bpm + phase * 4, 1),
                }
            )
        )

    return out
