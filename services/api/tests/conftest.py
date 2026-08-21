"""Shared fixtures.

The whole suite is redirected onto a throwaway database. Without this the
module-level ``main.database`` would lazily create ``.data/mecai.db`` under
whatever directory pytest was invoked from — so running the tests would write into
the same archive a real deployment uses, and a test that prunes or resolves would
be operating on patient records.
"""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from mecai_api import main
from mecai_api.db import Database
from mecai_api.models import PatientUpsert, RiskProfile


@pytest.fixture
def database(tmp_path: Path) -> Iterator[Database]:
    """A fresh on-disk database per test.

    On disk rather than ``:memory:`` because ``Database`` opens one connection per
    thread, and separate in-memory connections do not share a database — the
    schema a test set up on one thread would be invisible to the request handler
    running on another.
    """
    db = Database(tmp_path / "test.db")
    db.conn  # noqa: B018 — connect and apply the schema
    yield db
    db.close()


@pytest.fixture
def client(database: Database) -> Iterator[TestClient]:
    """A client whose requests hit ``database`` rather than the real archive."""
    main.app.dependency_overrides[main.get_db] = lambda: database
    try:
        with TestClient(main.app) as test_client:
            yield test_client
    finally:
        main.app.dependency_overrides.clear()


@pytest.fixture
def scorable_profile() -> RiskProfile:
    """A profile the model can actually score on current hardware.

    Carries ``baseline_systolic_mmhg``: the watch has no cuff, so without a
    self-reported resting systolic every reading is unscorable.
    """
    return RiskProfile(
        age=55,
        sex="male",
        smoker=False,
        diabetic=False,
        total_cholesterol_mgdl=213,
        hdl_cholesterol_mgdl=50,
        baseline_systolic_mmhg=125,
    )


@pytest.fixture
def enrolled(client: TestClient, scorable_profile: RiskProfile) -> str:
    """A registered patient id, ready to receive readings."""
    payload = PatientUpsert(
        patient_id="patient-test-0001",
        display_name="T. Villanueva",
        profile=scorable_profile,
        device_name="MECAI-Watch",
        app_version="0.1.0",
    )
    response = client.post("/v1/patients", json=payload.model_dump(mode="json"))
    assert response.status_code == 200, response.text
    return payload.patient_id
