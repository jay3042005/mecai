"use client";

/**
 * MEC-AI's assistant orb.
 *
 * A luminous, organically deforming field rather than a waveform or a spinner — the
 * Gemini Live interaction model, adapted to a **text** conversation. There is no
 * microphone here and no audio, so the two things a voice orb reads from amplitude
 * are read from the conversation instead:
 *
 * | Voice version | Chat version |
 * |---|---|
 * | your speaking volume | your typing cadence |
 * | the synthesised voice | the rate tokens are arriving |
 *
 * That substitution is what keeps the motion *meaningful* rather than decorative
 * (docs/design.md §2 principle 3): when the orb swells it is because something
 * measurable is happening — keys are being pressed, or text is landing. An idle orb
 * breathes slowly and nothing else.
 *
 * ### The six chat states
 *
 * | State | Meaning | Behaviour |
 * |---|---|---|
 * | `idle` | ready, nothing running | slow breathe, small core |
 * | `composing` | the reader is typing | perimeter lifts with each keystroke |
 * | `thinking` | request sent, nothing back yet | tight inward churn, ring sweeps |
 * | `responding` | tokens arriving | strong outward morphing, bright core |
 * | `interrupted` | Stop was pressed | collapses back to idle |
 * | `offline` | no route to a model | dim, still, flattened |
 *
 * ### How the shape is made
 *
 * Not `feTurbulence`: its `baseFrequency` cannot be animated smoothly across
 * browsers, and displacement maps blur the silhouette in ways that vary by engine.
 * Instead each blob's radius is a sum of three sine harmonics around θ,
 *
 *     r(θ) = base · (1 + Σ aᵢ · sin(kᵢθ + φᵢ + t·vᵢ))
 *
 * sampled at [SAMPLES] points and closed into a path. Three blobs run at different
 * speeds and phases, so their overlap is what reads as depth. `energy` scales the
 * amplitudes and the glow.
 *
 * `energy` is smoothed toward its target every frame rather than applied directly —
 * the raw signal from keystrokes is spiky, and an orb that flinches per character
 * looks broken rather than alive.
 *
 * ### Reduced motion
 *
 * The animation loop never starts. Each state renders one still frame, and the
 * states stay distinguishable by silhouette, core size and opacity alone — §3.6 is
 * a hard requirement, and a pulsing field is exactly the kind of movement it is
 * about.
 */

import { useCallback, useEffect, useId, useRef, useState } from "react";

import { usePrefersReducedMotion } from "@/lib/use-reduced-motion";

export type MecBotState =
  | "idle"
  | "composing"
  | "thinking"
  | "responding"
  | "interrupted"
  | "offline";

/** Points per blob outline. 48 is smooth at every size this renders at. */
const SAMPLES = 48;
const VIEW = 120;
const CENTRE = VIEW / 2;

/** Per-state tuning. `churn` negative pulls the deformation inward. */
const TUNING: Record<
  MecBotState,
  { base: number; amp: number; speed: number; churn: number; core: number; glow: number }
> = {
  idle: { base: 0.74, amp: 0.04, speed: 0.55, churn: 1, core: 0.12, glow: 0.55 },
  composing: { base: 0.78, amp: 0.07, speed: 0.9, churn: 1, core: 0.15, glow: 0.75 },
  thinking: { base: 0.7, amp: 0.055, speed: 1.5, churn: -1, core: 0.09, glow: 0.7 },
  responding: { base: 0.84, amp: 0.11, speed: 1.35, churn: 1, core: 0.2, glow: 1 },
  // Visibly *collapsed* relative to idle, not merely calmer — this is the only
  // confirmation the reader gets that Stop landed, so it has to be legible in the
  // second it is on screen.
  interrupted: { base: 0.56, amp: 0.02, speed: 0.5, churn: 1, core: 0.07, glow: 0.28 },
  // Still a body, just a grey one. The first tuning faded it almost to nothing,
  // which read as a rendering failure rather than as an unavailable assistant.
  offline: { base: 0.66, amp: 0.015, speed: 0, churn: 1, core: 0.07, glow: 0.2 },
};

/**
 * Three layers. Each has its own harmonics and rate, which is what stops the
 * silhouette from looking like one shape with a wobble.
 */
const LAYERS = [
  { ks: [2, 3, 5], phase: [0, 1.1, 2.3], rate: [0.7, -0.45, 0.3], scale: 1, opacity: 0.2 },
  { ks: [3, 4, 6], phase: [1.6, 0.4, 2.9], rate: [-0.5, 0.65, -0.25], scale: 0.86, opacity: 0.3 },
  { ks: [2, 5, 7], phase: [2.4, 1.9, 0.7], rate: [0.4, -0.3, 0.55], scale: 0.7, opacity: 0.42 },
] as const;

