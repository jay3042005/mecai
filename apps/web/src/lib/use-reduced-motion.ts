"use client";

/**
 * Reduced-motion preference, as a shared hook.
 *
 * Lifted out of `components/risk-ring.tsx`, which had it as a private function.
 * It is needed by anything that animates — the gradient background's breathing
 * loop, the wordmark's letter pop — and `prefers-reduced-motion` is a hard
 * requirement in this system rather than a nicety (docs/design.md §3.6), so it
 * should have exactly one implementation.
 */

import { useSyncExternalStore } from "react";

const REDUCED_MOTION_QUERY = "(prefers-reduced-motion: reduce)";

function subscribe(onChange: () => void) {
  const query = window.matchMedia(REDUCED_MOTION_QUERY);
  query.addEventListener("change", onChange);
  return () => query.removeEventListener("change", onChange);
}

/**
 * `useSyncExternalStore` rather than `useEffect` + `setState`: matchMedia is an
 * external system, and subscribing to it this way avoids the cascading render
 * that a synchronous setState in an effect body causes.
 */
export function usePrefersReducedMotion(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => window.matchMedia(REDUCED_MOTION_QUERY).matches,
    // Server snapshot: assume motion is allowed, then correct on hydration.
    () => false,
  );
}
