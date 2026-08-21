"""SQLite persistence.

Uses the standard library's ``sqlite3`` rather than an ORM. The schema is five
tables of flat numeric columns; an ORM would add a dependency and a migration
framework to a service whose entire data model fits on one screen.

### Why the assessment is stored alongside the reading

``readings`` carries the *band, percentage, and model version that were computed
when the reading arrived* — it is not re-scored on read. Re-scoring history with a
later model would silently rewrite what a patient was told last month. A clinician
looking at a trend needs to see the figure the patient actually saw, and the
``model_version`` column is what makes a later change auditable rather than
invisible.

### Why WAL

A dashboard polling ``GET /v1/patients`` must not block a phone mid-sync. In the
default rollback journal mode a writer excludes all readers; WAL lets them run
concurrently, which is the actual access pattern here.
"""

from __future__ import annotations

import json
import sqlite3
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

#: Bumped when the schema changes in a way ``_migrate`` must handle.
SCHEMA_VERSION = 1

_SCHEMA = """
CREATE TABLE IF NOT EXISTS patients (
    id                     TEXT PRIMARY KEY,
    display_name           TEXT NOT NULL,
    age                    INTEGER,
    sex                    TEXT,
    smoker                 INTEGER,
    diabetic               INTEGER,
    on_bp_medication       INTEGER,
    total_cholesterol_mgdl REAL,
    hdl_cholesterol_mgdl   REAL,
    baseline_systolic_mmhg REAL,
    family_history_cvd     INTEGER,
    device_name            TEXT,
    app_version            TEXT,
    created_at             TEXT NOT NULL,
    updated_at             TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS readings (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id     TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE,

    -- Client-generated UUID. The uniqueness constraint below is what makes
    -- re-sending a batch safe: a phone that loses the network mid-sync retries
    -- the whole batch, and the rows that already landed are ignored rather than
    -- duplicated into the trend chart.
    client_id      TEXT NOT NULL,

    systolic_mmhg  REAL,
    diastolic_mmhg REAL,
    heart_rate_bpm REAL,
    spo2_pct       REAL,
    temperature_c  REAL,
    ambient_temp_c REAL,
    motion_artifact INTEGER NOT NULL DEFAULT 0,

    measured_at    TEXT NOT NULL,
    received_at    TEXT NOT NULL,

    -- Assessment snapshot, computed at ingest. See module docstring.
    band           TEXT NOT NULL,
    value_pct      REAL,
    confidence     TEXT NOT NULL,
    model_version  TEXT NOT NULL,
    missing_fields TEXT NOT NULL DEFAULT '[]',

    -- Denormalised so the roster query does not have to parse JSON per row.
    flag_count     INTEGER NOT NULL DEFAULT 0,
    top_severity   TEXT,
    flags_json     TEXT NOT NULL DEFAULT '[]',

    UNIQUE (patient_id, client_id)
);

CREATE INDEX IF NOT EXISTS idx_readings_patient_time
    ON readings (patient_id, measured_at DESC);

CREATE TABLE IF NOT EXISTS sos_events (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id    TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    client_id     TEXT NOT NULL,
    triggered_at  TEXT NOT NULL,
    received_at   TEXT NOT NULL,
    source        TEXT NOT NULL,
    latitude      REAL,
    longitude     REAL,
    accuracy_m    REAL,
    -- Vitals at the moment the button was pressed. Denormalised on purpose: an
    -- SOS is the one record that must stay readable even if the reading rows
    -- around it were pruned by retention.
    heart_rate_bpm REAL,
    spo2_pct       REAL,
    temperature_c  REAL,
    note          TEXT,
    resolved_at   TEXT,
    UNIQUE (patient_id, client_id)
);

CREATE INDEX IF NOT EXISTS idx_sos_time ON sos_events (triggered_at DESC);

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


class Database:
    """Thread-confined SQLite connections behind a process-wide schema guard.

    FastAPI runs sync path operations in a thread pool, so a single shared
    connection would be used from several threads. ``sqlite3`` rejects that by
    default (and ``check_same_thread=False`` merely moves the race into C). One
    connection per thread avoids the question entirely.
    """

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self._local = threading.local()
        self._init_lock = threading.Lock()
        self._initialised = False

    # ─────────────────────────── connection ───────────────────────────

    def _connect(self) -> sqlite3.Connection:
        if self.path.parent != Path(""):
            self.path.parent.mkdir(parents=True, exist_ok=True)

        conn = sqlite3.connect(
            self.path,
            # A phone syncing over a slow link can hold a write lock briefly.
            # Failing instantly with "database is locked" would drop a reading
            # that was successfully transmitted, so wait instead.
            timeout=10.0,
            isolation_level=None,  # explicit transactions, see transaction()
        )
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute("PRAGMA synchronous = NORMAL")
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("PRAGMA busy_timeout = 10000")
        return conn

    @property
    def conn(self) -> sqlite3.Connection:
        existing: sqlite3.Connection | None = getattr(self._local, "conn", None)
        if existing is None:
            existing = self._connect()
            self._local.conn = existing
        self.ensure_schema()
        return existing

    def ensure_schema(self) -> None:
        if self._initialised:
            return
        with self._init_lock:
            if self._initialised:
                return
            conn: sqlite3.Connection = self._local.conn
            conn.executescript(_SCHEMA)
            conn.execute(
                "INSERT INTO meta (key, value) VALUES ('schema_version', ?) "
                "ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                (str(SCHEMA_VERSION),),
            )
            self._initialised = True

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        """Explicit transaction — a partially-written sync batch is not a record.

        ``isolation_level=None`` disables the driver's implicit transaction
        handling, so BEGIN/COMMIT are stated here rather than inferred from which
        statement happens to run first.
        """
        conn = self.conn
        conn.execute("BEGIN IMMEDIATE")
        try:
            yield conn
        except Exception:
            conn.execute("ROLLBACK")
            raise
        else:
            conn.execute("COMMIT")

    def close(self) -> None:
        conn: sqlite3.Connection | None = getattr(self._local, "conn", None)
        if conn is not None:
            conn.close()
            self._local.conn = None


def encode_list(values: list[str]) -> str:
    return json.dumps(values, separators=(",", ":"))


def decode_list(raw: str | None) -> list[str]:
    if not raw:
        return []
    decoded = json.loads(raw)
    return decoded if isinstance(decoded, list) else []
