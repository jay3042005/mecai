"use client";

/**
 * The risk indicator — web twin of `apps/mobile/lib/widgets/risk_ring.dart`.
 *
 * Four redundant channels (docs/design.md §4):
 *   1. word   — the band label, always visible
 *   2. icon   — a distinct silhouette per band
 *   3. arc    — proportional fill, readable with zero colour
 *   4. colour — last, and never load-bearing alone
 *
 * ### Why not Magic UI's `animated-circular-progress-bar`
 *
 * That component renders a 0–100 gauge and nothing else. This ring needs three
 * things it cannot express: a 0–40% display scale, tick marks at the clinical
 * band boundaries, and a dashed neutral state for an unscorable profile. It also
 * has no place for the word or the icon, which are the channels that make the
 * indicator safe. So the gauge is hand-rolled; `NumberTicker` below follows
 * Magic UI's pattern for the figure itself.
 *
 * ### Why the scale is 0–40%, not 0–100%
 *
 * Ten-year CVD risk bands at <10 / 10–20 / >=20. On a 0–100 ring a 42% risk
 * renders as "less than half full", which reads as reassuring and is the opposite
 * of true. Sweeping 0–40% with boundary ticks makes arc length mean something.
 */

import { useEffect, useReducer, useState } from "react";

import { BANDS } from "@/components/risk-band";
import type { RiskAssessment } from "@/lib/api";
import { usePrefersReducedMotion } from "@/lib/use-reduced-motion";

const DISPLAY_MAX_PCT = 40;

/** 270° sweep starting lower-left, leaving the bottom open for the caption. */
const SWEEP_FRACTION = 0.75;
const RADIUS = 116;
const STROKE = 14;
const SIZE = (RADIUS + STROKE) * 2;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;
const ARC_LENGTH = CIRCUMFERENCE * SWEEP_FRACTION;

/**
 * Counts up to `value`, following Magic UI's Number Ticker pattern.
 *
 * Under reduced motion the final value is *derived*, not set in an effect — a
 * hard requirement, not a nicety (docs/design.md §3.6).
 */
function NumberTicker({
  value,
  decimals,
  durationMs = 900,
}: {
  value: number;
  decimals: number;
  durationMs?: number;
}) {
  const reduced = usePrefersReducedMotion();
  const [progress, setProgress] = useState(0);

  useEffect(() => {
    if (reduced) return;

    let frame = 0;
    const start = performance.now();

    const step = (now: number) => {
      const t = Math.min(1, (now - start) / durationMs);
      // easeOutCubic, matching --m-value's curve on mobile.
      setProgress(1 - Math.pow(1 - t, 3));
      if (t < 1) frame = requestAnimationFrame(step);
    };

    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
  }, [value, durationMs, reduced]);

  const displayed = reduced ? value : value * progress;

  // Proportional figures — `tabular-nums` makes a number like 121 look loose at
  // display sizes, so it is reserved for axis ticks and table columns.
  return <>{displayed.toFixed(decimals)}%</>;
}

