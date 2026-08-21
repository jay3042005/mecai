"use client";

import * as React from "react";
import type { SosEvent } from "@/lib/api";
import { usePrefersReducedMotion } from "@/lib/use-reduced-motion";
import {
  Siren,
  MapPin,
  MapPinOff,
  ShieldCheck,
  Clock,
  Heart,
  Droplets,
  Thermometer,
  CheckCircle2,
} from "lucide-react";

interface SosPanelProps {
  events: SosEvent[];
  onResolve: (eventId: number) => void;
  loading?: boolean;
}



function relativeTime(iso: string): string {
  const date = new Date(iso);
  const now = new Date();
  const diff = Math.floor((now.getTime() - date.getTime()) / 1000);

  if (diff < 60) return "Just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  if (diff < 604800) return `${Math.floor(diff / 86400)}d ago`;

  return date.toLocaleDateString();
}

function VitalTile({
  icon: Icon,
  value,
  unit,
}: {
  icon: React.ElementType;
  value: string | number;
  unit: string;
}) {
  return (
    <div
      className="flex items-center gap-1.5 px-2.5 py-1.5 rounded-[12px]"
      style={{ backgroundColor: "color-mix(in srgb, var(--mec-elevated) 50%, transparent)" }}
    >
      <Icon size={14} style={{ color: "var(--mec-ink-muted)" }} />
      <div className="flex items-baseline gap-0.5">
        <span className="font-semibold tabular-nums text-[13px]" style={{ color: "var(--mec-ink-primary)" }}>
          {value}
        </span>
        <span className="text-[10px]" style={{ color: "var(--mec-ink-muted)" }}>
          {unit}
        </span>
      </div>
    </div>
  );
}

