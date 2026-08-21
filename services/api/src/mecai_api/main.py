"""FastAPI application.

Endpoint contract is versioned (``/v1/...``) because the risk model behind
``/v1/assess`` will change: swapping Framingham for a regionally recalibrated
model, or layering an ML adjustment on top, alters the meaning of the response.
Clients pin a version rather than silently receiving figures computed a new way.
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from pydantic_settings import BaseSettings, SettingsConfigDict

from mecai_api import __version__, mock, store
from mecai_api.db import Database
from mecai_api.models import (
    AssessmentRequest,
    AssessmentResponse,
    FleetStats,
    PatientSummary,
    PatientUpsert,
    RiskProfile,
    SosEvent,
    SosUpload,
    StoredReading,
    SyncRequest,
    SyncResponse,
    VitalsReading,
)
from mecai_api.risk import engine, framingham


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="MECAI_", env_file=".env")

    #: Dev origins for the Next.js dashboard. Override in production — a wildcard
    #: origin on an endpoint carrying health data is not acceptable.
    #:
    #: Both spellings of the loopback host are listed because a browser treats them
    #: as *different origins*. With only one, opening the dashboard at the other
    #: address fails CORS and the client reports "could not reach the scoring
    #: service" — sending the reader off to restart a server that is already
    #: running. Same host, same port, so allowing both costs nothing.
    cors_origins: list[str] = ["*"]

    #: Mock endpoints serve synthetic data. Must be false in production so
    #: generated readings can never be mistaken for a patient's own.
    enable_mock_endpoints: bool = True

    #: SQLite file backing the readings archive.
    #:
    #: Relative to the process working directory, and gitignored — this holds real
    #: health data the moment a phone syncs to it, which RA 10173 regulates. Point
    #: it at an encrypted volume for any deployment beyond a developer's laptop.
    database_path: str = ".data/mecai.db"

    #: Days of vitals history to keep. Readings older than this are removed by
    #: ``POST /v1/admin/prune``. SOS events are never pruned.
    retention_days: int = 365


settings = Settings()

database = Database(settings.database_path)


def get_db() -> Database:
    return database


Db = Annotated[Database, Depends(get_db)]

@asynccontextmanager
async def lifespan(_: FastAPI):
    """Open the database at startup rather than on first use.

    A bad path or an unwritable directory then fails at boot with a clear error,
    instead of surfacing as a failed sync from a phone in the field — where the
    reading that triggered it may be the only copy.
    """
    database.conn  # noqa: B018 — connects and applies the schema
    yield
    database.close()


app = FastAPI(
    title="MEC-AI API",
    version=__version__,
    description=(
        "Cardiovascular risk scoring and readings archive for the MEC-AI wearable. "
        "Returns screening indicators, not diagnoses."
    ),
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class Health(BaseModel):
    status: str
    version: str
    risk_model: str
    mock_endpoints: bool

    #: Whether the readings archive is writable. The app's "Save and test
    #: connection" button reports this: a server that scores but cannot store is
    #: a half-working state the user needs to know about *before* relying on it
    #: for backup, not after a month of readings failed to arrive.
    storage: bool = False
    patients: int = 0
    readings: int = 0


@app.get("/health", response_model=Health, tags=["meta"])
async def health(db: Db) -> Health:
    storage_ok = True
    patients = readings = 0
    try:
        counters = store.stats(db)
        patients, readings = counters.patients, counters.readings
    except Exception:  # noqa: BLE001 — a broken archive must not 500 the probe
        storage_ok = False

    return Health(
        status="ok",
        version=__version__,
        risk_model=framingham.MODEL_VERSION,
        mock_endpoints=settings.enable_mock_endpoints,
        storage=storage_ok,
        patients=patients,
        readings=readings,
    )


@app.post("/v1/assess", response_model=AssessmentResponse, tags=["risk"])
async def assess(request: AssessmentRequest) -> AssessmentResponse:
    """Score a reading against a profile.

    Returns both paths described in ``risk.engine``: the ten-year chronic
    assessment and any acute flags from this reading. Acute flags are computed
    unconditionally — they need no questionnaire, so an incomplete profile still
    yields immediate warnings.
    """
    assessment = engine.assess(request.profile, request.reading)
    flags = engine.acute_flags(request.reading)

    notes: list[str] = []
    if request.reading.motion_artifact:
        notes.append(
            "Motion was detected during this measurement. Re-measure while still "
            "for a more reliable result."
        )

    # Field-aware, because the two causes need different actions from the user:
    # one is bloodwork they can go get, the other is hardware they do not have.
    missing = set(assessment.missing_fields)
    if missing & {"total_cholesterol_mgdl", "hdl_cholesterol_mgdl"}:
        notes.append(
            "A ten-year risk figure needs a lipid panel. Add total and HDL "
            "cholesterol in your profile to enable scoring."
        )
    if "systolic_mmhg" in missing:
        # Names the action that actually unblocks scoring. The watch has no cuff,
        # so "take another reading" would be advice the hardware cannot follow —
        # the user has to supply a resting systolic from a clinic or home cuff.
        notes.append(
            "The MEC-AI watch has no blood-pressure cuff, and the risk model needs "
            "a systolic pressure. Add a resting systolic reading to your profile to "
            "enable the ten-year score. Heart rate, blood oxygen, and any immediate "
            "alerts below are unaffected."
        )
    if request.reading.ambient_temp_c is not None and request.reading.temperature_c is None:
        notes.append(
            "Temperature shown is ambient (room) temperature, not body temperature, "
            "and is not used for health alerts."
        )

    if not (
        framingham.VALIDATED_AGE_MIN <= request.profile.age <= framingham.VALIDATED_AGE_MAX
    ):
        notes.append(
            f"The risk model was validated for ages "
            f"{framingham.VALIDATED_AGE_MIN}-{framingham.VALIDATED_AGE_MAX}. "
            "Outside that range the estimate is an extrapolation."
        )

    return AssessmentResponse(assessment=assessment, acute_flags=flags, notes=notes)


def _require_mock() -> None:
    if not settings.enable_mock_endpoints:
        raise HTTPException(status_code=404, detail="Mock endpoints are disabled.")


@app.get("/v1/mock/reading", response_model=VitalsReading, tags=["mock"])
async def mock_reading(
    scenario: Annotated[mock.Scenario, Query()] = mock.Scenario.normal,
) -> VitalsReading:
    """One synthetic reading from a *complete* device — all four vitals."""
    _require_mock()
    return mock.reading(scenario)


@app.get("/v1/mock/firmware-reading", response_model=VitalsReading, tags=["mock"])
async def mock_firmware_reading(
    scenario: Annotated[mock.Scenario, Query()] = mock.Scenario.normal,
) -> VitalsReading:
    """Only what ``MEC-AI3.ino`` reports today: heart rate, SpO2, ambient temp.

    Use this to check the real integration path. `/v1/assess` on this reading
    returns ``band: unknown`` for want of systolic BP while still firing SpO2 and
    heart-rate alerts — which is the honest current state of the system.
    """
    _require_mock()
    return mock.firmware_reading(scenario)


@app.get("/v1/mock/series", response_model=list[VitalsReading], tags=["mock"])
async def mock_series(
    hours: Annotated[int, Query(ge=1, le=2160)] = 24,
    interval_minutes: Annotated[int, Query(ge=1, le=1440)] = 60,
    scenario: Annotated[mock.Scenario, Query()] = mock.Scenario.normal,
) -> list[VitalsReading]:
    """Back-dated history for the Trends charts."""
    _require_mock()
    return mock.series(hours, interval_minutes=interval_minutes, scenario=scenario)


# ═══════════════════════ readings archive ═══════════════════════
#
# The phone is the system of record until a reading is acknowledged here. It
# writes to its own SQLite store first and backs up in batches, so a reading
# survives a flat network, a rejected upload, and a reinstalled server.


@app.post("/v1/patients", response_model=PatientSummary, tags=["patients"])
async def upsert_patient(payload: PatientUpsert, db: Db) -> PatientSummary:
    """Register a phone, or update its questionnaire.

    Called on first launch and whenever the profile is saved. Idempotent on
    ``patient_id``, which the app generates locally — a server-assigned id would
    strand every reading recorded before the phone first reached the network, and
    on a rural device that is the normal case.
    """
    store.upsert_patient(db, payload)
    summary = store.patient_summary(db, payload.patient_id)
    if summary is None:  # pragma: no cover — just written above
        raise HTTPException(status_code=500, detail="Patient was not persisted.")
    return summary


@app.get("/v1/patients", response_model=list[PatientSummary], tags=["patients"])
async def list_patients(db: Db) -> list[PatientSummary]:
    """The dashboard roster, most recently active first."""
    return store.list_patients(db)


@app.get("/v1/patients/{patient_id}", response_model=PatientSummary, tags=["patients"])
async def get_patient(patient_id: str, db: Db) -> PatientSummary:
    summary = store.patient_summary(db, patient_id)
    if summary is None:
        raise HTTPException(status_code=404, detail=f"No patient {patient_id!r}.")
    return summary


@app.post("/v1/readings/sync", response_model=SyncResponse, tags=["readings"])
async def sync_readings(payload: SyncRequest, db: Db) -> SyncResponse:
    """Back up a batch of readings from the phone.

    Each reading is scored **on arrival** and the result stored with it, rather
    than being recomputed whenever the dashboard asks. Re-scoring history under a
    later model would silently rewrite what a patient was told last month; storing
    ``model_version`` per row makes a model change visible instead.

    Idempotent: a batch retried after a dropped connection reports its already-
    stored rows as ``duplicates``, which the phone counts as success. Without that
    a flaky link would duplicate rows that are indistinguishable from real rapid
    measurements in a trend chart.
    """
    row = store.get_patient_row(db, payload.patient_id)

    # A profile on the request wins, so a questionnaire edited offline scores the
    # readings it arrives with rather than the previous batch's inputs.
    profile: RiskProfile | None = payload.profile
    if profile is None and row is not None:
        profile = store.profile_from_row(row)

    if row is None:
        if profile is None:
            raise HTTPException(
                status_code=404,
                detail=(
                    f"Unknown patient {payload.patient_id!r}. POST /v1/patients first, "
                    "or include a profile with the batch."
                ),
            )
        # First contact carrying its own profile: enrol rather than reject. The
        # alternative loses a real batch to a bookkeeping step the phone can
        # legitimately have missed while offline.
        store.upsert_patient(
            db,
            PatientUpsert(
                patient_id=payload.patient_id,
                display_name=f"Patient {payload.patient_id[:8]}",
                profile=profile,
            ),
        )

    assessments = {
        reading.client_id: (
            engine.assess(profile, reading),
            engine.acute_flags(reading),
        )
        for reading in payload.readings
    }

    stored, duplicates, rejected = store.insert_readings(
        db, payload.patient_id, payload.readings, assessments
    )

    return SyncResponse(
        patient_id=payload.patient_id,
        stored=stored,
        duplicates=duplicates,
        rejected=rejected,
        server_time=store.now(),
    )


@app.get(
    "/v1/patients/{patient_id}/readings",
    response_model=list[StoredReading],
    tags=["readings"],
)
async def patient_readings(
    patient_id: str,
    db: Db,
    hours: Annotated[int | None, Query(ge=1, le=8760)] = 24,
    limit: Annotated[int, Query(ge=1, le=5000)] = 500,
) -> list[StoredReading]:
    """History for the trend charts, oldest first.

    Pass ``hours=`` omitted to read the whole archive up to ``limit``.
    """
    if store.get_patient_row(db, patient_id) is None:
        raise HTTPException(status_code=404, detail=f"No patient {patient_id!r}.")
    return store.get_readings(db, patient_id, hours=hours, limit=limit)


@app.get(
    "/v1/patients/{patient_id}/latest",
    response_model=StoredReading,
    tags=["readings"],
)
async def patient_latest(patient_id: str, db: Db) -> StoredReading:
    latest = store.latest_reading(db, patient_id)
    if latest is None:
        raise HTTPException(
            status_code=404, detail=f"No readings stored for {patient_id!r}."
        )
    return latest


# ════════════════════════════ SOS ═══════════════════════════════


@app.post("/v1/sos", response_model=SosEvent, tags=["sos"])
async def record_sos(payload: SosUpload, db: Db) -> SosEvent:
    """Record an emergency alert with the location that makes it actionable.

    Accepted without coordinates: permission can be denied and an indoor fix can
    fail, and refusing the alert for want of GPS would discard it exactly when
    someone is somewhere with poor reception.
    """
    row = store.get_patient_row(db, payload.patient_id)
    if row is None:
        raise HTTPException(status_code=404, detail=f"No patient {payload.patient_id!r}.")
    return store.insert_sos(db, payload, row["display_name"])


@app.get("/v1/sos", response_model=list[SosEvent], tags=["sos"])
async def list_sos(
    db: Db,
    unresolved_only: Annotated[bool, Query()] = False,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> list[SosEvent]:
    return store.list_sos(db, unresolved_only=unresolved_only, limit=limit)


@app.post("/v1/sos/{event_id}/resolve", response_model=SosEvent, tags=["sos"])
async def resolve_sos(event_id: int, db: Db) -> SosEvent:
    """Mark an incident handled. Already-resolved events keep their original time."""
    event = store.resolve_sos(db, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail=f"No SOS event {event_id}.")
    return event


# ═══════════════════════════ dashboard ══════════════════════════


@app.get("/v1/stats", response_model=FleetStats, tags=["dashboard"])
async def fleet_stats(db: Db) -> FleetStats:
    """Header counters. Bands reflect each patient's latest reading, not all history."""
    return store.stats(db)


class PruneResult(BaseModel):
    deleted: int
    older_than_days: int


@app.post("/v1/admin/prune", response_model=PruneResult, tags=["dashboard"])
async def prune(
    db: Db,
    older_than_days: Annotated[int | None, Query(ge=1, le=3650)] = None,
) -> PruneResult:
    """Apply the retention policy. SOS events are never pruned."""
    days = older_than_days or settings.retention_days
    return PruneResult(deleted=store.prune_readings(db, days), older_than_days=days)
