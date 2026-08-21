"""Pydantic schemas for the MEC-AI API.

Design constraints these types enforce (see docs/design.md §4):

* A risk assessment can never be returned without ``factors`` and ``confidence``.
  The UI's redundant-channel and incomplete-profile states depend on them, so
  they are required fields rather than optional extras.
* ``RiskFactor.source`` records whether each input came from the device or the
  questionnaire. The device cannot measure cholesterol, smoking, or diabetes,
  and the user is entitled to see which is which.
* Ten-year risk and acute early-warning flags are separate types. They answer
  different questions and must never be conflated in the UI.
"""

from __future__ import annotations

from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel, Field, model_validator

DISCLAIMER = "Screening indicator, not a diagnosis. Consult a physician."


class Sex(StrEnum):
    female = "female"
    male = "male"


class RiskBand(StrEnum):
    low = "low"
    moderate = "moderate"
    high = "high"
    unknown = "unknown"
    """No colour band is rendered for ``unknown`` — the ring goes dashed neutral."""


class Confidence(StrEnum):
    complete = "complete"
    """All model inputs present. A validated figure may be shown."""

    incomplete = "incomplete"
    """Inputs missing. Band MUST be ``unknown``; no percentage may be displayed."""


class Severity(StrEnum):
    info = "info"
    warning = "warning"
    critical = "critical"


class FactorSource(StrEnum):
    device = "device"
    profile = "profile"


# ─────────────────────────────── inputs ───────────────────────────────


class VitalsReading(BaseModel):
    """One measurement set from the device.

    **Every vital is optional**, because the hardware is built incrementally. The
    current firmware (``MEC-AI3.ino``) reports heart rate and SpO2 only — it has no
    pressure sensor and no contact temperature sensor. A model that required all
    four would reject every real reading, so instead the API accepts what the
    device can measure and reports honestly what it therefore cannot compute.

    Ranges are physiological-plausibility bounds, not clinical limits. A value
    outside these is rejected as a sensor fault rather than displayed — a cuff
    reporting 400 mmHg has failed, and showing that as a health event is worse
    than showing nothing.
    """

    systolic_mmhg: float | None = Field(default=None, ge=50, le=300)
    diastolic_mmhg: float | None = Field(default=None, ge=25, le=200)
    heart_rate_bpm: float | None = Field(default=None, ge=25, le=250)
    spo2_pct: float | None = Field(default=None, ge=50, le=100)

    #: **Body** temperature, from a contact sensor (MAX30205 / MLX90614).
    #: Do not populate this from an ambient sensor — see ``ambient_temp_c``.
    temperature_c: float | None = Field(default=None, ge=30.0, le=45.0)

    #: Enclosure/room air temperature, e.g. the SHT30x in the current firmware.
    #:
    #: Deliberately a separate field. An SHT30x in a wrist enclosure reads air
    #: influenced by ambient conditions, body heat, and self-heating from the MCU
    #: and display — it is not core temperature. Feeding it to ``temperature_c``
    #: would fire a critical hypothermia flag in an air-conditioned room. This
    #: field is recorded for context and never generates a clinical flag.
    ambient_temp_c: float | None = Field(default=None, ge=0.0, le=60.0)

    measured_at: datetime
    motion_artifact: bool = Field(
        default=False,
        description="Set when accelerometer variance during measurement was high.",
    )

    @model_validator(mode="after")
    def _systolic_above_diastolic(self) -> VitalsReading:
        if self.systolic_mmhg is None or self.diastolic_mmhg is None:
            return self
        if self.systolic_mmhg <= self.diastolic_mmhg:
            raise ValueError(
                f"systolic ({self.systolic_mmhg}) must exceed diastolic "
                f"({self.diastolic_mmhg}) — likely a sensor or cuff fault"
            )
        return self

    @model_validator(mode="after")
    def _at_least_one_vital(self) -> VitalsReading:
        """A reading with no vitals at all is a bug in the caller, not a datapoint."""
        if not any(
            v is not None
            for v in (
                self.systolic_mmhg,
                self.diastolic_mmhg,
                self.heart_rate_bpm,
                self.spo2_pct,
                self.temperature_c,
                self.ambient_temp_c,
            )
        ):
            raise ValueError("a reading must carry at least one vital")
        return self


