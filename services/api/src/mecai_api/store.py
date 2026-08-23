"""Repository functions over the SQLite schema in ``db``.

Kept separate from ``main`` so the endpoints stay thin and the storage rules are
testable without an HTTP client.

### Timestamps

Every timestamp is normalised to UTC and written with a **fixed-width** format by
``iso``. This matters more than it looks: the roster and trend queries sort and
range-filter on these columns as text, and a mixture of ``+00:00``, ``Z``, and
varying sub-second precision does not sort chronologically. Normalising on the way
in means ``ORDER BY measured_at DESC`` is correct rather than approximately correct.

A naive datetime is *assumed* UTC rather than rejected. Rejecting it would fail a
sync over a clock-skewed phone, and the alternative — interpreting it as server
local time — would silently shift a rural clinic's readings by eight hours.
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta

from mecai_api.db import Database, decode_list, encode_list
from mecai_api.models import (
    AcuteFlag,
    Confidence,
    FleetStats,
    PatientSummary,
    PatientUpsert,
    ReadingUpload,
    RiskAssessment,
    RiskBand,
    RiskProfile,
    Severity,
    SosEvent,
    SosUpload,
    StoredReading,
    VitalsReading,
)
from mecai_api.risk import engine

#: Fixed-width UTC. See module docstring on why the format is pinned.
_TS_FORMAT = "%Y-%m-%dT%H:%M:%S.%f+00:00"

_SEVERITY_RANK = {Severity.critical: 0, Severity.warning: 1, Severity.info: 2}


def iso(value: datetime) -> str:
    """UTC, fixed width, lexicographically sortable."""
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(UTC).strftime(_TS_FORMAT)


def parse_ts(raw: str) -> datetime:
    return datetime.fromisoformat(raw)


def now() -> datetime:
    return datetime.now(UTC)


# ───────────────────────────── patients ─────────────────────────────


def upsert_patient(database: Database, payload: PatientUpsert) -> None:
    """Register or update a phone.

    ``created_at`` is preserved on conflict — a profile edit must not look like a
    new enrolment, or the roster's "monitoring since" date resets every time
    someone corrects their age.
    """
    stamp = iso(now())
    p = payload.profile
    with database.transaction() as conn:
        conn.execute(
            """
            INSERT INTO patients (
                id, display_name, age, sex, smoker, diabetic, on_bp_medication,
                total_cholesterol_mgdl, hdl_cholesterol_mgdl,
                baseline_systolic_mmhg, family_history_cvd,
                device_name, app_version, created_at, updated_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT (id) DO UPDATE SET
                display_name           = excluded.display_name,
                age                    = excluded.age,
                sex                    = excluded.sex,
                smoker                 = excluded.smoker,
                diabetic               = excluded.diabetic,
                on_bp_medication       = excluded.on_bp_medication,
                total_cholesterol_mgdl = excluded.total_cholesterol_mgdl,
                hdl_cholesterol_mgdl   = excluded.hdl_cholesterol_mgdl,
                baseline_systolic_mmhg = excluded.baseline_systolic_mmhg,
                family_history_cvd     = excluded.family_history_cvd,
                device_name            = COALESCE(excluded.device_name, patients.device_name),
                app_version            = COALESCE(excluded.app_version, patients.app_version),
                updated_at             = excluded.updated_at
            """,
            (
                payload.patient_id,
                payload.display_name,
                p.age,
                str(p.sex),
                int(p.smoker),
                int(p.diabetic),
                int(p.on_bp_medication),
                p.total_cholesterol_mgdl,
                p.hdl_cholesterol_mgdl,
                p.baseline_systolic_mmhg,
                int(p.family_history_cvd),
                payload.device_name,
                payload.app_version,
                stamp,
                stamp,
            ),
        )


def profile_from_row(row: sqlite3.Row) -> RiskProfile:
    return RiskProfile(
        age=row["age"],
        sex=row["sex"],
        smoker=bool(row["smoker"]),
        diabetic=bool(row["diabetic"]),
        on_bp_medication=bool(row["on_bp_medication"]),
        total_cholesterol_mgdl=row["total_cholesterol_mgdl"],
        hdl_cholesterol_mgdl=row["hdl_cholesterol_mgdl"],
        baseline_systolic_mmhg=row["baseline_systolic_mmhg"],
        family_history_cvd=bool(row["family_history_cvd"]),
    )


def scoring_inputs_changed(row: sqlite3.Row, profile: RiskProfile) -> bool:
    """Whether ``profile`` differs from the stored row in anything the model uses.

    Display-name edits and family history (not a Framingham input) do not count:
    re-scoring on those would rewrite figures that are still correct.
    """
    old = profile_from_row(row)
    return (
        old.age != profile.age
        or str(old.sex) != str(profile.sex)
        or old.smoker != profile.smoker
        or old.diabetic != profile.diabetic
        or old.on_bp_medication != profile.on_bp_medication
        or old.total_cholesterol_mgdl != profile.total_cholesterol_mgdl
        or old.hdl_cholesterol_mgdl != profile.hdl_cholesterol_mgdl
        or old.baseline_systolic_mmhg != profile.baseline_systolic_mmhg
    )


def backfill_stale_scores(database: Database) -> int:
    """Heals stamps left behind by an upgrade: readings stored under a
    questionnaire that has since changed.

    Deployments that ran pre-restamp code carry rows whose band/confidence were
    computed from whatever the profile contained at ingest — often an empty
    one, so the roster says "unknown" forever even though the current profile
    scores fine. One live assessment per patient detects that cheaply; only a
    mismatch pays for the full restamp.
    """
    healed = 0
    for summary in list_patients(database):
        row = get_patient_row(database, summary.patient_id)
        latest = latest_reading(database, summary.patient_id)
        if row is None or latest is None:
            continue
        profile = profile_from_row(row)
        current = engine.assess(profile, latest)
        if (
            current.band == latest.band
            and current.confidence == latest.confidence
            and current.value_pct == latest.value_pct
        ):
            continue
        healed += restamp_patient_scores(database, summary.patient_id, profile)
    return healed


def restamp_patient_scores(
    database: Database,
    patient_id: str,
    profile: RiskProfile,
    limit: int = 500,
) -> int:
    """Re-scores a patient's most recent readings under their *current* profile.

    Readings are stamped at ingest, which is right for model changes — an old
    stamp preserves what the model of the day said. But when the questionnaire
    changes, the stored figure answers a question built from inputs the patient
    has since corrected. Leaving it stale makes the roster, the filters and
    ``/v1/stats`` report "unknown" for a patient whose detail panel scores fine,
    because only the detail panel re-scores live.

    Acute flags are untouched: they depend on the reading alone, never on the
    profile. Returns how many rows were restamped.
    """
    rows = database.conn.execute(
        """
        SELECT client_id, systolic_mmhg, diastolic_mmhg, heart_rate_bpm,
               spo2_pct, temperature_c, ambient_temp_c, motion_artifact,
               measured_at
        FROM readings WHERE patient_id = ?
        ORDER BY measured_at DESC LIMIT ?
        """,
        (patient_id, limit),
    ).fetchall()

    restamped = 0
    with database.transaction() as conn:
        for row in rows:
            reading = VitalsReading(
                systolic_mmhg=row["systolic_mmhg"],
                diastolic_mmhg=row["diastolic_mmhg"],
                heart_rate_bpm=row["heart_rate_bpm"],
                spo2_pct=row["spo2_pct"],
                temperature_c=row["temperature_c"],
                ambient_temp_c=row["ambient_temp_c"],
                motion_artifact=bool(row["motion_artifact"]),
                measured_at=parse_ts(row["measured_at"]),
            )
            assessment = engine.assess(profile, reading)
            cursor = conn.execute(
                """
                UPDATE readings SET
                    band = ?, value_pct = ?, confidence = ?,
                    model_version = ?, missing_fields = ?
                WHERE patient_id = ? AND client_id = ?
                """,
                (
                    str(assessment.band),
                    assessment.value_pct,
                    str(assessment.confidence),
                    assessment.model_version,
                    encode_list(assessment.missing_fields),
                    patient_id,
                    row["client_id"],
                ),
            )
            restamped += cursor.rowcount
    return restamped


def get_patient_row(database: Database, patient_id: str) -> sqlite3.Row | None:
    return database.conn.execute(
        "SELECT * FROM patients WHERE id = ?", (patient_id,)
    ).fetchone()


#: Roster projection. Correlated subqueries rather than GROUP BY joins so a
#: patient with no readings still produces a row — enrolled-but-never-synced is a
#: state the dashboard must show, not one it should hide.
_SUMMARY_SELECT = """
SELECT p.*,
       (SELECT COUNT(*) FROM readings r WHERE r.patient_id = p.id)
           AS reading_count,
       (SELECT MIN(r.measured_at) FROM readings r WHERE r.patient_id = p.id)
           AS first_reading_at,
       (SELECT MAX(r.measured_at) FROM readings r WHERE r.patient_id = p.id)
           AS last_reading_at,
       (SELECT COUNT(*) FROM sos_events s
         WHERE s.patient_id = p.id AND s.resolved_at IS NULL)
           AS open_sos_count
  FROM patients p
"""


def _summary_from_row(database: Database, row: sqlite3.Row) -> PatientSummary:
    return PatientSummary(
        patient_id=row["id"],
        display_name=row["display_name"],
        profile=profile_from_row(row),
        device_name=row["device_name"],
        reading_count=row["reading_count"],
        first_reading_at=(
            parse_ts(row["first_reading_at"]) if row["first_reading_at"] else None
        ),
        last_reading_at=(
            parse_ts(row["last_reading_at"]) if row["last_reading_at"] else None
        ),
        latest=latest_reading(database, row["id"]),
        open_sos_count=row["open_sos_count"],
    )


def list_patients(database: Database) -> list[PatientSummary]:
    """The dashboard roster.

    Ordered by most recent reading first, nulls last: a clinician opening the
    console wants whoever reported most recently at the top, and a patient who
    has enrolled but never synced still needs to be visible rather than silently
    absent from the list.
    """
    rows = database.conn.execute(
        _SUMMARY_SELECT + " ORDER BY last_reading_at IS NULL, last_reading_at DESC"
    ).fetchall()
    return [_summary_from_row(database, row) for row in rows]


def patient_summary(database: Database, patient_id: str) -> PatientSummary | None:
    """One roster row. Queried directly rather than filtered out of the full list —
    this runs on every profile save, and scanning the cohort to find one patient
    would make enrolment cost grow with the size of the deployment."""
    row = database.conn.execute(
        _SUMMARY_SELECT + " WHERE p.id = ?", (patient_id,)
    ).fetchone()
    return _summary_from_row(database, row) if row else None


# ───────────────────────────── readings ─────────────────────────────


def _reading_row_to_model(row: sqlite3.Row) -> StoredReading:
    return StoredReading(
        client_id=row["client_id"],
        systolic_mmhg=row["systolic_mmhg"],
        diastolic_mmhg=row["diastolic_mmhg"],
        heart_rate_bpm=row["heart_rate_bpm"],
        spo2_pct=row["spo2_pct"],
        temperature_c=row["temperature_c"],
        ambient_temp_c=row["ambient_temp_c"],
        measured_at=parse_ts(row["measured_at"]),
        motion_artifact=bool(row["motion_artifact"]),
        received_at=parse_ts(row["received_at"]),
        band=RiskBand(row["band"]),
        value_pct=row["value_pct"],
        confidence=Confidence(row["confidence"]),
        model_version=row["model_version"],
        missing_fields=decode_list(row["missing_fields"]),
        acute_flags=[AcuteFlag.model_validate(f) for f in decode_list(row["flags_json"])],
    )


def insert_readings(
    database: Database,
    patient_id: str,
    readings: list[ReadingUpload],
    assessments: dict[str, tuple[RiskAssessment, list[AcuteFlag]]],
) -> tuple[int, int, list[str]]:
    """Store a synced batch. Returns ``(stored, duplicates, rejected_client_ids)``.

    Idempotent by ``(patient_id, client_id)``: a retried batch adds nothing and is
    reported as duplicates, which the phone treats as success. Without this a
    dropped connection mid-sync would duplicate every row that did land, and the
    duplicates would be indistinguishable from real rapid measurements in a trend
    chart.

    The whole batch is one transaction. A half-written batch would leave the phone
    unable to tell which rows to retry.
    """
    stored = 0
    duplicates = 0
    rejected: list[str] = []
    received = iso(now())

    with database.transaction() as conn:
        for reading in readings:
            entry = assessments.get(reading.client_id)
            if entry is None:
                rejected.append(reading.client_id)
                continue
            assessment, flags = entry

            severity = (
                str(min((f.severity for f in flags), key=lambda s: _SEVERITY_RANK[s]))
                if flags
                else None
            )

            cursor = conn.execute(
                """
                INSERT INTO readings (
                    patient_id, client_id,
                    systolic_mmhg, diastolic_mmhg, heart_rate_bpm, spo2_pct,
                    temperature_c, ambient_temp_c, motion_artifact,
                    measured_at, received_at,
                    band, value_pct, confidence, model_version, missing_fields,
                    flag_count, top_severity, flags_json
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT (patient_id, client_id) DO NOTHING
                """,
                (
                    patient_id,
                    reading.client_id,
                    reading.systolic_mmhg,
                    reading.diastolic_mmhg,
                    reading.heart_rate_bpm,
                    reading.spo2_pct,
                    reading.temperature_c,
                    reading.ambient_temp_c,
                    int(reading.motion_artifact),
                    iso(reading.measured_at),
                    received,
                    str(assessment.band),
                    assessment.value_pct,
                    str(assessment.confidence),
                    assessment.model_version,
                    encode_list(assessment.missing_fields),
                    len(flags),
                    severity,
                    encode_list([f.model_dump(mode="json") for f in flags]),
                ),
            )
            if cursor.rowcount:
                stored += 1
            else:
                duplicates += 1

    return stored, duplicates, rejected


def get_readings(
    database: Database,
    patient_id: str,
    *,
    hours: int | None = None,
    limit: int = 500,
) -> list[StoredReading]:
    """History for the trend charts, oldest first.

    Selected newest-first with a LIMIT so a long window returns the *most recent*
    N rather than the oldest N, then reversed for plotting. Selecting oldest-first
    with a limit would chart a patient's first hour forever while their current
    state scrolled off the end.
    """
    params: list[object] = [patient_id]
    where = "patient_id = ?"
    if hours is not None:
        where += " AND measured_at >= ?"
        params.append(iso(now() - timedelta(hours=hours)))
    params.append(limit)

    rows = database.conn.execute(
        f"SELECT * FROM readings WHERE {where} ORDER BY measured_at DESC LIMIT ?",
        params,
    ).fetchall()
    return [_reading_row_to_model(row) for row in reversed(rows)]


def latest_reading(database: Database, patient_id: str) -> StoredReading | None:
    row = database.conn.execute(
        "SELECT * FROM readings WHERE patient_id = ? ORDER BY measured_at DESC LIMIT 1",
        (patient_id,),
    ).fetchone()
    return _reading_row_to_model(row) if row else None


# ─────────────────────────────── SOS ────────────────────────────────


def insert_sos(database: Database, payload: SosUpload, display_name: str) -> SosEvent:
    """Record an SOS press, idempotently.

    Re-pressing after a failed upload must not create a second incident for one
    event, so ``client_id`` is unique per patient and a repeat returns the stored
    row unchanged — including its ``resolved_at``, so a retry cannot silently
    reopen an incident a responder already closed.
    """
    received = iso(now())
    with database.transaction() as conn:
        conn.execute(
            """
            INSERT INTO sos_events (
                patient_id, client_id, triggered_at, received_at, source,
                latitude, longitude, accuracy_m,
                heart_rate_bpm, spo2_pct, temperature_c, note
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT (patient_id, client_id) DO NOTHING
            """,
            (
                payload.patient_id,
                payload.client_id,
                iso(payload.triggered_at),
                received,
                payload.source,
                payload.latitude,
                payload.longitude,
                payload.accuracy_m,
                payload.heart_rate_bpm,
                payload.spo2_pct,
                payload.temperature_c,
                payload.note,
            ),
        )
        row = conn.execute(
            "SELECT * FROM sos_events WHERE patient_id = ? AND client_id = ?",
            (payload.patient_id, payload.client_id),
        ).fetchone()

    return _sos_row_to_model(row, display_name)


def _sos_row_to_model(row: sqlite3.Row, display_name: str) -> SosEvent:
    return SosEvent(
        id=row["id"],
        patient_id=row["patient_id"],
        client_id=row["client_id"],
        display_name=display_name,
        triggered_at=parse_ts(row["triggered_at"]),
        received_at=parse_ts(row["received_at"]),
        source=row["source"],
        latitude=row["latitude"],
        longitude=row["longitude"],
        accuracy_m=row["accuracy_m"],
        heart_rate_bpm=row["heart_rate_bpm"],
        spo2_pct=row["spo2_pct"],
        temperature_c=row["temperature_c"],
        note=row["note"],
        resolved_at=parse_ts(row["resolved_at"]) if row["resolved_at"] else None,
    )


def list_sos(
    database: Database,
    *,
    unresolved_only: bool = False,
    limit: int = 50,
) -> list[SosEvent]:
    where = "WHERE s.resolved_at IS NULL" if unresolved_only else ""
    rows = database.conn.execute(
        f"""
        SELECT s.*, p.display_name
          FROM sos_events s
          JOIN patients p ON p.id = s.patient_id
          {where}
         ORDER BY s.triggered_at DESC
         LIMIT ?
        """,
        (limit,),
    ).fetchall()
    return [_sos_row_to_model(row, row["display_name"]) for row in rows]


def resolve_sos(database: Database, event_id: int) -> SosEvent | None:
    """Close an incident. Already-resolved rows keep their original timestamp.

    The ``resolved_at IS NULL`` guard means a second responder clicking resolve
    does not overwrite when the first one actually did it.
    """
    with database.transaction() as conn:
        conn.execute(
            "UPDATE sos_events SET resolved_at = ? WHERE id = ? AND resolved_at IS NULL",
            (iso(now()), event_id),
        )
        row = conn.execute(
            """
            SELECT s.*, p.display_name
              FROM sos_events s JOIN patients p ON p.id = s.patient_id
             WHERE s.id = ?
            """,
            (event_id,),
        ).fetchone()
    return _sos_row_to_model(row, row["display_name"]) if row else None


# ────────────────────────────── stats ───────────────────────────────


def stats(database: Database) -> FleetStats:
    """Dashboard counters.

    ``band_counts`` reflects each patient's *latest* reading, not every reading
    ever stored — the header answers "how is the cohort right now", and counting
    all history would let one patient with a thousand readings dominate the
    figure.
    """
    conn = database.conn
    cutoff = iso(now() - timedelta(hours=24))

    patients = conn.execute("SELECT COUNT(*) AS n FROM patients").fetchone()["n"]
    readings = conn.execute("SELECT COUNT(*) AS n FROM readings").fetchone()["n"]
    recent = conn.execute(
        "SELECT COUNT(*) AS n FROM readings WHERE measured_at >= ?", (cutoff,)
    ).fetchone()["n"]
    open_sos = conn.execute(
        "SELECT COUNT(*) AS n FROM sos_events WHERE resolved_at IS NULL"
    ).fetchone()["n"]
    latest_at = conn.execute("SELECT MAX(measured_at) AS t FROM readings").fetchone()["t"]

    latest_per_patient = conn.execute(
        """
        SELECT r.band, r.flag_count
          FROM readings r
          JOIN (
              SELECT patient_id, MAX(measured_at) AS newest
                FROM readings GROUP BY patient_id
          ) m ON m.patient_id = r.patient_id AND m.newest = r.measured_at
        """
    ).fetchall()

    band_counts: dict[str, int] = {}
    with_alerts = 0
    for row in latest_per_patient:
        band_counts[row["band"]] = band_counts.get(row["band"], 0) + 1
        if row["flag_count"]:
            with_alerts += 1

    return FleetStats(
        patients=patients,
        readings=readings,
        readings_last_24h=recent,
        open_sos=open_sos,
        patients_with_alerts=with_alerts,
        band_counts=band_counts,
        latest_reading_at=parse_ts(latest_at) if latest_at else None,
    )


def prune_readings(database: Database, older_than_days: int) -> int:
    """Retention. RA 10173 requires a stated retention policy, so one exists here.

    SOS events are deliberately *not* pruned: an emergency is a record worth
    keeping past a vitals-history window.
    """
    cutoff = iso(now() - timedelta(days=older_than_days))
    with database.transaction() as conn:
        cursor = conn.execute("DELETE FROM readings WHERE measured_at < ?", (cutoff,))
    return cursor.rowcount