export function RiskRing({
  assessment,
  onShowFactors,
  onCompleteProfile,
}: {
  assessment: RiskAssessment;
  onShowFactors?: () => void;
  onCompleteProfile?: () => void;
}) {
  const reduced = usePrefersReducedMotion();
  const [mounted, dispatchMounted] = useReducer(() => true, false);

  const scored = assessment.confidence === "complete" && assessment.value_pct !== null;
  const pct = assessment.value_pct ?? 0;
  const band = BANDS[assessment.band];

  useEffect(() => {
    // One frame before filling, so the stroke transition actually runs.
    const id = requestAnimationFrame(dispatchMounted);
    return () => cancelAnimationFrame(id);
  }, []);

  const fraction = Math.min(1, Math.max(0, pct / DISPLAY_MAX_PCT));
  const filled = reduced || mounted ? fraction : 0;
  const decimals = pct < 10 ? 1 : 0;

  const ariaLabel = scored
    ? `${band.label} cardiovascular risk. ${pct.toFixed(1)} percent ${assessment.horizon} estimated risk.`
    : `Cardiovascular risk cannot be calculated. ${band.label}.`;

  return (
    <div className="flex flex-col items-center" role="img" aria-label={ariaLabel}>
      <div className="relative" style={{ width: SIZE, height: SIZE }}>
        <svg
          width={SIZE}
          height={SIZE}
          viewBox={`0 0 ${SIZE} ${SIZE}`}
          // Rotate so the 270° arc opens at the bottom.
          style={{ transform: "rotate(135deg)" }}
          aria-hidden
        >
          {scored ? (
            <>
              <circle
                cx={SIZE / 2}
                cy={SIZE / 2}
                r={RADIUS}
                fill="none"
                stroke="var(--mec-gridline)"
                strokeWidth={STROKE}
                strokeLinecap="round"
                strokeDasharray={`${ARC_LENGTH} ${CIRCUMFERENCE}`}
              />
              {/* Band boundaries as ticks, so arc length reads against the
                  clinical bands rather than an arbitrary 0–100 scale. */}
              {[10, 20].map((boundary) => {
                const angle = (boundary / DISPLAY_MAX_PCT) * SWEEP_FRACTION * 360;
                return (
                  <line
                    key={boundary}
                    x1={SIZE / 2 + RADIUS - STROKE / 2}
                    y1={SIZE / 2}
                    x2={SIZE / 2 + RADIUS + STROKE / 2}
                    y2={SIZE / 2}
                    stroke="var(--mec-baseline)"
                    strokeWidth={2}
                    strokeLinecap="round"
                    transform={`rotate(${angle} ${SIZE / 2} ${SIZE / 2})`}
                  />
                );
              })}
              <circle
                cx={SIZE / 2}
                cy={SIZE / 2}
                r={RADIUS}
                fill="none"
                stroke={band.color}
                strokeWidth={STROKE}
                strokeLinecap="round"
                strokeDasharray={`${ARC_LENGTH * filled} ${CIRCUMFERENCE}`}
                style={{
                  transition: reduced
                    ? "none"
                    : "stroke-dasharray var(--mec-dur-value) var(--ease-value)",
                }}
              />
            </>
          ) : (
            /* Unscorable: dashed neutral track, no band colour, no value arc. */
            <circle
              cx={SIZE / 2}
              cy={SIZE / 2}
              r={RADIUS}
              fill="none"
              stroke="var(--mec-gridline)"
              strokeWidth={STROKE}
              strokeDasharray="6 10"
            />
          )}
        </svg>

        <div className="absolute inset-0 flex flex-col items-center justify-center px-10 text-center">
          {/* Channels 1 and 2: icon + word, together, always visible. */}
          <div className="flex items-center gap-2">
            <band.Icon size={18} style={{ color: band.color }} aria-hidden />
            <span
              className="text-[18px] font-semibold tracking-wide"
              style={{ color: "var(--mec-ink-primary)" }}
            >
              {band.label.toUpperCase()}
            </span>
          </div>

          {scored ? (
            <>
              <span
                className="mt-1 text-[64px] font-semibold leading-none"
                style={{ color: "var(--mec-ink-primary)" }}
              >
                <NumberTicker value={pct} decimals={decimals} />
              </span>
              {/* The number's meaning. Never a bare percentage — an unlabelled
                  "42%" reads as an acute probability. */}
              <span
                className="mt-2 text-[13px] font-medium"
                style={{ color: "var(--mec-ink-secondary)" }}
              >
                {assessment.horizon} estimated risk
              </span>
            </>
          ) : (
            <span
              className="mt-2 text-[15px] leading-relaxed"
              style={{ color: "var(--mec-ink-secondary)" }}
            >
              Add a lipid panel to enable risk scoring
            </span>
          )}
        </div>
      </div>

      {scored ? (
        <button
          type="button"
          onClick={onShowFactors}
          className="mt-4 inline-flex items-center gap-2 rounded-chip border px-4 py-3 text-[13px] font-medium"
          style={{
            borderColor: "var(--mec-hairline)",
            background: "var(--mec-card)",
            color: "var(--mec-ink-secondary)",
          }}
        >
          {assessment.factors.length} factors
        </button>
      ) : (
        <button
          type="button"
          onClick={onCompleteProfile}
          className="mt-4 inline-flex items-center gap-2 rounded-chip border px-4 py-3 text-[13px] font-medium"
          style={{
            borderColor: "var(--mec-hairline)",
            background: "var(--mec-card)",
            color: "var(--mec-ink-secondary)",
          }}
        >
          Complete your profile
          {assessment.missing_fields.length > 0 &&
            ` (${assessment.missing_fields.length} missing)`}
        </button>
      )}

      {/* Persistent, never a dismissible toast. */}
      <p className="mt-3 text-[12px]" style={{ color: "var(--mec-ink-muted)" }}>
        {assessment.disclaimer}
      </p>
    </div>
  );
}