class RiskProfile(BaseModel):
    """Questionnaire inputs the device cannot sense.

    Cholesterol is optional because most users will not know it. When absent the
    engine returns ``Confidence.incomplete`` rather than guessing a population
    mean — a fabricated input would produce a confident-looking figure with no
    validity behind it.
    """

    age: int = Field(ge=18, le=110)
    sex: Sex
    smoker: bool
    diabetic: bool
    on_bp_medication: bool = False
    total_cholesterol_mgdl: float | None = Field(default=None, ge=100, le=450)
    hdl_cholesterol_mgdl: float | None = Field(default=None, ge=10, le=150)
    family_history_cvd: bool = False

    #: Resting systolic pressure the user entered, from a clinic visit or a home
    #: cuff.
    #:
    #: Framingham requires a systolic pressure and the MEC-AI watch does not
    #: measure one — its firmware streams heart rate, SpO2 and temperature only.
    #: Without this field the ten-year score could *never* be computed on the
    #: current hardware, so it is part of the questionnaire rather than something
    #: the device is expected to supply.
    #:
    #: A live cuff reading always wins over this value; see ``engine.assess``.
    #: This is deliberately not a substituted population mean — it is a real
    #: measurement the user reports, and ``FactorSource.profile`` records that it
    #: came from them rather than from the device.
    baseline_systolic_mmhg: float | None = Field(default=None, ge=50, le=300)

    def missing_for_scoring(self, reading: VitalsReading | None = None) -> list[str]:
        """Fields the validated model needs that neither profile nor reading supply.

        ``reading`` is optional so a profile can report its own completeness
        (the mobile profile screen's meter) without inventing a measurement. When
        given, a live systolic from the device satisfies the pressure requirement.
        """
        missing: list[str] = []
        if self.total_cholesterol_mgdl is None:
            missing.append("total_cholesterol_mgdl")
        if self.hdl_cholesterol_mgdl is None:
            missing.append("hdl_cholesterol_mgdl")

        measured_systolic = reading.systolic_mmhg if reading is not None else None
        if measured_systolic is None and self.baseline_systolic_mmhg is None:
            missing.append("systolic_mmhg")
        return missing


class AssessmentRequest(BaseModel):
    profile: RiskProfile
    reading: VitalsReading


# ─────────────────────────────── outputs ──────────────────────────────


class RiskFactor(BaseModel):
    """One input's contribution, in terms a user can read.

    ``contribution`` is the input's share of the linear predictor, normalised so
    the factors sum to 1.0. It explains *relative* weight within this score; it
    is not an independent risk figure and must not be rendered as a percentage
    of risk.
    """

    name: str
    display_value: str
    contribution: float = Field(ge=0.0, le=1.0)
    source: FactorSource
    modifiable: bool = Field(
        description="Whether the user can act on it. Drives which factors get a recommendation."
    )


class RiskAssessment(BaseModel):
    band: RiskBand
    value_pct: float | None = Field(
        default=None,
        description="Ten-year absolute risk. None when confidence is incomplete.",
    )
    horizon: str = Field(default="10-year")
    factors: list[RiskFactor]
    confidence: Confidence
    missing_fields: list[str] = Field(default_factory=list)
    model_version: str
    disclaimer: str = DISCLAIMER

    @model_validator(mode="after")
    def _incomplete_hides_figure(self) -> RiskAssessment:
        """Structural guard for docs/design.md §4.

        An incomplete profile must not yield a number or a coloured band. Enforcing
        it here means a future client cannot bypass the rule by ignoring the
        ``confidence`` field.
        """
        if self.confidence is Confidence.incomplete:
            if self.value_pct is not None:
                raise ValueError("incomplete confidence must not carry a value_pct")
            if self.band is not RiskBand.unknown:
                raise ValueError("incomplete confidence must report band=unknown")
        elif self.value_pct is None:
            raise ValueError("complete confidence requires a value_pct")
        return self


class AcuteFlag(BaseModel):
    """An immediate out-of-range vital.

    Distinct from ``RiskAssessment``: this is "something is wrong now", not
    "your ten-year outlook". The spec's early-warning notifications come from
    here, never from the risk percentage.
    """

    severity: Severity
    vital: str
    display_value: str
    threshold: str
    message: str
    recommendation: str


class AssessmentResponse(BaseModel):
    assessment: RiskAssessment
    acute_flags: list[AcuteFlag]
    reading_accepted: bool = True
    notes: list[str] = Field(default_factory=list)


