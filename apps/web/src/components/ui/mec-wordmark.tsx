"use client";

/**
 * The MEC-AI wordmark, letter by letter — web twin of `MecWordmark` in
 * `apps/mobile/lib/widgets/mec_boot_fx.dart`.
 *
 * The watch firmware (`MEC-AI3/MEC-AI3.ino`) opens by popping the letters of
 * "MEC-AI" in one at a time, each in a different palette colour, before the word
 * settles to steady white with an electric glow. The Flutter app reproduces that
 * as its splash. This is the same gesture on the web, so all three surfaces —
 * device, app, dashboard — introduce the product identically.
 *
 * Two details carried over deliberately:
 *
 * * **Hidden letters render transparent, not absent.** The word occupies its final
 *   width from the first frame, so it does not grow and shift as letters arrive.
 * * **Palette, then settle.** Letters wear the data hue and green on the way in and
 *   transition to white once the sequence lands. The alarm red is not in this
 *   palette — see `MecBootPalette.calm` for the same reasoning on mobile.
 *
 * Under `prefers-reduced-motion` the word is simply *there*, already settled: no
 * pop, no stagger, no colour cycle.
 */

import { motion } from "motion/react";
import { useEffect, useState } from "react";

import { usePrefersReducedMotion } from "@/lib/use-reduced-motion";

/** Blue → light blue → green → white. No alarm red. */
const CALM_PALETTE = [
  "var(--mec-s1)",
  "var(--mec-s2)",
  "var(--mec-risk-low)",
  "var(--mec-ink-primary)",
] as const;

/** Matches the firmware's ~90ms per-letter cadence. */
const LETTER_DELAY_S = 0.09;

interface MecWordmarkProps {
  /** @default "MEC-AI" */
  text?: string;

  /** Additional class names for the wordmark element. */
  className?: string;

  /**
   * Skip the entrance and render the settled white word immediately.
   * @default false
   */
  settled?: boolean;
}

export function MecWordmark({
  text = "MEC-AI",
  className = "",
  settled = false,
}: MecWordmarkProps) {
  const reduced = usePrefersReducedMotion();
  const skipEntrance = reduced || settled;

  const [sequenceDone, setSequenceDone] = useState(false);

  // Derived, not set in an effect: when the entrance is skipped the word is
  // already settled, so there is no state to push. Same rule the risk ring's
  // NumberTicker follows for its final value.
  const hasSettled = skipEntrance || sequenceDone;

  useEffect(() => {
    if (skipEntrance) return;

    // Settle once every letter has landed, plus a beat to read the colour.
    const ms = (text.length * LETTER_DELAY_S + 0.55) * 1000;
    const timer = setTimeout(() => setSequenceDone(true), ms);
    return () => clearTimeout(timer);
  }, [skipEntrance, text.length]);

  return (
    // One accessible name for the whole word; the per-letter spans are decoration.
    <h1
      aria-label={text}
      className={`flex select-none font-bold tracking-[0.08em] ${className}`}
    >
      {text.split("").map((char, i) => {
        const hue = hasSettled
          ? "var(--mec-ink-primary)"
          : CALM_PALETTE[i % CALM_PALETTE.length];

        return (
          <motion.span
            key={`${char}-${i}`}
            aria-hidden
            initial={skipEntrance ? false : { scale: 0.3, opacity: 0 }}
            animate={{ scale: 1, opacity: 1 }}
            transition={
              skipEntrance
                ? { duration: 0 }
                : {
                    delay: i * LETTER_DELAY_S,
                    // A spring reproduces Flutter's elasticOut pop.
                    type: "spring",
                    stiffness: 620,
                    damping: 14,
                  }
            }
            style={{
              color: hue,
              textShadow: `0 0 18px color-mix(in srgb, ${hue} 60%, transparent)`,
              // The settle itself is a colour change, which is safe under reduced
              // motion — but there is nothing to transition from when we start
              // settled, so it costs nothing either.
              transition: "color 400ms var(--ease-standard), text-shadow 400ms var(--ease-standard)",
            }}
          >
            {char}
          </motion.span>
        );
      })}
    </h1>
  );
}
