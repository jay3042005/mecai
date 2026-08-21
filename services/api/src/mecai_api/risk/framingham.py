"""Framingham General CVD Risk Score (10-year).

Reference
--------
D'Agostino RB Sr, Vasan RS, Pencina MJ, Wolf PA, Cobain M, Massaro JM, Kannel WB.
"General Cardiovascular Risk Profile for Use in Primary Care: The Framingham
Heart Study." *Circulation*. 2008;117(6):743-753.

Why this and not a bespoke model
--------------------------------
MEC-AI's sensors measure blood pressure, heart rate, SpO2, and temperature. A
validated cardiovascular risk figure additionally requires age, sex, smoking
status, diabetes, and a lipid panel — none of which any cuff can sense. Deriving
a "risk percentage" from vitals alone would produce an unvalidated number
wearing the authority of a clinical one.

So this module is the defensible backbone: a published, peer-reviewed,
sex-specific Cox model whose output *is* a 10-year absolute risk. The vitals
stream feeds it the one input it needs and MEC-AI can actually measure
(systolic BP), and drives the separate acute-flag path in ``engine.py``.

Validity envelope
-----------------
Derived on a cohort aged 30-74 without prevalent CVD. Outside that age range the
model extrapolates and ``age_out_of_validated_range`` is set so callers can
surface the caveat. Cholesterol inputs are **mg/dL** (multiply mmol/L by 38.67
for total/LDL cholesterol, by 38.67 for HDL).
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from mecai_api.models import Sex

MODEL_VERSION = "framingham-general-cvd-2008"

#: Cohort age bounds the published model was derived on.
VALIDATED_AGE_MIN = 30
VALIDATED_AGE_MAX = 74

#: 10-year risk band cut-points. Aligned with the conventional
#: low / intermediate / high split used for general CVD risk.
BAND_MODERATE_MIN_PCT = 10.0
BAND_HIGH_MIN_PCT = 20.0


@dataclass(frozen=True)
class _Coefficients:
    """Sex-specific beta coefficients, baseline survival, and cohort mean."""

    ln_age: float
    ln_total_chol: float
    ln_hdl: float
    ln_sbp_untreated: float
    ln_sbp_treated: float
    smoker: float
    diabetic: float
    mean_linear_predictor: float
    baseline_survival_10yr: float


#: Table 2 of D'Agostino 2008.
_COEFFS: dict[Sex, _Coefficients] = {
    Sex.female: _Coefficients(
        ln_age=2.32888,
        ln_total_chol=1.20904,
        ln_hdl=-0.70833,
        ln_sbp_untreated=2.76157,
        ln_sbp_treated=2.82263,
        smoker=0.52873,
        diabetic=0.69154,
        mean_linear_predictor=26.1931,
        baseline_survival_10yr=0.95012,
    ),
    Sex.male: _Coefficients(
        ln_age=3.06117,
        ln_total_chol=1.12370,
        ln_hdl=-0.93263,
        ln_sbp_untreated=1.93303,
        ln_sbp_treated=1.99881,
        smoker=0.65451,
        diabetic=0.57367,
        mean_linear_predictor=23.9802,
        baseline_survival_10yr=0.88936,
    ),
}


@dataclass
class FraminghamResult:
    """A scored 10-year risk plus the per-term breakdown behind it."""

    risk_pct: float
    linear_predictor: float
    #: term name -> absolute contribution to the linear predictor
    terms: dict[str, float] = field(default_factory=dict)
    age_out_of_validated_range: bool = False


def score(
    *,
    age: int,
    sex: Sex,
    systolic_mmhg: float,
    total_cholesterol_mgdl: float,
    hdl_cholesterol_mgdl: float,
    smoker: bool,
    diabetic: bool,
    on_bp_medication: bool = False,
) -> FraminghamResult:
    """Compute 10-year general CVD risk.

    The model is ``risk = 1 - S0(10) ** exp(L - L_mean)`` where ``L`` is the sum
    of beta-weighted (log-transformed, for continuous inputs) covariates.

    Returns
    -------
    FraminghamResult
        ``risk_pct`` is an absolute 10-year percentage, clamped to [0, 100].
        ``terms`` carries each covariate's absolute contribution to ``L``, used
        upstream to build the user-facing factor breakdown.
    """
    c = _COEFFS[sex]

    sbp_beta = c.ln_sbp_treated if on_bp_medication else c.ln_sbp_untreated

    terms = {
        "age": c.ln_age * math.log(age),
        "total_cholesterol": c.ln_total_chol * math.log(total_cholesterol_mgdl),
        "hdl_cholesterol": c.ln_hdl * math.log(hdl_cholesterol_mgdl),
        "systolic_bp": sbp_beta * math.log(systolic_mmhg),
        "smoking": c.smoker * (1.0 if smoker else 0.0),
        "diabetes": c.diabetic * (1.0 if diabetic else 0.0),
    }

    linear_predictor = sum(terms.values())
    excess = linear_predictor - c.mean_linear_predictor

    # math.exp overflows around 709; a linear predictor that extreme means the
    # inputs are already nonsensical, so saturate at certainty rather than raise.
    try:
        risk = 1.0 - c.baseline_survival_10yr ** math.exp(excess)
    except OverflowError:  # pragma: no cover - defensive
        risk = 1.0

    return FraminghamResult(
        risk_pct=max(0.0, min(100.0, risk * 100.0)),
        linear_predictor=linear_predictor,
        terms=terms,
        age_out_of_validated_range=not (VALIDATED_AGE_MIN <= age <= VALIDATED_AGE_MAX),
    )


def band_for(risk_pct: float) -> str:
    """Map an absolute 10-year risk to a band key.

    Returns the string key (``"low"`` / ``"moderate"`` / ``"high"``) rather than
    the enum to keep this module free of presentation concerns.
    """
    if risk_pct >= BAND_HIGH_MIN_PCT:
        return "high"
    if risk_pct >= BAND_MODERATE_MIN_PCT:
        return "moderate"
    return "low"
