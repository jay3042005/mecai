#!/usr/bin/env python3
"""Populate a running MEC-AI API with a demo cohort.

Drives the **real sync endpoint** over HTTP rather than writing to SQLite
directly. Seeding through the same path a phone uses means running this proves
the ingest contract works — enrolment, idempotency, per-reading scoring — instead
of quietly bypassing it and leaving the dashboard looking correct over data that
never went through the code the phone depends on.

    ./start-api.sh                       # in one terminal
    python3 scripts/seed-demo.py         # in another

Re-running is safe: reading ids are derived from the patient and timestamp, so a
second run reports duplicates rather than doubling every trend line.

Only stdlib — this must run without touching the API's virtualenv.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import urllib.error
import urllib.request
import uuid
from datetime import UTC, datetime, timedelta

DEFAULT_BASE_URL = "http://127.0.0.1:8000"

#: Stable namespace so re-running produces the same reading ids and the sync is
#: idempotent. A fresh uuid4 per run would duplicate the whole history each time.
_NAMESPACE = uuid.UUID("6ba7b812-9dad-11d1-80b4-00c04fd430c8")


class Patient:
    """A demo enrolment plus the shape of its vitals over time."""

    def __init__(
        self,
        *,
        slug: str,
        name: str,
        profile: dict,
        hr: float,
        spo2: float,
        note: str,
    ) -> None:
        self.slug = slug
        self.name = name
        self.profile = profile
        self.hr = hr
        self.spo2 = spo2
        self.note = note

    @property
    def patient_id(self) -> str:
        return f"demo-{self.slug}"


# Deliberately mixed completeness. A cohort where every patient scores would hide
# the states the real deployment is mostly in: the watch has no cuff, and most
# users have never had a lipid panel.
COHORT = [
    Patient(
        slug="bautista",
        name="R. Bautista",
        profile={
            "age": 42, "sex": "male", "smoker": False, "diabetic": False,
            "total_cholesterol_mgdl": 190, "hdl_cholesterol_mgdl": 55,
            "baseline_systolic_mmhg": 118,
        },
        hr=72, spo2=98,
        note="Complete profile, healthy vitals — scores in the low band.",
    ),
    Patient(
        slug="delacruz",
        name="M. Dela Cruz",
        profile={
            "age": 58, "sex": "female", "smoker": False, "diabetic": False,
            "total_cholesterol_mgdl": 232, "hdl_cholesterol_mgdl": 48,
            "baseline_systolic_mmhg": 138,
        },
        hr=78, spo2=97,
        note="Raised lipids and a prehypertensive baseline.",
    ),
    Patient(
        slug="sarmiento",
        name="A. Sarmiento",
        profile={
            "age": 64, "sex": "male", "smoker": True, "diabetic": False,
            "total_cholesterol_mgdl": 248, "hdl_cholesterol_mgdl": 39,
            "baseline_systolic_mmhg": 152,
        },
        hr=84, spo2=96,
        note="Smoker, stage-2 baseline — high band.",
    ),
    Patient(
        slug="manalo",
        name="L. Manalo",
        profile={
            "age": 67, "sex": "male", "smoker": True, "diabetic": True,
            "total_cholesterol_mgdl": 265, "hdl_cholesterol_mgdl": 34,
            "baseline_systolic_mmhg": 168,
        },
        hr=95, spo2=93,
        note="Stacked risk factors plus borderline SpO2 — fires acute warnings.",
    ),
    Patient(
        slug="ocampo",
        name="J. Ocampo",
        # No lipid panel and no baseline pressure: the default state of a real
        # user who has never had bloodwork. Must show as unscorable, not as a
        # reassuring low band built from substituted averages.
        profile={"age": 51, "sex": "female", "smoker": False, "diabetic": False},
        hr=74, spo2=98,
        note="No bloodwork, no baseline BP — unscorable, and honest about it.",
    ),
    Patient(
        slug="villanueva",
        name="T. Villanueva",
        profile={
            "age": 60, "sex": "male", "smoker": False, "diabetic": True,
            "total_cholesterol_mgdl": 210, "hdl_cholesterol_mgdl": 44,
            "baseline_systolic_mmhg": 144,
        },
        hr=96, spo2=88,
        note="Hypoxic — critical SpO2 alert alongside a scored ten-year band.",
    ),
]


def post(base_url: str, path: str, payload: dict) -> dict:
    request = urllib.request.Request(
        f"{base_url}{path}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read())


def build_readings(patient: Patient, *, hours: int, every_minutes: int) -> list[dict]:
    """Back-dated history with a circadian shape.

    Heart rate follows a daily curve rather than pure noise — a flat line with
    jitter makes the trend charts look plausible while testing nothing about how
    they render an actual pattern.

    Only the fields the current firmware reports are populated: HR, SpO2, and
    ambient air temperature. ``systolic_mmhg`` stays absent because the device has
    no cuff, and filling it here would make the dashboard look like it is
    receiving pressure data it will never see.

    Timestamps are snapped to a fixed grid of ``every_minutes`` slots measured from
    the Unix epoch, not offset from "now". Since the reading id is derived from the
    timestamp, offsetting from ``now`` would give every run a fresh set of ids and
    duplicate the entire history — the archive would grow by 144 rows each time
    someone re-seeded. On a grid, a re-run inside the same slot produces identical
    ids and reports duplicates, and a re-run an hour later appends only the slots
    that have actually elapsed.
    """
    rng = random.Random(patient.slug)
    slot = timedelta(minutes=every_minutes)
    # Most recent completed slot boundary.
    epoch_slots = int(datetime.now(UTC).timestamp() // slot.total_seconds())
    latest = datetime.fromtimestamp(epoch_slots * slot.total_seconds(), tz=UTC)
    readings: list[dict] = []

    for index in range(hours * 60 // every_minutes, 0, -1):
        at = latest - slot * (index - 1)
        phase = math.sin((at.hour - 4) / 24 * 2 * math.pi)
        drift = rng.uniform(-1, 1)

        readings.append(
            {
                # Derived from the grid slot, not random: re-running is idempotent.
                "client_id": str(
                    uuid.uuid5(_NAMESPACE, f"{patient.slug}:{at.isoformat()}")
                ),
                "heart_rate_bpm": round(patient.hr + drift * 4 + phase * 5, 1),
                "spo2_pct": round(min(100.0, patient.spo2 + drift * 0.8), 1),
                "ambient_temp_c": round(28.5 + drift * 1.2 + phase * 0.8, 2),
                "measured_at": at.isoformat(),
                "motion_artifact": rng.random() < 0.05,
            }
        )
    return readings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--hours", type=int, default=48, help="History depth.")
    parser.add_argument(
        "--every-minutes", type=int, default=30, help="Interval between readings."
    )
    parser.add_argument(
        "--sos",
        action="store_true",
        help="Also raise an unresolved SOS for the hypoxic patient.",
    )
    args = parser.parse_args()

    try:
        with urllib.request.urlopen(f"{args.base_url}/health", timeout=10) as response:
            health = json.loads(response.read())
    except urllib.error.URLError as error:
        print(f"Cannot reach the API at {args.base_url} — is it running?\n  {error}")
        print("Start it with: ./start-api.sh")
        return 1

    if not health.get("storage"):
        print("The API is up but its readings archive is not writable. Check MECAI_DATABASE_PATH.")
        return 1

    print(f"API {health['version']} · model {health['risk_model']} · {args.base_url}\n")

    total_stored = total_duplicate = 0
    for patient in COHORT:
        post(
            args.base_url,
            "/v1/patients",
            {
                "patient_id": patient.patient_id,
                "display_name": patient.name,
                "profile": patient.profile,
                "device_name": "MECAI-Watch (demo)",
                "app_version": "seed",
            },
        )

        readings = build_readings(
            patient, hours=args.hours, every_minutes=args.every_minutes
        )

        # Chunked because the sync schema caps a batch at 500 readings — the same
        # limit the phone's sync service batches against.
        stored = duplicates = 0
        for start in range(0, len(readings), 500):
            result = post(
                args.base_url,
                "/v1/readings/sync",
                {
                    "patient_id": patient.patient_id,
                    "profile": patient.profile,
                    "readings": readings[start : start + 500],
                },
            )
            stored += result["stored"]
            duplicates += result["duplicates"]

        total_stored += stored
        total_duplicate += duplicates
        latest = json.loads(
            urllib.request.urlopen(
                f"{args.base_url}/v1/patients/{patient.patient_id}/latest", timeout=10
            ).read()
        )
        band = latest["band"]
        pct = "—" if latest["value_pct"] is None else f"{latest['value_pct']}%"
        alerts = len(latest["acute_flags"])
        print(
            f"  {patient.name:<16} {stored:>4} new  {duplicates:>4} dup   "
            f"{band:<9} {pct:>6}   {alerts} alert(s)"
        )
        print(f"  {'':<16} {patient.note}")

    if args.sos:
        hypoxic = COHORT[-1]
        event = post(
            args.base_url,
            "/v1/sos",
            {
                "patient_id": hypoxic.patient_id,
                # Fixed id so repeated runs do not stack duplicate incidents.
                "client_id": f"demo-sos-{hypoxic.slug}",
                "triggered_at": datetime.now(UTC).isoformat(),
                "source": "app",
                # Tacurong City, Sultan Kudarat.
                "latitude": 6.6925,
                "longitude": 124.6774,
                "accuracy_m": 14.0,
                "heart_rate_bpm": hypoxic.hr,
                "spo2_pct": hypoxic.spo2,
                "note": "Demo SOS — seeded, not a real emergency.",
            },
        )
        print(f"\n  SOS #{event['id']} raised for {event['display_name']} (unresolved)")

    stats = json.loads(urllib.request.urlopen(f"{args.base_url}/v1/stats", timeout=10).read())
    print(
        f"\n{total_stored} readings stored, {total_duplicate} already present.\n"
        f"Archive now holds {stats['readings']} readings across {stats['patients']} patients."
    )
    print("\nOpen the dashboard: cd apps/web && pnpm dev  →  http://localhost:3000")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
