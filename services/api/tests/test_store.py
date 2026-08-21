"""Tests for the readings archive: sync idempotency, history, SOS, and stats.

The properties under test here are the ones a flaky rural network actually
exercises. A dropped connection mid-sync is the normal case, not an edge case, so
"retrying a batch does not duplicate rows" is a correctness requirement rather
than an optimisation.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

from fastapi.testclient import TestClient

from mecai_api import store
from mecai_api.db import Database
from mecai_api.models import (
    PatientUpsert,
    ReadingUpload,
    RiskProfile,
    SyncRequest,
)


def _upload(
    *,
    minutes_ago: float = 0,
    client_id: str | None = None,
    **vitals,
) -> ReadingUpload:
    """A firmware-shaped reading: HR, SpO2, ambient. No cuff, no contact temp."""
    base = {
        "heart_rate_bpm": 72.0,
        "spo2_pct": 98.0,
        "ambient_temp_c": 28.5,
    }
    base.update(vitals)
    return ReadingUpload(
        client_id=client_id or str(uuid.uuid4()),
        measured_at=datetime.now(UTC) - timedelta(minutes=minutes_ago),
        **base,
    )


def _sync(client: TestClient, patient_id: str, readings: list[ReadingUpload]) -> dict:
    response = client.post(
        "/v1/readings/sync",
        json=SyncRequest(patient_id=patient_id, readings=readings).model_dump(mode="json"),
    )
    assert response.status_code == 200, response.text
    return response.json()


# ─────────────────────────── enrolment ───────────────────────────


def test_upsert_patient_is_idempotent(client: TestClient, scorable_profile: RiskProfile):
    payload = PatientUpsert(
        patient_id="patient-abc12345",
        display_name="R. Bautista",
        profile=scorable_profile,
    )
    first = client.post("/v1/patients", json=payload.model_dump(mode="json")).json()
    second = client.post("/v1/patients", json=payload.model_dump(mode="json")).json()

    assert first["patient_id"] == second["patient_id"]
    assert len(client.get("/v1/patients").json()) == 1


def test_profile_edit_preserves_enrolment_date(
    database: Database, client: TestClient, scorable_profile: RiskProfile
):
    """A questionnaire correction must not read as a new enrolment."""
    payload = PatientUpsert(
        patient_id="patient-abc12345",
        display_name="R. Bautista",
        profile=scorable_profile,
    )
    client.post("/v1/patients", json=payload.model_dump(mode="json"))
    created = store.get_patient_row(database, payload.patient_id)["created_at"]

    payload.profile = scorable_profile.model_copy(update={"age": 56})
    client.post("/v1/patients", json=payload.model_dump(mode="json"))
    row = store.get_patient_row(database, payload.patient_id)

    assert row["created_at"] == created
    assert row["age"] == 56


def test_device_name_is_not_erased_by_a_profile_only_update(
    database: Database, client: TestClient, scorable_profile: RiskProfile
):
    """COALESCE on device_name: a profile save omits it and must not blank it."""
    client.post(
        "/v1/patients",
        json=PatientUpsert(
            patient_id="patient-abc12345",
            display_name="R. Bautista",
            profile=scorable_profile,
            device_name="MECAI-Watch",
        ).model_dump(mode="json"),
    )
    client.post(
        "/v1/patients",
        json=PatientUpsert(
            patient_id="patient-abc12345",
            display_name="R. Bautista",
            profile=scorable_profile,
        ).model_dump(mode="json"),
    )
    assert store.get_patient_row(database, "patient-abc12345")["device_name"] == "MECAI-Watch"


# ───────────────────────────── sync ──────────────────────────────


def test_sync_stores_readings(client: TestClient, enrolled: str):
    body = _sync(client, enrolled, [_upload(minutes_ago=10), _upload(minutes_ago=5)])
    assert body["stored"] == 2
    assert body["duplicates"] == 0
    assert body["rejected"] == []


def test_resent_batch_is_reported_as_duplicate_not_stored_twice(
    client: TestClient, enrolled: str
):
    """The property a dropped connection depends on.

    A phone that loses the link mid-sync retries the whole batch. Duplicated rows
    would be indistinguishable from genuinely rapid measurements in a trend chart.
    """
    batch = [_upload(minutes_ago=10), _upload(minutes_ago=5)]

    first = _sync(client, enrolled, batch)
    second = _sync(client, enrolled, batch)

    assert (first["stored"], first["duplicates"]) == (2, 0)
    assert (second["stored"], second["duplicates"]) == (0, 2)
    assert len(client.get(f"/v1/patients/{enrolled}/readings").json()) == 2


def test_partially_overlapping_batch_stores_only_the_new_rows(
    client: TestClient, enrolled: str
):
    shared = _upload(minutes_ago=10)
    _sync(client, enrolled, [shared])

    body = _sync(client, enrolled, [shared, _upload(minutes_ago=5)])
    assert (body["stored"], body["duplicates"]) == (1, 1)


def test_same_client_id_from_two_patients_is_not_a_collision(
    client: TestClient, enrolled: str, scorable_profile: RiskProfile
):
    """Uniqueness is per patient. Two phones can generate the same id."""
    other = "patient-other001"
    client.post(
        "/v1/patients",
        json=PatientUpsert(
            patient_id=other, display_name="M. Dela Cruz", profile=scorable_profile
        ).model_dump(mode="json"),
    )
    shared_id = "collision-000001"

    assert _sync(client, enrolled, [_upload(client_id=shared_id)])["stored"] == 1
    assert _sync(client, other, [_upload(client_id=shared_id)])["stored"] == 1


def test_sync_enrols_an_unknown_patient_that_carries_a_profile(
    client: TestClient, scorable_profile: RiskProfile
):
    """Losing a real batch to a missed registration call would be the worse failure."""
    response = client.post(
        "/v1/readings/sync",
        json=SyncRequest(
            patient_id="patient-unseen01",
            profile=scorable_profile,
            readings=[_upload()],
        ).model_dump(mode="json"),
    )
    assert response.status_code == 200, response.text
    assert response.json()["stored"] == 1
    assert client.get("/v1/patients/patient-unseen01").status_code == 200


def test_sync_rejects_an_unknown_patient_with_no_profile(client: TestClient):
    response = client.post(
        "/v1/readings/sync",
        json=SyncRequest(patient_id="patient-nobody1", readings=[_upload()]).model_dump(
            mode="json"
        ),
    )
    assert response.status_code == 404


def test_sync_with_no_readings_is_accepted(client: TestClient, enrolled: str):
    """A heartbeat sync with nothing pending must not be an error."""
    assert _sync(client, enrolled, [])["stored"] == 0


def test_implausible_reading_is_rejected_before_storage(client: TestClient, enrolled: str):
    """422 at the schema boundary — a 400 bpm heart rate is a sensor fault."""
    response = client.post(
        "/v1/readings/sync",
        json={
            "patient_id": enrolled,
            "readings": [
                {
                    "client_id": "bad-reading-01",
                    "heart_rate_bpm": 400.0,
                    "measured_at": datetime.now(UTC).isoformat(),
                }
            ],
        },
    )
    assert response.status_code == 422
    assert client.get(f"/v1/patients/{enrolled}/readings").json() == []


# ──────────────────── stored assessment snapshot ─────────────────


def test_stored_reading_carries_the_assessment_computed_at_ingest(
    client: TestClient, enrolled: str
):
    """History shows the figure the patient saw, not a re-score."""
    _sync(client, enrolled, [_upload()])
    stored = client.get(f"/v1/patients/{enrolled}/readings").json()[0]

    assert stored["confidence"] == "complete"
    assert stored["band"] in {"low", "moderate", "high"}
    assert stored["value_pct"] is not None
    assert stored["model_version"]


def test_profile_baseline_systolic_makes_a_cuffless_reading_scorable(
    client: TestClient, enrolled: str
):
    """The parity fix.

    The watch has no pressure sensor. Before the profile baseline was honoured the
    server returned ``unknown`` for every real reading while the phone's on-device
    engine produced a percentage — two different figures for one patient.
    """
    _sync(client, enrolled, [_upload()])
    stored = client.get(f"/v1/patients/{enrolled}/readings").json()[0]

    assert stored["systolic_mmhg"] is None
    assert stored["confidence"] == "complete"
    assert stored["missing_fields"] == []
    assert stored["value_pct"] > 0

    # And no blood-pressure alert was invented from the baseline: a self-reported
    # resting figure is an input to the ten-year model, not a live measurement
    # that can be staged as hypertension.
    assert all(f["vital"] != "Blood pressure" for f in stored["acute_flags"])


def test_a_profile_without_a_baseline_stays_unscorable(
    client: TestClient, scorable_profile: RiskProfile
):
    """No substituted population mean. Unknown is the honest answer."""
    no_baseline = scorable_profile.model_copy(update={"baseline_systolic_mmhg": None})
    client.post(
        "/v1/patients",
        json=PatientUpsert(
            patient_id="patient-nobp0001", display_name="J. Ocampo", profile=no_baseline
        ).model_dump(mode="json"),
    )
    _sync(client, "patient-nobp0001", [_upload()])
    stored = client.get("/v1/patients/patient-nobp0001/readings").json()[0]

    assert stored["band"] == "unknown"
    assert stored["value_pct"] is None
    assert "systolic_mmhg" in stored["missing_fields"]


def test_acute_flags_fire_even_when_the_score_is_unknown(
    client: TestClient, scorable_profile: RiskProfile
):
    """A missing sensor must never silence an alarm for a sensor that works."""
    no_baseline = scorable_profile.model_copy(update={"baseline_systolic_mmhg": None})
    client.post(
        "/v1/patients",
        json=PatientUpsert(
            patient_id="patient-nobp0001", display_name="J. Ocampo", profile=no_baseline
        ).model_dump(mode="json"),
    )
    _sync(client, "patient-nobp0001", [_upload(spo2_pct=86.0)])
    stored = client.get("/v1/patients/patient-nobp0001/readings").json()[0]

    assert stored["band"] == "unknown"
    assert [f["severity"] for f in stored["acute_flags"]] == ["critical"]
    assert stored["acute_flags"][0]["vital"] == "SpO2"


# ──────────────────────────── history ────────────────────────────


def test_history_is_oldest_first(client: TestClient, enrolled: str):
    _sync(
        client,
        enrolled,
        [_upload(minutes_ago=m, heart_rate_bpm=60.0 + m) for m in (30, 20, 10)],
    )
    rows = client.get(f"/v1/patients/{enrolled}/readings").json()
    timestamps = [r["measured_at"] for r in rows]

    assert timestamps == sorted(timestamps)
    assert [r["heart_rate_bpm"] for r in rows] == [90.0, 80.0, 70.0]


def test_history_window_excludes_older_readings(client: TestClient, enrolled: str):
    _sync(client, enrolled, [_upload(minutes_ago=60 * 40), _upload(minutes_ago=30)])

    day = client.get(f"/v1/patients/{enrolled}/readings?hours=24").json()
    week = client.get(f"/v1/patients/{enrolled}/readings?hours=168").json()

    assert len(day) == 1
    assert len(week) == 2


def test_limit_returns_the_most_recent_readings_not_the_oldest(
    client: TestClient, enrolled: str
):
    """A limit that kept the oldest rows would chart a patient's first hour forever."""
    _sync(
        client,
        enrolled,
        [_upload(minutes_ago=m, heart_rate_bpm=60.0 + m) for m in range(10, 0, -1)],
    )
    rows = client.get(f"/v1/patients/{enrolled}/readings?limit=3").json()

    assert [r["heart_rate_bpm"] for r in rows] == [63.0, 62.0, 61.0]