/** Closed blob path for one layer at time `t`. */
function blobPath(
  layer: (typeof LAYERS)[number],
  t: number,
  base: number,
  amp: number,
  churn: number,
): string {
  const radius = CENTRE * base * layer.scale;
  const points: string[] = [];

  for (let i = 0; i < SAMPLES; i++) {
    const theta = (i / SAMPLES) * Math.PI * 2;
    let deform = 0;
    for (let h = 0; h < 3; h++) {
      deform +=
        Math.sin(layer.ks[h] * theta + layer.phase[h] + t * layer.rate[h] * churn) /
        (h + 1);
    }
    const r = radius * (1 + amp * deform);
    const x = CENTRE + r * Math.cos(theta);
    const y = CENTRE + r * Math.sin(theta);
    points.push(`${x.toFixed(2)} ${y.toFixed(2)}`);
  }

  // Straight segments between 48 points read as a curve once blurred, and cost a
  // fraction of what per-point Béziers would recompute every frame.
  return `M${points.join("L")}Z`;
}

export function MecBot({
  state = "idle",
  energy = 0,
  size = 96,
  className = "",
}: {
  /** @default "idle" */
  state?: MecBotState;
  /**
   * Activity level, 0–1. Typing cadence while `composing`, token arrival rate while
   * `responding`. Ignored in the states that have no measurable activity.
   * @default 0
   */
  energy?: number;
  /** Rendered width in px. @default 96 */
  size?: number;
  className?: string;
}) {
  const reduced = usePrefersReducedMotion();
  const tune = TUNING[state];

  // Mirrored into a ref so the loop can read the latest value without `energy`
  // being a dependency — listing it there would tear down and restart the
  // animation on every keystroke, losing the phase each time.
  const targetEnergy = useRef(0);
  useEffect(() => {
    targetEnergy.current = Math.min(1, Math.max(0, energy));
  }, [energy]);

  const [frame, setFrame] = useState(() => ({ t: 0, e: 0 }));

  useEffect(() => {
    if (reduced || state === "offline") return;

    let raf = 0;
    let last = performance.now();
    let t = 0;
    let e = 0;

    const step = (now: number) => {
      const dt = Math.min(0.05, (now - last) / 1000); // clamped: tab-switch safety
      last = now;
      t += dt * tune.speed;
      // Exponential approach, ~180ms to close the gap. This is the interpolation
      // that turns spiky keystroke signal into something that looks alive.
      e += (targetEnergy.current - e) * Math.min(1, dt * 5.5);
      setFrame({ t, e });
      raf = requestAnimationFrame(step);
    };

    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, [reduced, state, tune.speed]);

  // Under reduced motion the still frame is taken at a fixed phase that shows the
  // silhouette off, rather than at t=0 where the harmonics cancel to a circle.
  const t = reduced ? 1.4 : frame.t;
  const e = reduced ? 0.5 : frame.e;

  const amp = tune.amp * (1 + e * 1.6);
  const base = tune.base * (1 + e * 0.08);
  const glow = tune.glow * (0.75 + e * 0.35);
  const dim = state === "offline";

  // Unique per instance: two orbs on one page must not share a filter id, or the
  // smaller one inherits the larger one's blur radius. `useId` rather than a random
  // string — a random id differs between the server and client renders, which is a
  // hydration mismatch. The colons it contains are stripped because `url(#…)` does
  // not reliably accept them.
  const uid = useId().replace(/:/g, "");

  return (
    <svg
      viewBox={`0 0 ${VIEW} ${VIEW}`}
      width={size}
      height={size}
      className={className}
      aria-hidden
      focusable="false"
    >
      <defs>
        <radialGradient id={`halo-${uid}`}>
          <stop offset="0%" stopColor="var(--mec-s2)" stopOpacity={0.5 * glow} />
          <stop offset="55%" stopColor="var(--mec-s1)" stopOpacity={0.22 * glow} />
          <stop offset="100%" stopColor="var(--mec-s1)" stopOpacity="0" />
        </radialGradient>
        <radialGradient id={`core-${uid}`}>
          <stop offset="0%" stopColor="var(--mec-ink-primary)" stopOpacity={0.95 * glow} />
          <stop offset="40%" stopColor="var(--mec-s2)" stopOpacity={0.85 * glow} />
          <stop offset="100%" stopColor="var(--mec-s1)" stopOpacity="0" />
        </radialGradient>
        {/* Softness is the whole look: without it three sine outlines read as
            contour lines rather than as one luminous body. */}
        <filter id={`soft-${uid}`} x="-40%" y="-40%" width="180%" height="180%">
          <feGaussianBlur stdDeviation={dim ? 1.6 : 2.6} />
        </filter>
      </defs>

      {/* Atmospheric halo, well outside the blobs so the edge never reads as hard. */}
      <circle cx={CENTRE} cy={CENTRE} r={CENTRE * 0.95} fill={`url(#halo-${uid})`} />

      {/* The body: three translucent layers, each deforming on its own clock. */}
      <g filter={`url(#soft-${uid})`}>
        {LAYERS.map((layer, i) => (
          <path
            key={i}
            d={blobPath(layer, t, base, amp, tune.churn)}
            fill={
              dim
                ? "var(--mec-ink-muted)"
                : i === 2
                  ? "var(--mec-s2)"
                  : "var(--mec-s1)"
            }
            fillOpacity={layer.opacity * (dim ? 0.75 : 0.8 + e * 0.3)}
          />
        ))}
      </g>

      {/* Thinking: one ring sweeping the perimeter. The orb itself churns inward
          while this travels, so "working" is legible before any text exists. */}
      {state === "thinking" && !reduced && (
        <circle
          cx={CENTRE}
          cy={CENTRE}
          r={CENTRE * (tune.base + 0.1)}
          fill="none"
          stroke="var(--mec-s2)"
          strokeOpacity="0.55"
          strokeWidth="1.5"
          strokeLinecap="round"
          pathLength="100"
          strokeDasharray="12 88"
          strokeDashoffset={100 - ((t * 34) % 100)}
        />
      )}

      {/* Core. Its size is the clearest single cue, and it survives greyscale. */}
      <circle
        cx={CENTRE}
        cy={CENTRE}
        r={CENTRE * tune.core * (1 + e * 0.5)}
        fill={`url(#core-${uid})`}
      />

      {/* The MEC signature: a heartbeat through the core while it speaks. This is a
          cardiovascular product, and the one flourish worth keeping from the older
          bot is the waveform its readers already know how to read. */}
      {state === "responding" && (
        <path
          d={`M${CENTRE - 26} ${CENTRE} L${CENTRE - 12} ${CENTRE} L${CENTRE - 8} ${CENTRE - 5} L${CENTRE - 4} ${CENTRE + 6} L${CENTRE} ${CENTRE - 13} L${CENTRE + 4} ${CENTRE + 8} L${CENTRE + 8} ${CENTRE - 3} L${CENTRE + 12} ${CENTRE} L${CENTRE + 26} ${CENTRE}`}
          fill="none"
          stroke="var(--mec-ink-primary)"
          strokeOpacity={0.72 + e * 0.28}
          strokeWidth="2.2"
          strokeLinecap="round"
          strokeLinejoin="round"
          pathLength="100"
          strokeDasharray={reduced ? undefined : "52 100"}
          strokeDashoffset={reduced ? undefined : 130 - ((t * 42) % 130)}
        />
      )}

      {/* Offline needs to survive both greyscale and a stopped animation, so it gets
          a shape nothing else has: a slash across the core. */}
      {dim && (
        <line
          x1={CENTRE - 16}
          y1={CENTRE + 16}
          x2={CENTRE + 16}
          y2={CENTRE - 16}
          stroke="var(--mec-ink-muted)"
          strokeWidth="2"
          strokeLinecap="round"
        />
      )}
    </svg>
  );
}

/**
 * Turns discrete events into a decaying 0–1 level for [MecBot]'s `energy`.
 *
 * Call `bump()` per keystroke or per arriving chunk. The level rises toward 1 as
 * events cluster and falls back once they stop, which is what makes the orb track
 * the *pace* of activity rather than merely whether it is happening.
 *
 * Decay runs on a timer rather than in the render loop so a component that is not
 * animating still settles to zero.
 */
export function useEnergy(): { energy: number; bump: () => void } {
  const [energy, setEnergy] = useState(0);
  const level = useRef(0);

  useEffect(() => {
    const id = setInterval(() => {
      if (level.current <= 0.001) return;
      level.current *= 0.82;
      if (level.current < 0.01) level.current = 0;
      setEnergy(level.current);
    }, 90);
    return () => clearInterval(id);
  }, []);

  const bump = useCallback(() => {
    // Saturating rather than additive: a fast typist should reach "busy", not
    // overshoot into a permanently maxed orb that no longer conveys pace.
    level.current = Math.min(1, level.current + 0.34);
    setEnergy(level.current);
  }, []);

  return { energy, bump };
}