export default function SosPanel({ events, onResolve, loading }: SosPanelProps) {
  const reducedMotion = usePrefersReducedMotion();

  // Sort events newest first
  const sortedEvents = React.useMemo(() => {
    return [...events].sort((a, b) => {
      const timeA = new Date(a.triggered_at).getTime();
      const timeB = new Date(b.triggered_at).getTime();
      return timeB - timeA;
    });
  }, [events]);

  const unresolvedCount = sortedEvents.filter((e) => !e.resolved_at).length;

  return (
    <div
      className="flex flex-col rounded-[28px] backdrop-blur-md overflow-hidden"
      style={{
        backgroundColor: "color-mix(in srgb, var(--mec-card) 90%, transparent)",
        border: "1px solid color-mix(in srgb, var(--mec-ink-muted) 15%, transparent)",
      }}
    >
      {/* Header */}
      <div className="flex items-center justify-between p-5 border-b border-[color-mix(in_srgb,var(--mec-ink-muted)_10%,transparent)]">
        <div className="flex items-center gap-2">
          <Siren
            size={20}
            style={{ color: unresolvedCount > 0 ? "var(--mec-risk-high)" : "var(--mec-ink-muted)" }}
          />
          <h2 className="text-[18px] font-semibold" style={{ color: "var(--mec-ink-primary)" }}>
            Emergency Incidents
          </h2>
        </div>
        {unresolvedCount > 0 && (
          <div
            className="px-2.5 py-0.5 rounded-full text-[13px] font-medium flex items-center justify-center"
            style={{
              backgroundColor: "color-mix(in srgb, var(--mec-risk-high) 15%, transparent)",
              color: "var(--mec-risk-high)",
            }}
          >
            {unresolvedCount} Active
          </div>
        )}
      </div>

      {/* Body */}
      <div className="p-4 flex flex-col gap-4">
        <style>{`
          @keyframes mec-sos-glow {
            0%, 100% { box-shadow: 0 0 0 0px color-mix(in srgb, var(--mec-risk-high) 40%, transparent); }
            50% { box-shadow: 0 0 0 4px color-mix(in srgb, var(--mec-risk-high) 0%, transparent); }
          }
          .sos-glow {
            animation: mec-sos-glow 2s cubic-bezier(0.2, 0, 0, 1) infinite;
          }
          @media (prefers-reduced-motion: reduce) {
            .sos-glow {
              animation: none !important;
            }
          }
        `}</style>

        {loading ? (
          <div className="p-8 text-center text-[15px]" style={{ color: "var(--mec-ink-muted)" }}>
            Loading incidents...
          </div>
        ) : sortedEvents.length === 0 ? (
          <div className="flex flex-col items-center justify-center p-10 gap-3 text-center">
            <div
              className="w-12 h-12 rounded-full flex items-center justify-center"
              style={{ backgroundColor: "color-mix(in srgb, var(--mec-risk-low) 10%, transparent)" }}
            >
              <ShieldCheck size={24} style={{ color: "var(--mec-risk-low)" }} />
            </div>
            <p className="text-[15px] font-medium" style={{ color: "var(--mec-ink-primary)" }}>
              No active emergencies
            </p>
            <p className="text-[13px]" style={{ color: "var(--mec-ink-muted)" }}>
              All patients are currently stable.
            </p>
          </div>
        ) : (
          sortedEvents.map((event) => {
            const isUnresolved = !event.resolved_at;
            
            return (
              <div
                key={event.id}
                className={`relative flex flex-col p-4 rounded-[24px] transition-all duration-300 hover:scale-[1.02] ${
                  isUnresolved && !reducedMotion ? "sos-glow" : ""
                }`}
                style={{
                  backgroundColor: isUnresolved
                    ? "color-mix(in srgb, var(--mec-risk-high) 4%, var(--mec-card))"
                    : "var(--mec-card)",
                  border: `1px solid color-mix(in srgb, ${
                    isUnresolved ? "var(--mec-risk-high)" : "var(--mec-ink-muted)"
                  } 15%, transparent)`,
                  borderLeft: isUnresolved ? "3px solid var(--mec-risk-high)" : undefined,
                  opacity: isUnresolved ? 1 : 0.7,
                }}
              >
                {/* Card Header */}
                <div className="flex items-start justify-between mb-3">
                  <div className="flex flex-col gap-1">
                    <div className="flex items-center gap-2">
                      {isUnresolved ? (
                        <Siren size={16} style={{ color: "var(--mec-risk-high)" }} />
                      ) : (
                        <CheckCircle2 size={16} style={{ color: "var(--mec-risk-low)" }} />
                      )}
                      <span className="text-[15px] font-semibold" style={{ color: "var(--mec-ink-primary)" }}>
                        {event.display_name}
                      </span>
                      <span
                        className="px-2 py-0.5 rounded-full text-[11px] font-medium uppercase tracking-wider"
                        style={{
                          backgroundColor: "color-mix(in srgb, var(--mec-ink-muted) 15%, transparent)",
                          color: "var(--mec-ink-primary)",
                        }}
                      >
                        {event.source}
                      </span>
                    </div>
                    <div className="flex items-center gap-1.5 text-[12px]" style={{ color: "var(--mec-ink-muted)" }}>
                      <Clock size={12} />
                      {relativeTime(event.triggered_at)}
                      {!isUnresolved && event.resolved_at && ` (Resolved ${relativeTime(event.resolved_at)})`}
                    </div>
                  </div>
                  
                  {isUnresolved && (
                    <button
                      onClick={() => onResolve(event.id)}
                      className="px-4 py-1.5 rounded-full text-[13px] font-medium transition-all duration-300 active:scale-95 cursor-pointer"
                      style={{
                        backgroundColor: "transparent",
                        border: "1px solid var(--mec-risk-high)",
                        color: "var(--mec-risk-high)",
                      }}
                    >
                      Mark Resolved
                    </button>
                  )}
                </div>

                {/* Vitals Snapshot */}
                {(event.heart_rate_bpm != null || event.spo2_pct != null || event.temperature_c != null) && (
                  <div className="flex flex-wrap gap-2 mb-3">
                    {event.heart_rate_bpm != null && <VitalTile icon={Heart} value={Math.round(event.heart_rate_bpm)} unit="bpm" />}
                    {event.spo2_pct != null && <VitalTile icon={Droplets} value={Math.round(event.spo2_pct)} unit="%" />}
                    {event.temperature_c != null && <VitalTile icon={Thermometer} value={event.temperature_c.toFixed(1)} unit="°C" />}
                  </div>
                )}

                {/* Location & Notes */}
                  <div className="flex flex-col gap-2">
                  <div className="flex items-center gap-1.5">
                    {event.latitude != null && event.longitude != null ? (
                      <a
                        className="flex items-center gap-1.5 rounded-md focus-visible:outline-2 focus-visible:outline-offset-2"
                        href={`https://www.openstreetmap.org/?mlat=${event.latitude}&mlon=${event.longitude}#map=17/${event.latitude}/${event.longitude}`}
                        target="_blank"
                        rel="noreferrer"
                        aria-label={`Open ${event.display_name}'s emergency location in OpenStreetMap`}
                      >
                        <MapPin size={14} style={{ color: "var(--mec-ink-muted)" }} />
                        <span className="text-[13px] tabular-nums" style={{ color: "var(--mec-ink-primary)" }}>
                          {event.latitude.toFixed(4)}, {event.longitude.toFixed(4)}
                          {event.accuracy_m != null && ` (±${Math.round(event.accuracy_m)}m)`}
                        </span>
                      </a>
                    ) : (
                      <>
                        <MapPinOff size={14} style={{ color: "var(--mec-ink-muted)" }} />
                        <span className="text-[13px]" style={{ color: "var(--mec-ink-muted)" }}>
                          Location unavailable
                        </span>
                      </>
                    )}
                  </div>
                  {event.note && (
                    <p className="text-[13px] italic" style={{ color: "var(--mec-ink-muted)" }}>
                      &ldquo;{event.note}&rdquo;
                    </p>
                  )}
                </div>
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}
