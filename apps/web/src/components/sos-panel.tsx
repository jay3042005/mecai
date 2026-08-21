"use client";

import * as React from "react";
import { createPortal } from "react-dom";
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
  Navigation,
  Copy,
  Check,
  X,
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

/** Great-circle distance in km. Straight-line, not road distance. */
function distanceKm(
  from: { lat: number; lon: number },
  to: { lat: number; lon: number },
): number {
  const R = 6371;
  const dLat = ((to.lat - from.lat) * Math.PI) / 180;
  const dLon = ((to.lon - from.lon) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((from.lat * Math.PI) / 180) *
      Math.cos((to.lat * Math.PI) / 180) *
      Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

/**
 * Map view for one incident, opened by clicking the patient.
 *
 * The embedded frame is scoped to the dialog rather than shown inline on every
 * card: a list of nine incidents each carrying a live map is nine third-party
 * frames loading on a console whose first job is to be readable.
 *
 * "My location" is requested on demand, never on mount. A responder's own
 * position is only relevant once they have opened an incident, and a browser
 * permission prompt fired on page load would be asking before there is a reason.
 */
function IncidentMapDialog({
  event,
  onResolve,
  onClose,
}: {
  event: SosEvent;
  onResolve: (eventId: number) => void;
  onClose: () => void;
}) {
  const [me, setMe] = React.useState<{ lat: number; lon: number } | null>(null);
  const [geoError, setGeoError] = React.useState<string | null>(null);
  const [locating, setLocating] = React.useState(false);
  const [copied, setCopied] = React.useState(false);
  const closeRef = React.useRef<HTMLButtonElement>(null);

  const patient = { lat: event.latitude!, lon: event.longitude! };

  // Frames both points when the responder's position is known, so "where they
  // are relative to me" is answered by the view itself and not only by a figure.
  const pad = 0.01;
  const lats = me ? [patient.lat, me.lat] : [patient.lat];
  const lons = me ? [patient.lon, me.lon] : [patient.lon];
  const bbox = [
    Math.min(...lons) - pad,
    Math.min(...lats) - pad,
    Math.max(...lons) + pad,
    Math.max(...lats) + pad,
  ].join(",");

  const locate = () => {
    if (!navigator.geolocation) {
      setGeoError("This browser cannot report a location.");
      return;
    }
    setLocating(true);
    setGeoError(null);
    navigator.geolocation.getCurrentPosition(
      (position) => {
        setMe({
          lat: position.coords.latitude,
          lon: position.coords.longitude,
        });
        setLocating(false);
      },
      (error) => {
        setGeoError(
          error.code === error.PERMISSION_DENIED
            ? "Location permission denied. The patient's position is still shown."
            : "Could not read your location. The patient's position is still shown.",
        );
        setLocating(false);
      },
      { enableHighAccuracy: true, timeout: 10_000 },
    );
  };

  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    // Focus moves into the dialog so a keyboard user is not left behind on the
    // card list, and Escape has something to close from.
    closeRef.current?.focus();
    // The page behind must not scroll under an open modal.
    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = prevOverflow;
    };
  }, [onClose]);

  const copyCoords = async () => {
    const text = `${patient.lat.toFixed(6)}, ${patient.lon.toFixed(6)}`;
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch {
      // Clipboard is permission-gated and absent over plain HTTP. The
      // coordinates are already on screen to read, so this is not worth an error.
    }
  };

  const isUnresolved = !event.resolved_at;
  const separation = me ? distanceKm(me, patient) : null;
  const accuracyIsCoarse = event.accuracy_m != null && event.accuracy_m > 100;

  // Rendered into <body>, not in place.
  //
  // The panel this dialog is declared inside carries `backdrop-blur`, and a
  // filter or backdrop-filter makes an element a containing block for its
  // `position: fixed` descendants. So `inset-0` was resolving against the
  // incident list rather than the viewport, which is why the modal landed down
  // the page instead of centred on screen.
  const portalTarget = typeof document === "undefined" ? null : document.body;
  if (portalTarget == null) return null;

  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-label={`Emergency location for ${event.display_name}`}
      className="fixed inset-0 z-[100] flex items-center justify-center p-4"
      style={{ backgroundColor: "rgba(0,0,0,0.62)", backdropFilter: "blur(4px)" }}
      onClick={onClose}
    >
      <div
        // A fixed height, not max-height: the map fills the leftover space with
        // flex-1, and that only has a value to claim if the shell's own height
        // is known rather than derived from its contents.
        className="flex h-[min(88vh,720px)] w-full max-w-3xl flex-col overflow-hidden rounded-[28px] shadow-2xl"
        style={{
          backgroundColor: "var(--mec-card)",
          border: `1px solid color-mix(in srgb, ${
            isUnresolved ? "var(--mec-risk-high)" : "var(--mec-ink-muted)"
          } 22%, transparent)`,
        }}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div
          className="flex shrink-0 items-start justify-between gap-3 px-5 py-4"
          style={{
            borderBottom: "1px solid color-mix(in srgb, var(--mec-ink-muted) 14%, transparent)",
            backgroundColor: isUnresolved
              ? "color-mix(in srgb, var(--mec-risk-high) 6%, transparent)"
              : "transparent",
          }}
        >
          <div className="flex min-w-0 items-start gap-3">
            <span
              className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full"
              style={{
                backgroundColor: `color-mix(in srgb, ${
                  isUnresolved ? "var(--mec-risk-high)" : "var(--mec-risk-low)"
                } 14%, transparent)`,
              }}
            >
              {isUnresolved ? (
                <Siren size={18} style={{ color: "var(--mec-risk-high)" }} />
              ) : (
                <CheckCircle2 size={18} style={{ color: "var(--mec-risk-low)" }} />
              )}
            </span>
            <div className="flex min-w-0 flex-col gap-1">
              <div className="flex flex-wrap items-center gap-2">
                <h3
                  className="truncate text-[19px] font-semibold"
                  style={{ color: "var(--mec-ink-primary)" }}
                >
                  {event.display_name}
                </h3>
                <span
                  className="rounded-full px-2 py-0.5 text-[11px] font-semibold uppercase tracking-wider"
                  style={{
                    backgroundColor: `color-mix(in srgb, ${
                      isUnresolved ? "var(--mec-risk-high)" : "var(--mec-risk-low)"
                    } 14%, transparent)`,
                    color: isUnresolved ? "var(--mec-risk-high)" : "var(--mec-risk-low)",
                  }}
                >
                  {isUnresolved ? "Active" : "Resolved"}
                </span>
                <span
                  className="rounded-full px-2 py-0.5 text-[11px] font-medium uppercase tracking-wider"
                  style={{
                    backgroundColor: "color-mix(in srgb, var(--mec-ink-muted) 14%, transparent)",
                    color: "var(--mec-ink-secondary)",
                  }}
                >
                  {event.source}
                </span>
              </div>
              <div
                className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[12px]"
                style={{ color: "var(--mec-ink-muted)" }}
              >
                <span className="inline-flex items-center gap-1.5">
                  <Clock size={12} aria-hidden />
                  Triggered {relativeTime(event.triggered_at)}
                </span>
                {event.resolved_at && (
                  <span>Resolved {relativeTime(event.resolved_at)}</span>
                )}
              </div>
            </div>
          </div>
          <button
            ref={closeRef}
            type="button"
            onClick={onClose}
            aria-label="Close map"
            className="shrink-0 rounded-full p-2 transition-colors hover:bg-[var(--mec-elevated)] active:scale-95 focus-visible:outline-2 focus-visible:outline-offset-2"
          >
            <X size={16} style={{ color: "var(--mec-ink-muted)" }} />
          </button>
        </div>

        {/* The map is the reason the dialog opened, so it sits directly under the
            header and takes every pixel left over. Details moved below it, where
            they can scroll without ever pushing the map out of view. */}
        <div className="relative min-h-[220px] flex-1">
          <iframe
            key={bbox}
            className="absolute inset-0 h-full w-full border-0"
            src={`https://www.openstreetmap.org/export/embed.html?bbox=${bbox}&layer=mapnik&marker=${patient.lat},${patient.lon}`}
            title={`Map of ${event.display_name}'s emergency location`}
          />
          <span
            className="pointer-events-none absolute left-3 top-3 rounded-full px-2.5 py-1 text-[11px] font-medium"
            style={{
              backgroundColor: "color-mix(in srgb, var(--mec-card) 88%, transparent)",
              color: "var(--mec-ink-secondary)",
              border: "1px solid color-mix(in srgb, var(--mec-ink-muted) 18%, transparent)",
            }}
          >
            {me ? "Patient + you" : "Patient location"}
          </span>
        </div>

        <div
          className="flex max-h-[34vh] shrink-0 flex-col gap-3 overflow-y-auto px-5 py-4"
          style={{
            borderTop: "1px solid color-mix(in srgb, var(--mec-ink-muted) 14%, transparent)",
          }}
        >
          {/* Vitals at the moment the alarm fired */}
          {(event.heart_rate_bpm != null ||
            event.spo2_pct != null ||
            event.temperature_c != null) && (
            <div className="flex flex-wrap items-center gap-2">
              <span
                className="text-[11px] font-semibold uppercase tracking-wider"
                style={{ color: "var(--mec-ink-muted)" }}
              >
                At trigger
              </span>
              {event.heart_rate_bpm != null && (
                <VitalTile icon={Heart} value={Math.round(event.heart_rate_bpm)} unit="bpm" />
              )}
              {event.spo2_pct != null && (
                <VitalTile icon={Droplets} value={Math.round(event.spo2_pct)} unit="%" />
              )}
              {event.temperature_c != null && (
                <VitalTile
                  icon={Thermometer}
                  value={event.temperature_c.toFixed(1)}
                  unit="°C"
                />
              )}
            </div>
          )}

          {/* Coordinates read as data, not prose: monospace figures, copyable,
              with the fix quality stated rather than left for the reader to infer. */}
          <div className="grid gap-2 sm:grid-cols-2">
            <div
              className="flex items-start justify-between gap-2 rounded-[16px] px-3.5 py-2.5"
              style={{ backgroundColor: "color-mix(in srgb, var(--mec-elevated) 50%, transparent)" }}
            >
              <div className="flex min-w-0 flex-col gap-0.5">
                <span className="text-[11px] uppercase tracking-wider" style={{ color: "var(--mec-ink-muted)" }}>
                  Coordinates
                </span>
                <span
                  className="truncate font-mono text-[13px] tabular-nums"
                  style={{ color: "var(--mec-ink-primary)" }}
                >
                  {patient.lat.toFixed(5)}, {patient.lon.toFixed(5)}
                </span>
              </div>
              <button
                type="button"
                onClick={copyCoords}
                aria-label="Copy coordinates"
                className="shrink-0 rounded-full p-1.5 transition-colors hover:bg-[var(--mec-elevated)] active:scale-95 focus-visible:outline-2 focus-visible:outline-offset-2"
              >
                {copied ? (
                  <Check size={14} style={{ color: "var(--mec-risk-low)" }} />
                ) : (
                  <Copy size={14} style={{ color: "var(--mec-ink-muted)" }} />
                )}
              </button>
            </div>

            <div
              className="flex flex-col gap-0.5 rounded-[16px] px-3.5 py-2.5"
              style={{ backgroundColor: "color-mix(in srgb, var(--mec-elevated) 50%, transparent)" }}
            >
              <span className="text-[11px] uppercase tracking-wider" style={{ color: "var(--mec-ink-muted)" }}>
                {separation != null ? "Distance from you" : "GPS accuracy"}
              </span>
              {separation != null ? (
                // Labelled straight-line, because a responder planning a route
                // will otherwise read it as travel distance and under-budget.
                <span className="text-[13px] tabular-nums" style={{ color: "var(--mec-ink-primary)" }}>
                  {separation < 1
                    ? `${Math.round(separation * 1000)} m`
                    : `${separation.toFixed(1)} km`}
                  <span style={{ color: "var(--mec-ink-muted)" }}> straight line</span>
                </span>
              ) : (
                <span
                  className="text-[13px] tabular-nums"
                  style={{
                    color: accuracyIsCoarse ? "var(--mec-risk-moderate)" : "var(--mec-ink-primary)",
                  }}
                >
                  {event.accuracy_m == null
                    ? "Not reported"
                    : `±${Math.round(event.accuracy_m)} m${accuracyIsCoarse ? " · coarse fix" : ""}`}
                </span>
              )}
            </div>
          </div>

          {event.note && (
            <p
              className="rounded-[16px] px-3.5 py-3 text-[13px] italic"
              style={{
                backgroundColor: "color-mix(in srgb, var(--mec-elevated) 40%, transparent)",
                color: "var(--mec-ink-secondary)",
              }}
            >
              &ldquo;{event.note}&rdquo;
            </p>
          )}

          {geoError && (
            <p className="text-[12px]" style={{ color: "var(--mec-risk-moderate)" }}>
              {geoError}
            </p>
          )}
        </div>

        {/* Actions pinned below the scroll area */}
        <div
          className="flex shrink-0 flex-wrap items-center gap-2 px-5 py-4"
          style={{
            borderTop: "1px solid color-mix(in srgb, var(--mec-ink-muted) 14%, transparent)",
          }}
        >
          <button
            type="button"
            onClick={locate}
            disabled={locating}
            className="inline-flex items-center gap-1.5 rounded-full px-4 py-2 text-[13px] font-medium transition-all active:scale-95 disabled:opacity-60 focus-visible:outline-2 focus-visible:outline-offset-2"
            style={{ border: "1px solid var(--mec-s1)", color: "var(--mec-s1)" }}
          >
            <Navigation size={14} aria-hidden />
            {locating ? "Locating…" : me ? "Update my location" : "Show my location"}
          </button>

          <a
            className="inline-flex items-center gap-1.5 rounded-full px-4 py-2 text-[13px] font-medium transition-all active:scale-95 focus-visible:outline-2 focus-visible:outline-offset-2"
            style={{
              border: "1px solid color-mix(in srgb, var(--mec-ink-muted) 30%, transparent)",
              color: "var(--mec-ink-primary)",
            }}
            href={
              me
                ? `https://www.openstreetmap.org/directions?engine=fossgis_osrm_car&route=${me.lat}%2C${me.lon}%3B${patient.lat}%2C${patient.lon}`
                : `https://www.openstreetmap.org/?mlat=${patient.lat}&mlon=${patient.lon}#map=17/${patient.lat}/${patient.lon}`
            }
            target="_blank"
            rel="noreferrer"
          >
            <MapPin size={14} aria-hidden />
            {me ? "Directions" : "Open full map"}
          </a>

          {isUnresolved && (
            <button
              type="button"
              onClick={() => {
                onResolve(event.id);
                onClose();
              }}
              className="ml-auto inline-flex items-center gap-1.5 rounded-full px-4 py-2 text-[13px] font-semibold transition-all active:scale-95 focus-visible:outline-2 focus-visible:outline-offset-2"
              style={{ backgroundColor: "var(--mec-risk-high)", color: "#fff" }}
            >
              <ShieldCheck size={14} aria-hidden />
              Mark Resolved
            </button>
          )}
        </div>
      </div>
    </div>,
    portalTarget,
  );
}

