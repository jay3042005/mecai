"""Cross-language conformance for acute-flag evaluation.

The Flutter client evaluates alerts locally (see
`apps/mobile/lib/data/acute_flags.dart`) so an SpO2 of 88% raises an emergency
without a network. That is two implementations of one clinical rule set, which is a
drift risk.

`packages/tokens/alert-conformance.json` is the contract both must satisfy. It is
generated from the same thresholds the implementations read, so moving a cut-point in
`tokens.json` moves its boundary cases too rather than leaving a stale fixture that
still passes.

The Dart twin of this file is `apps/mobile/test/conformance_test.dart`. Both must be
kept in step; a case added here without a Dart counterpart is a gap, not a pass.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from mecai_api.models import Severity, VitalsReading
from mecai_api.risk import engine

_FIXTURE = (
    Path(__file__).resolve().parents[3] / "packages" / "tokens" / "alert-conformance.json"
)


def _load_cases() -> list[dict[str, Any]]:
    if not _FIXTURE.exists():  # pragma: no cover - setup failure
        pytest.fail(
            f"Conformance fixture missing at {_FIXTURE}. "
            "Run: node packages/tokens/generate.mjs"
        )
    return json.loads(_FIXTURE.read_text())["cases"]


CASES = _load_cases()


def test_fixture_is_populated():
    """Guards against an empty fixture silently passing every case below."""
    assert len(CASES) >= 30, f"expected a meaningful fixture, got {len(CASES)} cases"


@pytest.mark.parametrize("case", CASES, ids=[c["id"] for c in CASES])
def test_conformance(case: dict[str, Any]):
    reading = VitalsReading(**case["reading"])
    flags = engine.acute_flags(reading)
    expected = case["expect"]

    if expected is None:
        assert flags == [], (
            f"{case['id']}: expected no flag, got "
            f"{[(f.vital, f.severity.value) for f in flags]}"
        )
        return

    # Every fixture reading carries a single vital (or one BP pair), so exactly one
    # flag is the correct outcome — more would mean a vital was evaluated twice.
    assert len(flags) == 1, (
        f"{case['id']}: expected exactly one flag, got "
        f"{[(f.vital, f.severity.value) for f in flags]}"
    )

    flag = flags[0]
    assert flag.vital == expected["vital"], f"{case['id']}: wrong vital"
    assert flag.severity is Severity(expected["severity"]), (
        f"{case['id']}: expected {expected['severity']}, got {flag.severity.value}"
    )


def test_every_flag_carries_an_actionable_recommendation():
    """A flag that says something is wrong but not what to do is half a feature."""
    for case in CASES:
        if case["expect"] is None:
            continue
        flag = engine.acute_flags(VitalsReading(**case["reading"]))[0]
        assert flag.recommendation.strip(), f"{case['id']}: empty recommendation"
        assert flag.message.strip(), f"{case['id']}: empty message"
        # The threshold is what makes the alert legible without relying on colour.
        assert flag.threshold.strip(), f"{case['id']}: empty threshold"
