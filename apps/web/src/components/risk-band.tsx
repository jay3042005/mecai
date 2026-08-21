/**
 * Risk band presentation, shared by the ring and the roster chip.
 *
 * The redundant-channel contract from docs/design.md §4 lives here so no
 * component can render a band without its word and icon:
 *
 *   1. word   — the band label
 *   2. icon   — a distinct silhouette per band
 *   3. colour — last, and never load-bearing alone
 *
 * The arc-length channel is the ring's job (see risk-ring.tsx).
 *
 * Why the redundancy: `validate_palette.js` measured low↔high at ΔE 4.1 under
 * deuteranopia. Roughly 8% of men cannot tell "Low" from "High" by colour.
 */

import {
  AlertTriangle,
  CircleHelp,
  OctagonAlert,
  ShieldCheck,
  type LucideIcon,
} from "lucide-react";

import type { RiskBandKey } from "@/lib/api";

export interface BandPresentation {
  label: string;
  Icon: LucideIcon;
  /** CSS custom property, so light/dark swap in one place. */
  color: string;
}

export const BANDS: Record<RiskBandKey, BandPresentation> = {
  low: { label: "Low", Icon: ShieldCheck, color: "var(--mec-risk-low)" },
  moderate: {
    label: "Moderate",
    Icon: AlertTriangle,
    color: "var(--mec-risk-moderate)",
  },
  high: { label: "High", Icon: OctagonAlert, color: "var(--mec-risk-high)" },
  unknown: {
    label: "Incomplete profile",
    Icon: CircleHelp,
    color: "var(--mec-risk-unknown)",
  },
};

/**
 * Compact band indicator for table rows.
 *
 * Note what this deliberately does NOT do: tint the whole row. A red row
 * background destroys text contrast and turns a table into an alarm. The chip
 * carries the state; the row stays readable.
 */
export function RiskChip({ band }: { band: RiskBandKey }) {
  const { label, Icon, color } = BANDS[band];

  return (
    <span
      className="inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-semibold tracking-wide transition-all duration-300 active:scale-95"
      style={{
        borderColor: `color-mix(in srgb, ${color} 30%, transparent)`,
        background: `color-mix(in srgb, ${color} 14%, var(--mec-card))`,
        color: "var(--mec-ink-primary)",
      }}
    >
      <Icon size={14} style={{ color }} aria-hidden />
      {label}
    </span>
  );
}