def test_history_for_unknown_patient_is_404(client: TestClient):
    assert client.get("/v1/patients/patient-nobody1/readings").status_code == 404


def test_latest_reflects_the_newest_measurement(client: TestClient, enrolled: str):
    _sync(
        client,
        enrolled,
        [_upload(minutes_ago=30, spo2_pct=97.0), _upload(minutes_ago=1, spo2_pct=94.0)],
    )
    assert client.get(f"/v1/patients/{enrolled}/latest").json()["spo2_pct"] == 94.0


def test_latest_is_404_before_any_reading_lands(client: TestClient, enrolled: str):
    assert client.get(f"/v1/patients/{enrolled}/latest").status_code == 404


def test_roster_shows_an_enrolled_patient_with_no_readings(
    client: TestClient, enrolled: str
):
    """Enrolled-but-never-synced is a state the dashboard must show, not hide."""
    row = client.get("/v1/patients").json()[0]
    assert row["reading_count"] == 0
    assert row["latest"] is None
    assert row["last_reading_at"] is None


def test_roster_orders_by_most_recent_activity(
    client: TestClient, enrolled: str, scorable_profile: RiskProfile
):
    quiet = "patient-quiet001"
    client.post(
        "/v1/patients",
        json=PatientUpsert(
            patient_id=quiet, display_name="Quiet", profile=scorable_profile
        ).model_dump(mode="json"),
    )
    _sync(client, quiet, [_upload(minutes_ago=600)])
    _sync(client, enrolled, [_upload(minutes_ago=1)])

    assert [r["patient_id"] for r in client.get("/v1/patients").json()] == [enrolled, quiet]