# ──────────────────────── persistence / sync ──────────────────────────
#
# The mobile app is the system of record for a reading until it is acknowledged
# here. It writes to its own SQLite store first, then backs up in batches; these
# types describe that handoff.


class PatientUpsert(BaseModel):
    """Registers a phone with the service, or updates its questionnaire.

    ``patient_id`` is generated by the app on first launch and never leaves the
    device's own store. A server-assigned id would strand every reading recorded
    before the phone first reached the network — which, for a rural device, is
    the normal case rather than an edge case.
    """

    patient_id: str = Field(min_length=8, max_length=64)
    display_name: str = Field(min_length=1, max_length=80)
    profile: RiskProfile
    device_name: str | None = Field(default=None, max_length=80)
    app_version: str | None = Field(default=None, max_length=32)


class ReadingUpload(VitalsReading):
    """A reading plus the client-side identity that makes re-sync idempotent.

    A phone on a rural network will lose a connection mid-batch and retry. Without
    a stable per-reading id the retry duplicates every row that did land, and the
    duplicates are indistinguishable from a genuinely rapid measurement sequence —
    they would show up as real spikes in a clinical trend chart.
    """

    client_id: str = Field(min_length=8, max_length=64)


class SyncRequest(BaseModel):
    patient_id: str = Field(min_length=8, max_length=64)

    #: Sent with the batch so a profile edited offline reaches the server on the
    #: same round-trip that carries the readings it should be scored against.
    profile: RiskProfile | None = None

    readings: list[ReadingUpload] = Field(default_factory=list, max_length=500)


class SyncResponse(BaseModel):
    """Deliberately reports duplicates rather than silently absorbing them.

    ``stored + duplicates`` is what the phone marks as synced — a duplicate means
    the server already has that reading, which is success from the phone's point
    of view. ``rejected`` is not: those rows stay unsynced and are reported so a
    systematic client bug shows up instead of quietly dropping data.
    """

    patient_id: str
    stored: int
    duplicates: int
    rejected: list[str] = Field(default_factory=list)
    server_time: datetime


class StoredReading(VitalsReading):
    """A reading as it came back out of the database.

    Carries the assessment computed *at ingest*, not a fresh one. See
    ``db`` module docstring: re-scoring history with a later model would rewrite
    what a patient was told, and a trend chart must show the figures they saw.
    """

    client_id: str
    received_at: datetime
    band: RiskBand
    value_pct: float | None
    confidence: Confidence
    model_version: str
    missing_fields: list[str] = Field(default_factory=list)
    acute_flags: list[AcuteFlag] = Field(default_factory=list)


class PatientSummary(BaseModel):
    """One row of the dashboard roster."""

    patient_id: str
    display_name: str
    profile: RiskProfile
    device_name: str | None = None
    reading_count: int = 0
    first_reading_at: datetime | None = None
    last_reading_at: datetime | None = None
    latest: StoredReading | None = None
    open_sos_count: int = 0


class SosUpload(BaseModel):
    """An SOS press, with the location that makes it actionable.

    Location is optional because permission can be denied or a fix can be
    unavailable indoors. An SOS with no coordinates is still an SOS and must be
    recorded — refusing it for want of GPS would discard the alert precisely when
    someone is somewhere with poor signal.
    """

    patient_id: str = Field(min_length=8, max_length=64)
    client_id: str = Field(min_length=8, max_length=64)
    triggered_at: datetime
    source: str = Field(default="app", pattern="^(app|watch)$")
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    accuracy_m: float | None = Field(default=None, ge=0, le=100_000)
    heart_rate_bpm: float | None = Field(default=None, ge=25, le=250)
    spo2_pct: float | None = Field(default=None, ge=50, le=100)
    temperature_c: float | None = Field(default=None, ge=30.0, le=45.0)
    note: str | None = Field(default=None, max_length=500)


class SosEvent(SosUpload):
    id: int
    display_name: str
    received_at: datetime
    resolved_at: datetime | None = None

    @property
    def has_location(self) -> bool:
        return self.latitude is not None and self.longitude is not None


class FleetStats(BaseModel):
    """Dashboard header counters."""

    patients: int
    readings: int
    readings_last_24h: int
    open_sos: int
    patients_with_alerts: int
    band_counts: dict[str, int] = Field(default_factory=dict)
    latest_reading_at: datetime | None = None
