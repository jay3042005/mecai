"use client";

/**
 * AnimatedGradientBackground
 *
 * A customizable animated radial gradient background with a subtle breathing
 * effect. Uses `motion` for the entrance and raw CSS gradients for the loop.
 *
 * ### Three changes from the upstream snippet, all deliberate
 *
 * 1. **`"use client"`.** The component uses `useEffect`/`useRef`, so it cannot
 *    render in a server component. Upstream relied on the *importer* carrying the
 *    directive; declaring it here means the file is correct on its own.
 *
 * 2. **`motion/react`, not `framer-motion`.** This project already depends on
 *    `motion` v13 — the same library under its current name. Adding
 *    `framer-motion` would ship a second copy of it in the bundle.
 *
 * 3. **Stable effect dependencies.** `gradientColors` and `gradientStops` are
 *    arrays; with default parameters a fresh identity is created on every render,
 *    so the original dependency list tore down and restarted the animation frame
 *    each time. They are joined to strings for comparison instead.
 *
 * And one addition: the breathing loop and the entrance both stop under
 * `prefers-reduced-motion`, which this system treats as a hard requirement
 * (docs/design.md §3.6) rather than an enhancement.
 *
 * Colour stops accept CSS custom properties — `var(--mec-s1)` is a valid gradient
 * colour — which is how callers stay on the generated palette instead of pasting
 * hexes. See `MEC_GRADIENT` below.
 */

import { motion } from "motion/react";
import React, { useEffect, useMemo, useRef } from "react";

import { usePrefersReducedMotion } from "@/lib/use-reduced-motion";

interface AnimatedGradientBackgroundProps {
  /**
   * Initial size of the radial gradient, defining the starting width.
   * @default 125
   */
  startingGap?: number;

  /**
   * Enables or disables the breathing animation effect.
   * @default false
   */
  Breathing?: boolean;

  /**
   * Array of colors to use in the radial gradient.
   * Each color corresponds to a stop percentage in `gradientStops`.
   */
  gradientColors?: string[];

  /**
   * Array of percentage stops corresponding to each color in `gradientColors`.
   * The values should range between 0 and 100.
   * @default [35, 50, 60, 70, 80, 90, 100]
   */
  gradientStops?: number[];

  /**
   * Speed of the breathing animation.
   * Lower values result in slower animation.
   * @default 0.02
   */
  animationSpeed?: number;

  /**
   * Maximum range for the breathing animation in percentage points.
   * Determines how much the gradient "breathes" by expanding and contracting.
   * @default 5
   */
  breathingRange?: number;

  /** Additional inline styles for the gradient container. */
  containerStyle?: React.CSSProperties;

  /** Additional class names for the gradient container. */
  containerClassName?: string;

  /**
   * Additional top offset for the gradient container from the top, for more
   * flexible control over the gradient.
   * @default 0
   */
  topOffset?: number;
}

/**
 * The MEC-AI palette, as gradient stops.
 *
 * Blue → light blue → green → white over the page surface, read straight from the
 * generated custom properties so this cannot drift from `packages/tokens`.
 *
 * **The alarm red is deliberately absent.** It is reserved for an actual alarm,
 * and a large sustained red wash behind a landing page on a cardiovascular product
 * would read as a warning that is not happening. Mobile draws the same distinction
 * — `MecBootPalette.calm` versus `.brand` in
 * `apps/mobile/lib/widgets/mec_boot_fx.dart`.
 */
export const MEC_GRADIENT = {
  colors: [
    "var(--mec-page)",
    "var(--mec-s1)",
    "var(--mec-s2)",
    "var(--mec-risk-low)",
    "var(--mec-ink-primary)",
  ],
  stops: [35, 55, 70, 85, 100],
} as const;

const AnimatedGradientBackground: React.FC<AnimatedGradientBackgroundProps> = ({
  startingGap = 125,
  Breathing = false,
  gradientColors = [
    "#0A0A0A",
    "#2979FF",
    "#FF80AB",
    "#FF6D00",
    "#FFD600",
    "#00E676",
    "#3D5AFE",
  ],
  gradientStops = [35, 50, 60, 70, 80, 90, 100],
  animationSpeed = 0.02,
  breathingRange = 5,
  containerStyle = {},
  topOffset = 0,
  containerClassName = "",
}) => {
  // Validation: ensure gradientStops and gradientColors lengths match.
  if (gradientColors.length !== gradientStops.length) {
    throw new Error(
      `GradientColors and GradientStops must have the same length.
     Received gradientColors length: ${gradientColors.length},
     gradientStops length: ${gradientStops.length}`,
    );
  }

  const containerRef = useRef<HTMLDivElement | null>(null);
  const reduced = usePrefersReducedMotion();

  // Arrays are compared by content, not identity — default parameters would
  // otherwise produce a new array every render and restart the loop.
  const colorsKey = gradientColors.join("|");
  const stopsKey = gradientStops.join("|");

  const stopsString = useMemo(
    () =>
      gradientStops.map((stop, i) => `${gradientColors[i]} ${stop}%`).join(", "),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [colorsKey, stopsKey],
  );

  useEffect(() => {
    // Reduced motion: paint the gradient once at its resting size and stop. No
    // rAF loop is scheduled at all, so there is nothing to breathe.
    if (reduced || !Breathing) {
      if (containerRef.current) {
        containerRef.current.style.background =
          `radial-gradient(${startingGap}% ${startingGap + topOffset}% at 50% 20%, ${stopsString})`;
      }
      return;
    }

    let animationFrame: number;
    let width = startingGap;
    let directionWidth = 1;

    const animateGradient = () => {
      if (width >= startingGap + breathingRange) directionWidth = -1;
      if (width <= startingGap - breathingRange) directionWidth = 1;

      width += directionWidth * animationSpeed;

      if (containerRef.current) {
        containerRef.current.style.background =
          `radial-gradient(${width}% ${width + topOffset}% at 50% 20%, ${stopsString})`;
      }

      animationFrame = requestAnimationFrame(animateGradient);
    };

    animationFrame = requestAnimationFrame(animateGradient);
    return () => cancelAnimationFrame(animationFrame);
  }, [
    startingGap,
    Breathing,
    stopsString,
    animationSpeed,
    breathingRange,
    topOffset,
    reduced,
  ]);

  return (
    <motion.div
      key="animated-gradient-background"
      initial={reduced ? false : { opacity: 0, scale: 1.5 }}
      animate={{
        opacity: 1,
        scale: 1,
        transition: {
          duration: reduced ? 0 : 2,
          ease: [0.25, 0.1, 0.25, 1], // Cubic bezier easing
        },
      }}
      className={`absolute inset-0 overflow-hidden ${containerClassName}`}
      // Decoration. Nothing here carries meaning a screen reader needs.
      aria-hidden
    >
      <div
        ref={containerRef}
        style={containerStyle}
        className="absolute inset-0 transition-transform"
      />
    </motion.div>
  );
};

export default AnimatedGradientBackground;