# ────────────────────────────── SOS ──────────────────────────────


def _sos(client: TestClient, patient_id: str, client_id: str = "sos-000001", **extra):
    payload = {
        "patient_id": patient_id,
        "client_id": client_id,
        "triggered_at": datetime.now(UTC).isoformat(),
        "source": "app",
        **extra,
    }
    return client.post("/v1/sos", json=payload)


def test_sos_records_location(client: TestClient, enrolled: str):
    body = _sos(
        client, enrolled, latitude=6.8894, longitude=124.6752, accuracy_m=12.0
    ).json()
    assert (body["latitude"], body["longitude"]) == (6.8894, 124.6752)
    assert body["resolved_at"] is None


def test_sos_without_a_gps_fix_is_still_recorded(client: TestClient, enrolled: str):
    """Refusing an alert for want of GPS would discard it exactly when it matters."""
    body = _sos(client, enrolled).json()
    assert body["latitude"] is None
    assert len(client.get("/v1/sos").json()) == 1


def test_repeated_sos_upload_does_not_create_a_second_incident(
    client: TestClient, enrolled: str
):
    _sos(client, enrolled)
    _sos(client, enrolled)
    assert len(client.get("/v1/sos").json()) == 1


def test_resolving_an_sos_closes_it(client: TestClient, enrolled: str):
    event_id = _sos(client, enrolled).json()["id"]

    resolved = client.post(f"/v1/sos/{event_id}/resolve").json()
    assert resolved["resolved_at"] is not None
    assert client.get("/v1/sos?unresolved_only=true").json() == []