export default function SosPanel({ events, onResolve, loading }: SosPanelProps) {
  const reducedMotion = usePrefersReducedMotion();
  const [mapEventId, setMapEventId] = React.useState<number | null>(null);

  // Sort events newest first
  const sortedEvents = React.useMemo(() => {
    return [...events].sort((a, b) => {
      const timeA = new Date(a.triggered_at).getTime();
      const timeB = new Date(b.triggered_at).getTime();
      return timeB - timeA;
    });
  }, [events]);

  const unresolvedCount = sortedEvents.filter((e) => !e.resolved_at).length;
  const mapEvent = sortedEvents.find((e) => e.id === mapEventId) ?? null;
  const canMap = (event: SosEvent) => event.latitude != null && event.longitude != null;

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
            const mappable = canMap(event);

            return (
              <div
                key={event.id}
                // The whole card opens the map. Clicks that land on the Resolve
                // button stop there, so the primary action is never shadowed by
                // the card behind it.
                onClick={mappable ? () => setMapEventId(event.id) : undefined}
                className={`relative flex flex-col p-4 rounded-[24px] transition-all duration-300 hover:scale-[1.02] ${
                  mappable ? "cursor-pointer" : ""
                } ${isUnresolved && !reducedMotion ? "sos-glow" : ""}`}
                role={mappable ? "button" : undefined}
                tabIndex={mappable ? 0 : undefined}
                aria-label={
                  mappable ? `Show ${event.display_name}'s location on a map` : undefined
                }
                onKeyDown={
                  mappable
                    ? (e) => {
                        if (e.key === "Enter" || e.key === " ") {
                          e.preventDefault();
                          setMapEventId(event.id);
                        }
                      }
                    : undefined
                }
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
                      onClick={(e) => {
                        e.stopPropagation();
                        onResolve(event.id);
                      }}
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
                  <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
                    {event.latitude != null && event.longitude != null ? (
                      <>
                        <span className="flex items-center gap-1.5">
                          <MapPin size={14} style={{ color: "var(--mec-ink-muted)" }} />
                          <span className="text-[13px] tabular-nums" style={{ color: "var(--mec-ink-primary)" }}>
                            {event.latitude.toFixed(4)}, {event.longitude.toFixed(4)}
                            {event.accuracy_m != null && ` (±${Math.round(event.accuracy_m)}m)`}
                          </span>
                        </span>
                        <span className="text-[12px]" style={{ color: "var(--mec-ink-muted)" }}>
                          Click card for map
                        </span>
                      </>
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

      {mapEvent && (
        <IncidentMapDialog
          event={mapEvent}
          onResolve={onResolve}
          onClose={() => setMapEventId(null)}
        />
      )}
    </div>
  );
}
