"""A questionnaire edit must re-score the readings already stored under it.

Regression: the roster reads each patient's *stored* per-reading assessment,
stamped at ingest. When someone completed their questionnaire after their
readings had synced, the detail panel (which scores live) showed a real band
while the roster kept saying "unknown" — the console contradicting itself on
the same patient.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from fastapi.testclient import TestClient

INCOMPLETE = {
    "age": 45, "sex": "male", "smoker": False, "diabetic": False,
}
COMPLETE = {
    "age": 58, "sex": "male", "smoker": True, "diabetic": True,
    "total_cholesterol_mgdl": 260.0, "hdl_cholesterol_mgdl": 38.0,
    "baseline_systolic_mmhg": 148.0,
}


def _reading(client_id: str, minutes_ago: int) -> dict:
    # client_id carries the server's 8-char minimum, same as real phones send.
    return {
        "client_id": f"{client_id}-00000000",
        "heart_rate_bpm": 78.0,
        "spo2_pct": 97.0,
        "ambient_temp_c": 28.4,
        "measured_at": (
            datetime.now(UTC) - timedelta(minutes=minutes_ago)
        ).isoformat(),
        "motion_artifact": False,
    }


def test_profile_edit_restamps_stored_readings(client: TestClient):
    pid = "22222222-3333-4444-5555-666666666666"

    # Enrol with an empty questionnaire and back up one reading.
    r = client.post("/v1/patients", json={
        "patient_id": pid, "display_name": "Test", "profile": INCOMPLETE,
    })
    assert r.status_code == 200

    r = client.post("/v1/readings/sync", json={
        "patient_id": pid,
        "profile": INCOMPLETE,
        "readings": [_reading("r1", 30)],
    })
    assert r.status_code == 200

    stored = client.get(f"/v1/patients/{pid}/readings?hours=24").json()[0]
    assert stored["band"] == "unknown"
    assert stored["confidence"] == "incomplete"

    # The questionnaire is completed and re-enrolled — the phone does this on
    # every profile save.
    r = client.post("/v1/patients", json={
        "patient_id": pid, "display_name": "Test", "profile": COMPLETE,
    })
    assert r.status_code == 200
    assert r.json()["latest"]["band"] != "unknown"
    assert r.json()["latest"]["confidence"] == "complete"
    assert r.json()["latest"]["value_pct"] is not None


def test_sync_carrying_updated_profile_restamps_too(client: TestClient):
    """The offline path: the batch itself announces the new inputs."""
    pid = "33333333-4444-5555-6666-777777777777"

    client.post("/v1/patients", json={
        "patient_id": pid, "display_name": "Offline", "profile": INCOMPLETE,
    })
    client.post("/v1/readings/sync", json={
        "patient_id": pid, "profile": INCOMPLETE,
        "readings": [_reading("r1", 10)],
    })

    r = client.post("/v1/readings/sync", json={
        "patient_id": pid, "profile": COMPLETE,
        # Duplicate batch — nothing new to store, but the profile change alone
        # must still restamp what is already there.
        "readings": [],
    })
    assert r.status_code == 200

    stored = client.get(f"/v1/patients/{pid}/readings?hours=24").json()[0]
    assert stored["confidence"] == "complete"


def test_non_scoring_edits_do_not_restamp(client: TestClient):
    """Renaming yourself must not rewrite clinical history."""
    pid = "44444444-5555-6666-7777-888888888888"

    client.post("/v1/patients", json={
        "patient_id": pid, "display_name": "Before",
        "profile": {**COMPLETE, "family_history_cvd": False},
    })
    client.post("/v1/readings/sync", json={
        "patient_id": pid, "profile": {**COMPLETE, "family_history_cvd": False},
        "readings": [_reading("r1", 5)],
    })
    before = client.get(f"/v1/patients/{pid}/readings?hours=24").json()[0]

    # Family history is not a Framingham input; a rename even less so.
    client.post("/v1/patients", json={
        "patient_id": pid, "display_name": "After",
        "profile": {**COMPLETE, "family_history_cvd": True},
    })

    after = client.get(f"/v1/patients/{pid}/readings?hours=24").json()[0]
    assert after["value_pct"] == before["value_pct"]