def test_a_retried_upload_cannot_reopen_a_resolved_incident(
    client: TestClient, enrolled: str
):
    """A late retry from the phone must not undo a responder's decision."""
    event_id = _sos(client, enrolled).json()["id"]
    client.post(f"/v1/sos/{event_id}/resolve")

    assert _sos(client, enrolled).json()["resolved_at"] is not None


def test_resolving_twice_keeps_the_original_timestamp(client: TestClient, enrolled: str):
    event_id = _sos(client, enrolled).json()["id"]
    first = client.post(f"/v1/sos/{event_id}/resolve").json()["resolved_at"]
    second = client.post(f"/v1/sos/{event_id}/resolve").json()["resolved_at"]
    assert first == second


def test_sos_for_unknown_patient_is_404(client: TestClient):
    assert _sos(client, "patient-nobody1").status_code == 404


def test_open_sos_count_appears_on_the_roster(client: TestClient, enrolled: str):
    _sos(client, enrolled)
    assert client.get("/v1/patients").json()[0]["open_sos_count"] == 1


# ───────────────────────────── stats ─────────────────────────────


def test_stats_on_an_empty_archive(client: TestClient):
    body = client.get("/v1/stats").json()
    assert body["patients"] == 0
    assert body["readings"] == 0
    assert body["latest_reading_at"] is None


def test_stats_counts_bands_once_per_patient(client: TestClient, enrolled: str):
    """One patient with many readings must not dominate the cohort figure."""
    _sync(client, enrolled, [_upload(minutes_ago=m) for m in (30, 20, 10)])
    body = client.get("/v1/stats").json()

    assert body["patients"] == 1
    assert body["readings"] == 3
    assert sum(body["band_counts"].values()) == 1


def test_stats_counts_a_patient_with_alerts(client: TestClient, enrolled: str):
    _sync(client, enrolled, [_upload(spo2_pct=86.0)])
    body = client.get("/v1/stats").json()

    assert body["patients_with_alerts"] == 1
    assert body["readings_last_24h"] == 1


def test_stats_reports_open_sos(client: TestClient, enrolled: str):
    _sos(client, enrolled)
    assert client.get("/v1/stats").json()["open_sos"] == 1


def test_health_reports_storage_is_writable(client: TestClient):
    body = client.get("/health").json()
    assert body["storage"] is True


# ─────────────────────────── retention ───────────────────────────


def test_prune_removes_only_readings_past_the_window(client: TestClient, enrolled: str):
    _sync(client, enrolled, [_upload(minutes_ago=60 * 24 * 400), _upload(minutes_ago=5)])

    body = client.post("/v1/admin/prune?older_than_days=365").json()
    assert body["deleted"] == 1
    assert len(client.get(f"/v1/patients/{enrolled}/readings?hours=8760").json()) == 1


def test_prune_leaves_sos_events_alone(client: TestClient, enrolled: str):
    """An emergency is worth keeping past a vitals-history window."""
    _sos(client, enrolled)
    client.post("/v1/admin/prune?older_than_days=1")
    assert len(client.get("/v1/sos").json()) == 1


# ──────────────────────── timestamp handling ─────────────────────


def test_naive_timestamps_are_treated_as_utc(client: TestClient, enrolled: str):
    """A clock-skewed phone must not have its readings shifted by the server TZ."""
    naive = datetime.now(UTC).replace(tzinfo=None)
    response = client.post(
        "/v1/readings/sync",
        json={
            "patient_id": enrolled,
            "readings": [
                {
                    "client_id": "naive-ts-0001",
                    "heart_rate_bpm": 72.0,
                    "measured_at": naive.isoformat(),
                }
            ],
        },
    )
    assert response.status_code == 200, response.text
    stored = client.get(f"/v1/patients/{enrolled}/readings").json()[0]
    assert stored["measured_at"].startswith(naive.strftime("%Y-%m-%dT%H:%M"))


def test_stored_timestamps_sort_chronologically_as_text(database: Database):
    """Fixed-width UTC is what makes ORDER BY measured_at correct.

    Mixed offsets and varying sub-second precision do not sort chronologically as
    text, and every history query relies on that ordering.
    """
    early = datetime(2026, 8, 20, 9, 0, 0, tzinfo=UTC)
    later = datetime(2026, 8, 20, 9, 0, 1, 500000, tzinfo=UTC)
    assert store.iso(early) < store.iso(later)
    assert len({len(store.iso(t)) for t in (early, later)}) == 1
