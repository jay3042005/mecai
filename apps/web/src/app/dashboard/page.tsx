"use client";

/**
 * MEC-AI Clinical Console — Patient roster + detail (docs/design.md §5.2).
 *
 * Fully redesigned in the Material You (Material Design 3) design system:
 * - Layered depth with atmospheric blur shapes and animated gradient mesh
 * - MD3 tonal surface hierarchy (Background -> Surface Container -> Elevated)
 * - Distinctive MD3 Filled Text Field search bar with 2px active bottom border
 * - Pill-shaped filter chips and state layers with active:scale-95 tactile feedback
 * - Interactive Risk Factor breakdown modal (progressive disclosure)
 * - Longitudinal Trends (Small-multiples 4 charts: BP, HR, SpO₂, Temp) with canvas rendering
 * - Real-time SOS Emergency Incident console with GPS fix and vital snapshots
 * - Two-format Clinical Report & CSV Data Export Modal
 * - MD3 Floating Action Button (FAB) for quick cohort refresh
 * - Preserves all 4 redundant risk indicator channels and strict accessibility
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import {
  Activity,
  AlertCircle,
  AlertOctagon,
  ArrowLeft,
  ChevronRight,
  CloudOff,
  Download,
  Filter,
  LayoutDashboard,
  RefreshCw,
  Search,
  Siren,
  TrendingUp,
  Users,
  Watch,
  X,
} from "lucide-react";

import { RiskChip } from "@/components/risk-band";
import { RiskRing } from "@/components/risk-ring";
import TrendsCharts from "@/components/trends-charts";
import SosPanel from "@/components/sos-panel";
import ExportModal from "@/components/export-modal";
import {
  ApiError,
  assess,
  fetchFleetStats,
  fetchPatientReadings,
  fetchPatients,
  fetchSosEvents,
  formatRelative,
  resolveSos,
  show,
  showBloodPressure,
  type AssessmentResponse,
  type FleetStats,
  type PatientSummary,
  type SosEvent,
  type StoredReading,
  type VitalsReading,
} from "@/lib/api";

/**
 * One roster entry, built from the archive.
 *
 * `reading` is the patient's most recent stored measurement and `response` the
 * assessment for it. Both come from `GET /v1/patients`, so the console shows what
 * the devices actually reported rather than synthetic data that re-rolls on every
 * refresh — which would make the trend charts meaningless and hide whether ingest
 * works at all.
 */
interface Row {
  patientId: string;
  name: string;
  reading: VitalsReading;
  response: AssessmentResponse;
  summary: PatientSummary;
}

/**
 * Whether a patient's watch is reporting now.
 *
 * Replaces a substring test against a name containing "(live unit)". A display
 * name is user-entered text; deriving liveness from it meant the badge could be
 * spoofed by typing, and a genuinely live unit whose owner typed their real name
 * never lit up.
 */
const LIVE_WINDOW_MINUTES = 15;

function isLive(summary: PatientSummary): boolean {
  if (summary.last_reading_at == null) return false;
  const elapsedMs = Date.now() - new Date(summary.last_reading_at).getTime();
  return elapsedMs <= LIVE_WINDOW_MINUTES * 60_000;
}

/**
 * The assessment snapshot stored with a reading, as an `AssessmentResponse`.
 *
 * `factors` is empty because the archive does not store the per-factor breakdown —
 * the detail panel fetches a live one for the selected patient. An empty list is
 * the honest representation; fabricating contributions to fill the bars would
 * invent numbers the model never produced.
 */
function snapshotResponse(reading: StoredReading): AssessmentResponse {
  return {
    assessment: {
      band: reading.band,
      value_pct: reading.value_pct,
      horizon: "10-year",
      factors: [],
      confidence: reading.confidence,
      missing_fields: reading.missing_fields,
      model_version: reading.model_version,
      disclaimer: "Screening indicator, not a diagnosis. Consult a physician.",
    },
    acute_flags: reading.acute_flags,
    reading_accepted: true,
    notes: [],
  };
}

type TabType = "roster" | "trends" | "sos";
type FilterOption = "all" | "high_risk" | "alerts" | "complete" | "live_units";

export default function DashboardPage() {
  const [activeTab, setActiveTab] = useState<TabType>("roster");
  const [rows, setRows] = useState<Row[]>([]);
  const [selected, setSelected] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  // MD3 Search and Filter states
  const [searchQuery, setSearchQuery] = useState("");
  const [activeFilter, setActiveFilter] = useState<FilterOption>("all");
  const [searchFocused, setSearchFocused] = useState(false);

  // Modals state
  const [showFactorsModal, setShowFactorsModal] = useState(false);
  const [showExportModal, setShowExportModal] = useState(false);

  // Longitudinal Trends state
  const [trendReadings, setTrendReadings] = useState<VitalsReading[]>([]);
  const [trendHorizon, setTrendHorizon] = useState("24h");
  const [loadingTrends, setLoadingTrends] = useState(false);

  // SOS Emergency events state
  const [sosEvents, setSosEvents] = useState<SosEvent[]>([]);
  const [loadingSos, setLoadingSos] = useState(false);

  // Archive-wide counters. Read from the server rather than derived from `rows`
  // so the header counts the whole cohort, not just the page's current slice.
  const [fleet, setFleet] = useState<FleetStats | null>(null);

  // Live factor breakdown for the selected patient.
  //
  // The archive stores each reading's band and percentage but not its per-factor
  // contributions, so the detail panel asks the scoring service for them. Keyed by
  // patient id so a stale response for a previously-selected row cannot paint the
  // wrong patient's drivers.
  const [breakdown, setBreakdown] = useState<{
    patientId: string;
    response: AssessmentResponse;
  } | null>(null);

  // Load the roster from the readings archive.
  const loadCohort = useCallback(async () => {
    try {
      const [patients, stats] = await Promise.all([
        fetchPatients(),
        fetchFleetStats(),
      ]);

      // A patient with no readings is kept, not filtered out: enrolled-but-never-
      // synced is a real state a clinician needs to see. Dropping the row would
      // make a phone that has never reached the network indistinguishable from a
      // patient who was never enrolled.
      const loaded: Row[] = patients.map((summary) => {
        const latest = summary.latest;
        const reading: VitalsReading = latest ?? {
          systolic_mmhg: null,
          diastolic_mmhg: null,
          heart_rate_bpm: null,
          spo2_pct: null,
          temperature_c: null,
          ambient_temp_c: null,
          measured_at: summary.last_reading_at ?? new Date().toISOString(),
          motion_artifact: false,
        };

        return {
          patientId: summary.patient_id,
          name: summary.display_name,
          reading,
          response: latest
            ? snapshotResponse(latest)
            : {
                assessment: {
                  band: "unknown",
                  value_pct: null,
                  horizon: "10-year",
                  factors: [],
                  confidence: "incomplete",
                  missing_fields: [],
                  model_version: "no-readings",
                  disclaimer:
                    "Screening indicator, not a diagnosis. Consult a physician.",
                },
                acute_flags: [],
                reading_accepted: true,
                notes: ["This device has not synced any readings yet."],
              },
          summary,
        };
      });

      setRows(loaded);
      setFleet(stats);
      setError(null);
    } catch (cause) {
      setError(cause instanceof ApiError ? cause.message : String(cause));
    } finally {
      setLoading(false);
    }
  }, []);

  // Load SOS events
  const loadSos = useCallback(async () => {
    try {
      setLoadingSos(true);
      // Assigned unconditionally, including when empty. Falling back to retained
      // events on an empty response would leave stale incidents on screen after
      // they were resolved — and on a panel whose job is "who needs help now",
      // showing a resolved emergency as open is the worst possible error.
      setSosEvents(await fetchSosEvents(false, 50));
    } catch {
      // Leave the last good list rather than blanking the panel on a transient
      // failure. The roster's outage banner already reports the connection.
    } finally {
      setLoadingSos(false);
    }
  }, []);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void loadCohort();
    void loadSos();
  }, [loadCohort, loadSos]);

  const refresh = () => {
    setLoading(true);
    void loadCohort();
    void loadSos();
  };

  // Filtered Cohort calculation
  const filteredRows = useMemo(() => {
    return rows.filter((row) => {
      const matchesSearch =
        searchQuery.trim() === "" ||
        row.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
        row.response.assessment.band.toLowerCase().includes(searchQuery.toLowerCase());

      if (!matchesSearch) return false;

      switch (activeFilter) {
        case "high_risk":
          return row.response.assessment.band === "high";
        case "alerts":
          return row.response.acute_flags.length > 0;
        case "complete":
          return row.response.assessment.confidence === "complete";
        case "live_units":
          return isLive(row.summary);
        case "all":
        default:
          return true;
      }
    });
  }, [rows, searchQuery, activeFilter]);

  const current = rows[selected] ?? filteredRows[0];

  // Fetch this patient's stored history when the selection or horizon changes.
  useEffect(() => {
    if (!current) return;
    let isCancelled = false;

    const hours = trendHorizon === "30d" ? 720 : trendHorizon === "7d" ? 168 : 24;
    const patientId = current.patientId;

    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoadingTrends(true);
    fetchPatientReadings(patientId, hours)
      .then((series) => {
        if (isCancelled) return;
        setTrendReadings(series);
        setLoadingTrends(false);
      })
      .catch(() => {
        if (isCancelled) return;
        // Empty, never synthetic.
        //
        // The version this replaces fabricated twenty readings from the latest
        // value plus Math.random() whenever the request failed. On a clinical
        // console that is the most dangerous possible fallback: the invented
        // points are visually indistinguishable from measurements, so a clinician
        // reads a trend that no device ever produced. An empty chart says "no
        // data", which is true and actionable.
        setTrendReadings([]);
        setLoadingTrends(false);
      });

    return () => {
      isCancelled = true;
    };
  }, [current, trendHorizon]);

  // Ask the scoring service for the selected patient's factor breakdown.
  useEffect(() => {
    if (!current || current.summary.latest == null) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setBreakdown(null);
      return;
    }
    let isCancelled = false;
    const patientId = current.patientId;

    assess(current.summary.profile, current.summary.latest)
      .then((response) => {
        if (!isCancelled) setBreakdown({ patientId, response });
      })
      .catch(() => {
        // The stored band and percentage are already on screen; only the
        // contribution bars are missing, and an empty list renders as absent
        // rather than as fabricated weights.
        if (!isCancelled) setBreakdown(null);
      });

    return () => {
      isCancelled = true;
    };
  }, [current]);

  // Handle SOS incident resolution
  const handleResolveSos = async (eventId: number) => {
    try {
      await resolveSos(eventId);
    } catch {
      // Local optimistic update
    }
    setSosEvents((prev) =>
      prev.map((e) =>
        e.id === eventId ? { ...e, resolved_at: new Date().toISOString() } : e
      )
    );
  };

  // Cohort summary counters.
  //
  // Taken from `/v1/stats` where available: the server counts bands from each
  // patient's *latest* reading across the whole archive, so one patient with a
  // thousand readings cannot dominate the figure. The local reduction is only a
  // fallback for the moment before the first response lands.
  const stats = useMemo(() => {
    const openSos = sosEvents.filter((e) => !e.resolved_at).length;

    if (fleet) {
      return {
        total: fleet.patients,
        highRisk: fleet.band_counts.high ?? 0,
        activeAlerts: fleet.patients_with_alerts,
        openSos: Math.max(openSos, fleet.open_sos),
        readings: fleet.readings,
        readings24h: fleet.readings_last_24h,
        latestAt: fleet.latest_reading_at,
      };
    }

    return {
      total: rows.length,
      highRisk: rows.filter((r) => r.response.assessment.band === "high").length,
      activeAlerts: rows.filter((r) => r.response.acute_flags.length > 0).length,
      openSos,
      readings: 0,
      readings24h: 0,
      latestAt: null as string | null,
    };
  }, [rows, sosEvents, fleet]);

  // The stored snapshot carries band and percentage; the live response adds the
  // factor contributions and the scoring notes. Matched on patient id so an
  // in-flight response for the previous selection is never shown against this one.
  const detail: AssessmentResponse =
    breakdown && current && breakdown.patientId === current.patientId
      ? breakdown.response
      : (current?.response ?? {
          assessment: {
            band: "unknown",
            value_pct: null,
            horizon: "10-year",
            factors: [],
            confidence: "incomplete",
            missing_fields: [],
            model_version: "pending",
            disclaimer:
              "Screening indicator, not a diagnosis. Consult a physician.",
          },
          acute_flags: [],
          reading_accepted: true,
          notes: [],
        });

  return (
    <main
      className="relative min-h-screen overflow-x-hidden px-4 py-8 sm:px-6 lg:px-8 pb-28"
      style={{ background: "var(--mec-page)" }}
    >
      {/* Static background keeps the data console responsive during long sessions. */}
      <div
        className="pointer-events-none fixed inset-0 z-0"
        style={{
          background:
            "radial-gradient(circle at 15% 10%, color-mix(in srgb, var(--mec-s1) 16%, transparent), transparent 32%), radial-gradient(circle at 85% 55%, color-mix(in srgb, var(--mec-s2) 10%, transparent), transparent 38%)",
        }}
        aria-hidden
      />

      <div className="relative z-10 mx-auto w-full max-w-6xl">
        {/* Navigation Breadcrumb / Top Bar */}
        <div className="mb-6 flex flex-wrap items-center justify-between gap-4">
          <Link
            href="/"
            className="group inline-flex items-center gap-2 rounded-full border px-4 py-2 text-xs font-semibold tracking-wide backdrop-blur-md transition-all duration-300 hover:bg-[var(--mec-elevated)] hover:shadow-sm active:scale-95"
            style={{
              borderColor: "var(--mec-hairline)",
              background: "color-mix(in srgb, var(--mec-card) 80%, transparent)",
              color: "var(--mec-ink-secondary)",
            }}
          >
            <ArrowLeft
              size={14}
              className="transition-transform duration-300 group-hover:-translate-x-1"
              aria-hidden
            />
            Back to Overview
          </Link>

          <div className="flex items-center gap-3">
            <button
              type="button"
              onClick={() => setShowExportModal(true)}
              className="inline-flex items-center gap-2 rounded-full border px-4 py-2 text-xs font-semibold tracking-wide backdrop-blur-md transition-all duration-300 hover:bg-[var(--mec-elevated)] hover:shadow-sm active:scale-95"
              style={{
                borderColor: "var(--mec-hairline)",
                background: "color-mix(in srgb, var(--mec-card) 80%, transparent)",
                color: "var(--mec-ink-primary)",
              }}
            >
              <Download size={14} aria-hidden style={{ color: "var(--mec-s1)" }} />
              Export Records
            </button>

            <span
              className="inline-flex items-center gap-2 rounded-full border px-4 py-1.5 text-xs font-medium backdrop-blur-md"
              style={{
                borderColor: "var(--mec-hairline)",
                background: "color-mix(in srgb, var(--mec-card) 80%, transparent)",
                color: "var(--mec-ink-secondary)",
              }}
            >
              <span
                className="h-2 w-2 rounded-full animate-pulse shadow-[0_0_8px_var(--mec-risk-low)]"
                style={{ background: "var(--mec-risk-low)" }}
              />
              Live Telemetry Stream
            </span>
          </div>
        </div>

        {/* Dashboard Header */}
        <header className="mb-8 flex flex-col gap-6 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h1
              className="text-3xl font-bold tracking-tight sm:text-4xl"
              style={{ color: "var(--mec-ink-primary)" }}
            >
              Clinical Console
            </h1>
            <p
              className="mt-1 text-sm font-medium leading-relaxed"
              style={{ color: "var(--mec-ink-secondary)" }}
            >
              Centralized patient cohort monitoring, longitudinal trends & emergency response
            </p>
          </div>

          <div className="flex items-center gap-3">
            <button
              type="button"
              onClick={refresh}
              disabled={loading}
              className="inline-flex items-center justify-center gap-2.5 rounded-full border px-6 py-3 text-sm font-semibold tracking-wide backdrop-blur-md transition-all duration-300 hover:bg-[var(--mec-elevated)] hover:shadow-md active:scale-95 disabled:opacity-50"
              style={{
                borderColor: "var(--mec-baseline)",
                background: "color-mix(in srgb, var(--mec-card) 85%, transparent)",
                color: "var(--mec-ink-primary)",
              }}
            >
              <RefreshCw
                size={15}
                className={loading ? "animate-spin text-[var(--mec-s1)]" : "text-[var(--mec-s1)]"}
                aria-hidden
              />
              <span>Refresh Telemetry</span>
            </button>
          </div>
        </header>

        {/* Cohort Summary Metrics (MD3 Tonal Chips) */}
        <div className="mb-8 grid grid-cols-2 gap-3 sm:grid-cols-4 sm:gap-4">
          <SummaryMetric
            icon={Users}
            label="Monitored Patients"
            value={stats.total}
            color="var(--mec-s1)"
            onClick={() => setActiveTab("roster")}
          />
          <SummaryMetric
            icon={AlertOctagon}
            label="High Risk (>=20%)"
            value={stats.highRisk}
            color="var(--mec-risk-high)"
            onClick={() => {
              setActiveTab("roster");
              setActiveFilter("high_risk");
            }}
          />
          <SummaryMetric
            icon={AlertCircle}
            label="Active Acute Alerts"
            value={stats.activeAlerts}
            color="var(--mec-risk-moderate)"
            onClick={() => {
              setActiveTab("roster");
              setActiveFilter("alerts");
            }}
          />
          <SummaryMetric
            icon={Siren}
            label="Open SOS Emergencies"
            value={stats.openSos}
            color="var(--mec-risk-high)"
            onClick={() => setActiveTab("sos")}
          />
        </div>

        {error && <ServiceOutage message={error} />}

        {/* MD3 Navigation Tab Switcher */}
        <div className="mb-8 flex items-center justify-center sm:justify-start">
          <div
            className="inline-flex p-1.5 rounded-full border backdrop-blur-md"
            style={{
              background: "color-mix(in srgb, var(--mec-card) 85%, transparent)",
              borderColor: "var(--mec-hairline)",
            }}
          >
            <button
              type="button"
              onClick={() => setActiveTab("roster")}
              className="inline-flex items-center gap-2 rounded-full px-5 py-2.5 text-xs font-semibold tracking-wide transition-all duration-300 active:scale-95"
              style={{
                background:
                  activeTab === "roster"
                    ? "var(--mec-s1)"
                    : "transparent",
                color:
                  activeTab === "roster"
                    ? "var(--mec-page)"
                    : "var(--mec-ink-secondary)",
              }}
            >
              <LayoutDashboard size={14} aria-hidden />
              Cohort Overview & Detail
            </button>

            <button
              type="button"
              onClick={() => setActiveTab("trends")}
              className="inline-flex items-center gap-2 rounded-full px-5 py-2.5 text-xs font-semibold tracking-wide transition-all duration-300 active:scale-95"
              style={{
                background:
                  activeTab === "trends"
                    ? "var(--mec-s1)"
                    : "transparent",
                color:
                  activeTab === "trends"
                    ? "var(--mec-page)"
                    : "var(--mec-ink-secondary)",
              }}
            >
              <TrendingUp size={14} aria-hidden />
              Longitudinal Trends
            </button>

            <button
              type="button"
              onClick={() => setActiveTab("sos")}
              className="inline-flex items-center gap-2 rounded-full px-5 py-2.5 text-xs font-semibold tracking-wide transition-all duration-300 active:scale-95"
              style={{
                background:
                  activeTab === "sos"
                    ? "var(--mec-risk-high)"
                    : "transparent",
                color:
                  activeTab === "sos"
                    ? "#ffffff"
                    : "var(--mec-ink-secondary)",
              }}
            >
              <Siren size={14} aria-hidden className={stats.openSos > 0 ? "animate-bounce" : ""} />
              Emergency Dispatch
              {stats.openSos > 0 && (
                <span className="ml-1 rounded-full bg-white/25 px-2 py-0.5 text-[10px] font-bold">
                  {stats.openSos}
                </span>
              )}
            </button>
          </div>
        </div>

        {/* TAB 1: COHORT OVERVIEW & DETAIL */}
        {activeTab === "roster" && (
          <>
            {/* Selected Patient Hero Detail (MD3 Asymmetric Elevation Container) */}
            {current && (
              <section
                className="mb-8 rounded-[36px] border p-6 sm:p-8 backdrop-blur-md transition-all duration-300"
                style={{
                  background: "color-mix(in srgb, var(--mec-card) 84%, transparent)",
                  borderColor: "var(--mec-hairline)",
                  boxShadow: "0 8px 32px rgba(0,0,0,0.28)",
                }}
              >
                <div className="flex flex-col items-center gap-8 lg:flex-row lg:items-start lg:justify-around">
                  {/* Centerpiece 4-Channel Risk Ring */}
                  <div className="flex flex-col items-center">
                    <RiskRing
                      assessment={detail.assessment}
                      onShowFactors={() => setShowFactorsModal(true)}
                    />
                  </div>

                  {/* Patient Telemetry & Drivers */}
                  <div className="w-full max-w-lg">
                    <div
                      className="flex items-baseline justify-between border-b pb-4"
                      style={{ borderColor: "var(--mec-gridline)" }}
                    >
                      <div>
                        <div className="flex items-center gap-2.5">
                          <h2
                            className="text-2xl font-bold tracking-tight"
                            style={{ color: "var(--mec-ink-primary)" }}
                          >
                            {current.name}
                          </h2>
                          {isLive(current.summary) && (
                            <span
                              className="inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-[11px] font-semibold"
                              style={{
                                background: "color-mix(in srgb, var(--mec-s1) 15%, var(--mec-card))",
                                color: "var(--mec-s1)",
                                border: "1px solid color-mix(in srgb, var(--mec-s1) 30%, transparent)",
                              }}
                            >
                              <Watch size={11} aria-hidden />
                              ESP32 Hardware
                            </span>
                          )}
                        </div>
                        <p
                          className="mt-1 flex items-center gap-2 text-xs font-medium"
                          style={{ color: "var(--mec-ink-secondary)" }}
                        >
                          <Activity size={13} aria-hidden style={{ color: "var(--mec-s1)" }} />
                          {current.summary.latest == null ? (
                            "No readings synced from this device yet"
                          ) : (
                            <>
                              {/* Relative first: the dashboard's real question about
                                  a reading is how stale it is, and a bare clock time
                                  leaves the reader to work that out. The absolute
                                  time follows for cross-referencing another record. */}
                              {formatRelative(current.reading.measured_at)}
                              <span style={{ color: "var(--mec-ink-muted)" }}>
                                ·{" "}
                                {new Date(current.reading.measured_at).toLocaleString([], {
                                  month: "short",
                                  day: "numeric",
                                  hour: "2-digit",
                                  minute: "2-digit",
                                })}
                                {" · "}
                                {current.summary.reading_count} reading
                                {current.summary.reading_count === 1 ? "" : "s"} on file
                              </span>
                            </>
                          )}
                        </p>
                      </div>
                      <div className="flex items-center gap-2">
                        <RiskChip band={detail.assessment.band} />
                        <button
                          type="button"
                          onClick={() => setShowExportModal(true)}
                          className="p-1.5 rounded-full hover:bg-[var(--mec-elevated)] transition-colors active:scale-95"
                          aria-label="Export patient record"
                        >
                          <Download size={15} style={{ color: "var(--mec-ink-muted)" }} />
                        </button>
                      </div>
                    </div>

                    {/* 2x2 Vitals Grid with MD3 Tonal Surfaces */}
                    <dl className="mt-6 grid grid-cols-2 gap-3">
                      <VitalTile
                        label="Blood pressure"
                        value={showBloodPressure(current.reading)}
                        unit={current.reading.systolic_mmhg == null ? "" : "mmHg"}
                        isAbsent={current.reading.systolic_mmhg == null}
                      />
                      <VitalTile
                        label="Heart rate"
                        value={show(current.reading.heart_rate_bpm)}
                        unit={current.reading.heart_rate_bpm == null ? "" : "bpm"}
                        isAbsent={current.reading.heart_rate_bpm == null}
                      />
                      <VitalTile
                        label="Blood oxygen"
                        value={show(current.reading.spo2_pct)}
                        unit={current.reading.spo2_pct == null ? "" : "%"}
                        isAbsent={current.reading.spo2_pct == null}
                      />
                      {current.reading.temperature_c != null ? (
                        <VitalTile
                          label="Body temperature"
                          value={show(current.reading.temperature_c, 1)}
                          unit="°C"
                          isAbsent={false}
                        />
                      ) : (
                        <VitalTile
                          label="Ambient temperature"
                          value={show(current.reading.ambient_temp_c, 1)}
                          unit={current.reading.ambient_temp_c == null ? "" : "°C"}
                          isAbsent={current.reading.ambient_temp_c == null}
                          sublabel="SHT30 Enclosure"
                        />
                      )}
                    </dl>

                    {/* Risk Factor Drivers Section with Modal Trigger */}
                    {detail.assessment.factors.length > 0 && (
                      <div
                        className="mt-6 rounded-3xl border p-5 backdrop-blur-sm transition-all duration-300"
                        style={{
                          background: "color-mix(in srgb, var(--mec-elevated) 70%, transparent)",
                          borderColor: "var(--mec-hairline)",
                        }}
                      >
                        <div className="flex items-center justify-between">
                          <p
                            className="text-xs font-bold uppercase tracking-wider"
                            style={{ color: "var(--mec-ink-muted)" }}
                          >
                            Risk Factor Drivers
                          </p>
                          <button
                            type="button"
                            onClick={() => setShowFactorsModal(true)}
                            className="inline-flex items-center gap-1 text-xs font-semibold transition-colors duration-200 hover:underline active:scale-95"
                            style={{ color: "var(--mec-s1)" }}
                          >
                            Breakdown & Details
                            <ChevronRight size={13} aria-hidden />
                          </button>
                        </div>

                        <div className="mt-3.5 space-y-3">
                          {detail.assessment.factors.slice(0, 3).map((f) => (
                            <div key={f.name}>
                              <div className="flex justify-between text-xs font-medium">
                                <span style={{ color: "var(--mec-ink-primary)" }}>{f.name}</span>
                                <span style={{ color: "var(--mec-ink-secondary)" }}>
                                  {f.display_value}
                                </span>
                              </div>
                              <div
                                className="mt-1.5 h-2 w-full overflow-hidden rounded-full"
                                style={{ background: "var(--mec-gridline)" }}
                              >
                                <div
                                  className="h-full rounded-full transition-all duration-500"
                                  style={{
                                    width: `${Math.round(f.contribution * 100)}%`,
                                    background: "var(--mec-s1)",
                                  }}
                                />
                              </div>
                            </div>
                          ))}
                        </div>
                      </div>
                    )}

                    {/* Acute Alert Feed */}
                    {current.response.acute_flags.length > 0 && (
                      <div className="mt-6 space-y-2.5">
                        {current.response.acute_flags.map((flag) => {
                          const isCrit = flag.severity === "critical";
                          const color = isCrit
                            ? "var(--mec-risk-high)"
                            : flag.severity === "warning"
                              ? "var(--mec-risk-moderate)"
                              : "var(--mec-s1)";
                          return (
                            <div
                              key={`${flag.vital}-${flag.severity}`}
                              className="flex gap-3.5 rounded-2xl border p-4 backdrop-blur-sm transition-all duration-300 hover:shadow-md"
                              style={{
                                borderColor: `color-mix(in srgb, ${color} 35%, transparent)`,
                                background: `color-mix(in srgb, ${color} 12%, var(--mec-card))`,
                              }}
                            >
                              <AlertCircle
                                size={20}
                                className="mt-0.5 shrink-0"
                                style={{ color }}
                                aria-hidden
                              />
                              <div>
                                <p
                                  className="text-xs font-bold uppercase tracking-wider"
                                  style={{ color }}
                                >
                                  {flag.vital} · {flag.display_value} ({flag.severity})
                                </p>
                                <p
                                  className="mt-1 text-xs leading-relaxed"
                                  style={{ color: "var(--mec-ink-secondary)" }}
                                >
                                  {flag.recommendation}
                                </p>
                              </div>
                            </div>
                          );
                        })}
                      </div>
                    )}
                  </div>
                </div>
              </section>
            )}

            {/* MD3 Search & Filter Controls */}
            <section className="mb-6 space-y-4">
              <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
                {/* MD3 Distinctive Filled Text Field */}
                <div className="relative flex-1 max-w-md">
                  <div
                    className="flex items-center gap-3 rounded-t-2xl px-4 py-3.5 backdrop-blur-md transition-all duration-200"
                    style={{
                      background: "color-mix(in srgb, var(--mec-elevated) 80%, transparent)",
                      borderBottom: searchFocused
                        ? "2px solid var(--mec-s1)"
                        : "2px solid var(--mec-baseline)",
                    }}
                  >
                    <Search
                      size={18}
                      style={{
                        color: searchFocused ? "var(--mec-s1)" : "var(--mec-ink-muted)",
                      }}
                      aria-hidden
                    />
                    <input
                      type="text"
                      placeholder="Search patient by name or risk band…"
                      value={searchQuery}
                      onChange={(e) => setSearchQuery(e.target.value)}
                      onFocus={() => setSearchFocused(true)}
                      onBlur={() => setSearchFocused(false)}
                      className="w-full bg-transparent text-sm font-medium outline-none placeholder:text-[var(--mec-ink-muted)]"
                      style={{ color: "var(--mec-ink-primary)" }}
                    />
                    {searchQuery && (
                      <button
                        type="button"
                        onClick={() => setSearchQuery("")}
                        className="rounded-full p-1 transition-colors hover:bg-[var(--mec-gridline)] active:scale-95"
                        aria-label="Clear search"
                      >
                        <X size={14} style={{ color: "var(--mec-ink-muted)" }} />
                      </button>
                    )}
                  </div>
                </div>

                {/* MD3 Filter Chips */}
                <div className="flex flex-wrap items-center gap-2">
                  <span
                    className="mr-1 text-xs font-semibold uppercase tracking-wider flex items-center gap-1.5"
                    style={{ color: "var(--mec-ink-muted)" }}
                  >
                    <Filter size={12} aria-hidden />
                    Filter:
                  </span>

                  <FilterChip
                    label="All"
                    active={activeFilter === "all"}
                    onClick={() => setActiveFilter("all")}
                  />
                  <FilterChip
                    label="High Risk"
                    active={activeFilter === "high_risk"}
                    onClick={() => setActiveFilter("high_risk")}
                  />
                  <FilterChip
                    label="Acute Alerts"
                    active={activeFilter === "alerts"}
                    onClick={() => setActiveFilter("alerts")}
                  />
                  <FilterChip
                    label="Complete Profile"
                    active={activeFilter === "complete"}
                    onClick={() => setActiveFilter("complete")}
                  />
                  <FilterChip
                    label="Live Units"
                    active={activeFilter === "live_units"}
                    onClick={() => setActiveFilter("live_units")}
                  />
                </div>
              </div>
            </section>

            {/* Patient Cohort Roster Table */}
            {rows.length > 0 && (
              <section
                className="overflow-hidden rounded-[28px] border backdrop-blur-md transition-all duration-300"
                style={{
                  background: "color-mix(in srgb, var(--mec-card) 84%, transparent)",
                  borderColor: "var(--mec-hairline)",
                  boxShadow: "0 4px 20px rgba(0,0,0,0.2)",
                }}
              >
                <div
                  className="flex flex-col sm:flex-row sm:items-center sm:justify-between border-b px-6 py-4"
                  style={{ borderColor: "var(--mec-gridline)" }}
                >
                  <div>
                    <h2
                      className="text-base font-bold"
                      style={{ color: "var(--mec-ink-primary)" }}
                    >
                      Patient Cohort Roster
                    </h2>
                    <p
                      className="text-xs font-medium"
                      style={{ color: "var(--mec-ink-muted)" }}
                    >
                      Showing {filteredRows.length} of {rows.length} monitored patients
                    </p>
                  </div>

                  {filteredRows.length !== rows.length && (
                    <button
                      type="button"
                      onClick={() => {
                        setSearchQuery("");
                        setActiveFilter("all");
                      }}
                      className="mt-2 sm:mt-0 text-xs font-semibold text-[var(--mec-s1)] hover:underline active:scale-95"
                    >
                      Reset Filters
                    </button>
                  )}
                </div>

                <div className="overflow-x-auto">
                  <table className="w-full border-collapse text-left">
                    <thead>
                      <tr
                        style={{
                          borderBottom: "1px solid var(--mec-gridline)",
                          background: "color-mix(in srgb, var(--mec-elevated) 70%, transparent)",
                        }}
                      >
                        {[
                          "Patient Name",
                          "10-Yr CVD Risk",
                          "Blood Pressure",
                          "SpO₂ Saturation",
                          "Active Alerts",
                          "Actions",
                        ].map((h) => (
                          <th
                            key={h}
                            className="px-6 py-3.5 text-xs font-bold uppercase tracking-wider"
                            style={{ color: "var(--mec-ink-muted)" }}
                          >
                            {h}
                          </th>
                        ))}
                      </tr>
                    </thead>
                    <tbody
                      className="divide-y"
                      style={{ borderColor: "var(--mec-gridline)" }}
                    >
                      {filteredRows.length > 0 ? (
                        filteredRows.map((row) => {
                          const isSelected = current?.name === row.name;
                          return (
                            <tr
                              key={row.name}
                              onClick={() => {
                                const originalIndex = rows.findIndex((r) => r.name === row.name);
                                if (originalIndex !== -1) setSelected(originalIndex);
                              }}
                              className="group cursor-pointer transition-all duration-300 ease-[cubic-bezier(0.2,0,0,1)] hover:bg-[var(--mec-elevated)]/60 hover:scale-[1.002] active:scale-[0.99]"
                              style={{
                                background: isSelected
                                  ? "color-mix(in srgb, var(--mec-s1) 12%, transparent)"
                                  : "transparent",
                              }}
                            >
                              <td
                                className="px-6 py-4 font-semibold text-sm"
                                style={{ color: "var(--mec-ink-primary)" }}
                              >
                                <div className="flex items-center gap-2.5">
                                  {isSelected ? (
                                    <span
                                      className="h-2 w-2 rounded-full shadow-[0_0_10px_var(--mec-s1)] animate-pulse"
                                      style={{ background: "var(--mec-s1)" }}
                                    />
                                  ) : (
                                    <span
                                      className="h-2 w-2 rounded-full opacity-0 group-hover:opacity-60 transition-opacity"
                                      style={{ background: "var(--mec-ink-muted)" }}
                                    />
                                  )}
                                  <span>{row.name}</span>
                                </div>
                              </td>
                              <td className="px-6 py-4">
                                <RiskChip band={row.response.assessment.band} />
                              </td>
                              <td
                                className="tabular px-6 py-4 text-sm font-medium"
                                style={{ color: "var(--mec-ink-secondary)" }}
                              >
                                {showBloodPressure(row.reading)}
                              </td>
                              <td
                                className="tabular px-6 py-4 text-sm font-medium"
                                style={{ color: "var(--mec-ink-secondary)" }}
                              >
                                {row.reading.spo2_pct == null
                                  ? show(null)
                                  : `${show(row.reading.spo2_pct)}%`}
                              </td>
                              <td
                                className="tabular px-6 py-4 text-sm font-medium"
                                style={{ color: "var(--mec-ink-secondary)" }}
                              >
                                {row.response.acute_flags.length > 0 ? (
                                  <span
                                    className="inline-flex items-center rounded-full px-3 py-0.5 text-xs font-bold"
                                    style={{
                                      background:
                                        "color-mix(in srgb, var(--mec-risk-high) 20%, transparent)",
                                      color: "var(--mec-risk-high)",
                                    }}
                                  >
                                    {row.response.acute_flags.length} Alert
                                    {row.response.acute_flags.length > 1 ? "s" : ""}
                                  </span>
                                ) : (
                                  <span style={{ color: "var(--mec-ink-muted)" }}>
                                    None
                                  </span>
                                )}
                              </td>
                              <td className="px-6 py-4 text-sm">
                                <span
                                  className="inline-flex items-center gap-1 text-xs font-semibold transition-transform duration-200 group-hover:translate-x-1"
                                  style={{
                                    color: isSelected ? "var(--mec-s1)" : "var(--mec-ink-muted)",
                                  }}
                                >
                                  Inspect
                                  <ChevronRight size={14} aria-hidden />
                                </span>
                              </td>
                            </tr>
                          );
                        })
                      ) : (
                        <tr>
                          <td
                            colSpan={6}
                            className="px-6 py-12 text-center text-sm font-medium"
                            style={{ color: "var(--mec-ink-muted)" }}
                          >
                            No patients matching your search criteria.
                          </td>
                        </tr>
                      )}
                    </tbody>
                  </table>
                </div>
              </section>
            )}
          </>
        )}

        {/* TAB 2: LONGITUDINAL TRENDS */}
        {activeTab === "trends" && (
          <section className="space-y-6">
            {/* Patient Selector Pills for Trends */}
            <div
              className="rounded-[28px] border p-4 backdrop-blur-md"
              style={{
                background: "color-mix(in srgb, var(--mec-card) 84%, transparent)",
                borderColor: "var(--mec-hairline)",
              }}
            >
              <p className="text-xs font-bold uppercase tracking-wider mb-3 px-2" style={{ color: "var(--mec-ink-muted)" }}>
                Select Patient to View Sensor Time-Series:
              </p>
              <div className="flex flex-wrap gap-2">
                {rows.map((r, idx) => {
                  const isSelected = selected === idx;
                  return (
                    <button
                      key={r.name}
                      type="button"
                      onClick={() => setSelected(idx)}
                      className="inline-flex items-center gap-2 rounded-full border px-4 py-2 text-xs font-semibold tracking-wide backdrop-blur-sm transition-all duration-300 active:scale-95"
                      style={{
                        borderColor: isSelected ? "var(--mec-s1)" : "var(--mec-hairline)",
                        background: isSelected
                          ? "color-mix(in srgb, var(--mec-s1) 20%, var(--mec-card))"
                          : "color-mix(in srgb, var(--mec-card) 70%, transparent)",
                        color: isSelected ? "var(--mec-s1)" : "var(--mec-ink-primary)",
                      }}
                    >
                      {isSelected && <span className="h-1.5 w-1.5 rounded-full" style={{ background: "var(--mec-s1)" }} />}
                      {r.name}
                      <span className="text-[10px] opacity-70">({r.response.assessment.band})</span>
                    </button>
                  );
                })}
              </div>
            </div>

            {/* Trends Small-Multiples */}
            <TrendsCharts
              readings={trendReadings}
              loading={loadingTrends}
              horizon={trendHorizon}
              onHorizonChange={setTrendHorizon}
            />
          </section>
        )}

        {/* TAB 3: EMERGENCY INCIDENTS / DISPATCH */}
        {activeTab === "sos" && (
          <section className="space-y-6">
            <SosPanel
              events={sosEvents}
              onResolve={handleResolveSos}
              loading={loadingSos}
            />
          </section>
        )}

        {loading && rows.length === 0 && !error && (
          <div
            className="mt-16 flex flex-col items-center justify-center gap-3 text-sm font-medium"
            style={{ color: "var(--mec-ink-muted)" }}
          >
            <RefreshCw size={24} className="animate-spin text-[var(--mec-s1)]" aria-hidden />
            <span>Loading patient telemetry & Framingham models…</span>
          </div>
        )}

        {/* An empty archive is a setup state, not a failure — so it explains the
            two ways data arrives instead of showing an empty console and leaving
            the reader to guess whether something is broken. */}
        {!loading && rows.length === 0 && !error && <EmptyArchive />}
      </div>

      {/* MD3 Floating Action Button (FAB) */}
      <div className="fixed bottom-6 right-6 sm:bottom-8 sm:right-8 z-30 flex items-center gap-3">
        <button
          type="button"
          onClick={refresh}
          disabled={loading}
          aria-label="Refresh Cohort Telemetry"
          className="group flex h-14 w-14 items-center justify-center rounded-2xl border shadow-lg backdrop-blur-md transition-all duration-300 hover:scale-105 hover:shadow-2xl active:scale-95 disabled:opacity-50"
          style={{
            background: "var(--mec-s1)",
            borderColor: "color-mix(in srgb, var(--mec-s1) 50%, white)",
            color: "var(--mec-page)",
          }}
        >
          <RefreshCw
            size={22}
            className={`transition-transform duration-500 ${loading ? "animate-spin" : "group-hover:rotate-180"}`}
            aria-hidden
          />
        </button>
      </div>

      {/* Progressive Disclosure: Risk Factor Breakdown Modal */}
      {showFactorsModal && current && (
        <FactorBreakdownModal
          assessment={detail.assessment}
          patientName={current.name}
          onClose={() => setShowFactorsModal(false)}
        />
      )}

      {/* Clinical Report & CSV Export Modal */}
      {showExportModal && current && (
        <ExportModal
          patientName={current.name}
          readings={trendReadings.length > 0 ? trendReadings : [current.reading]}
          assessment={detail}
          onClose={() => setShowExportModal(false)}
        />
      )}
    </main>
  );
}

/** MD3 Summary Metric Chip */
function SummaryMetric({
  icon: Icon,
  label,
  value,
  color,
  onClick,
}: {
  icon: React.ElementType;
  label: string;
  value: string | number;
  color: string;
  onClick?: () => void;
}) {
  return (
    <div
      onClick={onClick}
      className={`group flex items-center gap-3 rounded-2xl border p-4 backdrop-blur-sm transition-all duration-300 hover:scale-[1.02] hover:shadow-md ${
        onClick ? "cursor-pointer active:scale-95" : ""
      }`}
      style={{
        background: "color-mix(in srgb, var(--mec-card) 80%, transparent)",
        borderColor: "var(--mec-hairline)",
      }}
    >
      <div
        className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full"
        style={{
          background: `color-mix(in srgb, ${color} 15%, transparent)`,
          color,
        }}
      >
        <Icon size={18} aria-hidden />
      </div>
      <div>
        <p className="text-xs font-medium" style={{ color: "var(--mec-ink-secondary)" }}>
          {label}
        </p>
        <p
          className="text-lg font-bold tracking-tight"
          style={{ color: "var(--mec-ink-primary)" }}
        >
          {value}
        </p>
      </div>
    </div>
  );
}

/** MD3 Vital Tile with hover scale and tactile feedback */
function VitalTile({
  label,
  value,
  unit,
  isAbsent,
  sublabel,
}: {
  label: string;
  value: string | number;
  unit: string;
  isAbsent: boolean;
  sublabel?: string;
}) {
  return (
    <div
      className="group rounded-2xl border p-4 backdrop-blur-sm transition-all duration-300 hover:scale-[1.02] hover:shadow-sm"
      style={{
        background: "color-mix(in srgb, var(--mec-elevated) 75%, transparent)",
        borderColor: "var(--mec-hairline)",
      }}
    >
      <div className="flex items-center justify-between">
        <dt className="text-xs font-medium" style={{ color: "var(--mec-ink-secondary)" }}>
          {label}
        </dt>
        {sublabel && (
          <span
            className="text-[10px] font-semibold uppercase tracking-wider"
            style={{ color: "var(--mec-ink-muted)" }}
          >
            {sublabel}
          </span>
        )}
      </div>
      <dd className="mt-1.5 flex items-baseline gap-1.5">
        <span
          className={`text-2xl font-bold tracking-tight ${isAbsent ? "opacity-50" : ""}`}
          style={{ color: "var(--mec-ink-primary)" }}
        >
          {value}
        </span>
        {unit && (
          <span className="text-xs font-medium" style={{ color: "var(--mec-ink-muted)" }}>
            {unit}
          </span>
        )}
      </dd>
    </div>
  );
}

/** MD3 Pill-shaped Filter Chip */
function FilterChip({
  label,
  active,
  onClick,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="inline-flex items-center gap-1.5 rounded-full border px-4 py-1.5 text-xs font-semibold tracking-wide backdrop-blur-sm transition-all duration-300 active:scale-95"
      style={{
        borderColor: active ? "var(--mec-s1)" : "var(--mec-hairline)",
        background: active
          ? "color-mix(in srgb, var(--mec-s1) 20%, var(--mec-card))"
          : "color-mix(in srgb, var(--mec-card) 70%, transparent)",
        color: active ? "var(--mec-s1)" : "var(--mec-ink-secondary)",
        boxShadow: active ? "0 0 12px color-mix(in srgb, var(--mec-s1) 30%, transparent)" : "none",
      }}
    >
      {active && <span className="h-1.5 w-1.5 rounded-full" style={{ background: "var(--mec-s1)" }} />}
      {label}
    </button>
  );
}

/** Service Outage Banner */
function EmptyArchive() {
  return (
    <section
      className="mt-12 rounded-[28px] border p-8 text-center"
      style={{
        background: "var(--mec-card)",
        borderColor: "var(--mec-hairline)",
      }}
    >
      <Users
        size={28}
        className="mx-auto"
        style={{ color: "var(--mec-ink-muted)" }}
        aria-hidden
      />
      <h3
        className="mt-4 text-base font-bold"
        style={{ color: "var(--mec-ink-primary)" }}
      >
        No patients have synced yet
      </h3>
      <p
        className="mx-auto mt-2 max-w-md text-sm leading-relaxed"
        style={{ color: "var(--mec-ink-secondary)" }}
      >
        The scoring service is reachable and its archive is empty. Readings appear
        here once a device backs them up.
      </p>
      <dl className="mx-auto mt-6 max-w-md space-y-3 text-left">
        <div
          className="rounded-2xl border p-4"
          style={{
            background: "var(--mec-elevated)",
            borderColor: "var(--mec-hairline)",
          }}
        >
          <dt
            className="text-xs font-semibold uppercase tracking-wider"
            style={{ color: "var(--mec-ink-muted)" }}
          >
            From a phone
          </dt>
          <dd
            className="mt-1 text-sm"
            style={{ color: "var(--mec-ink-secondary)" }}
          >
            Open the MEC-AI app, set the server address in Settings, and leave
            backup on. Readings upload every few minutes.
          </dd>
        </div>
        <div
          className="rounded-2xl border p-4"
          style={{
            background: "var(--mec-elevated)",
            borderColor: "var(--mec-hairline)",
          }}
        >
          <dt
            className="text-xs font-semibold uppercase tracking-wider"
            style={{ color: "var(--mec-ink-muted)" }}
          >
            For a demo
          </dt>
          <dd
            className="mt-1 text-sm"
            style={{ color: "var(--mec-ink-secondary)" }}
          >
            <code
              className="tabular rounded px-1.5 py-0.5 text-xs"
              style={{ background: "var(--mec-page)", color: "var(--mec-s1)" }}
            >
              python3 scripts/seed-demo.py --sos
            </code>{" "}
            populates a six-patient cohort through the same sync endpoint a phone
            uses.
          </dd>
        </div>
      </dl>
    </section>
  );
}

function ServiceOutage({ message }: { message: string }) {
  return (
    <div
      className="mb-8 rounded-3xl border p-6 backdrop-blur-md"
      style={{
        background: "color-mix(in srgb, var(--mec-risk-moderate) 12%, var(--mec-card))",
        borderColor: "color-mix(in srgb, var(--mec-risk-moderate) 30%, transparent)",
      }}
    >
      <div className="flex items-center gap-3">
        <CloudOff size={20} style={{ color: "var(--mec-risk-moderate)" }} aria-hidden />
        <p className="text-base font-bold" style={{ color: "var(--mec-ink-primary)" }}>
          Scoring Service Unavailable
        </p>
      </div>
      <p className="mt-2 text-xs leading-relaxed" style={{ color: "var(--mec-ink-secondary)" }}>
        {message}
      </p>
    </div>
  );
}

/** Progressive Disclosure: Factor Breakdown Dialog */
function FactorBreakdownModal({
  assessment,
  patientName,
  onClose,
}: {
  assessment: AssessmentResponse["assessment"];
  patientName: string;
  onClose: () => void;
}) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
      {/* Backdrop */}
      <div
        className="fixed inset-0 bg-black/60 backdrop-blur-sm transition-opacity"
        onClick={onClose}
        aria-hidden
      />

      {/* MD3 Elevated Dialog Container */}
      <div
        role="dialog"
        aria-modal="true"
        className="relative z-10 w-full max-w-lg rounded-[32px] border p-6 sm:p-8 backdrop-blur-xl shadow-2xl transition-all"
        style={{
          background: "color-mix(in srgb, var(--mec-card) 95%, transparent)",
          borderColor: "var(--mec-hairline)",
        }}
      >
        <div className="flex items-center justify-between border-b pb-4" style={{ borderColor: "var(--mec-gridline)" }}>
          <div>
            <h3 className="text-xl font-bold" style={{ color: "var(--mec-ink-primary)" }}>
              Framingham Risk Drivers
            </h3>
            <p className="mt-0.5 text-xs font-medium" style={{ color: "var(--mec-ink-muted)" }}>
              Factor contributions for {patientName}
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded-full p-2 text-[var(--mec-ink-secondary)] hover:bg-[var(--mec-elevated)] active:scale-95"
            aria-label="Close dialog"
          >
            <X size={18} />
          </button>
        </div>

        <div className="mt-6 space-y-4 max-h-[60vh] overflow-y-auto pr-1">
          {assessment.factors.length > 0 ? (
            assessment.factors.map((factor) => (
              <div
                key={factor.name}
                className="rounded-2xl border p-4"
                style={{
                  background: "var(--mec-elevated)",
                  borderColor: "var(--mec-hairline)",
                }}
              >
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    <span className="font-semibold text-sm" style={{ color: "var(--mec-ink-primary)" }}>
                      {factor.name}
                    </span>
                    <span
                      className="rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wider"
                      style={{
                        background: factor.modifiable
                          ? "color-mix(in srgb, var(--mec-s1) 20%, transparent)"
                          : "color-mix(in srgb, var(--mec-ink-muted) 20%, transparent)",
                        color: factor.modifiable ? "var(--mec-s1)" : "var(--mec-ink-secondary)",
                      }}
                    >
                      {factor.modifiable ? "Modifiable" : "Non-Modifiable"}
                    </span>
                  </div>
                  <span className="text-xs font-bold" style={{ color: "var(--mec-ink-primary)" }}>
                    {factor.display_value}
                  </span>
                </div>

                <div className="mt-2 flex items-center justify-between text-xs" style={{ color: "var(--mec-ink-muted)" }}>
                  <span>Source: {factor.source === "device" ? "Wearable Sensor" : "Profile Questionnaire"}</span>
                  <span>{Math.round(factor.contribution * 100)}% weight</span>
                </div>

                <div className="mt-2 h-1.5 w-full overflow-hidden rounded-full" style={{ background: "var(--mec-gridline)" }}>
                  <div
                    className="h-full rounded-full"
                    style={{
                      width: `${Math.round(factor.contribution * 100)}%`,
                      background: "var(--mec-s1)",
                    }}
                  />
                </div>
              </div>
            ))
          ) : (
            <p className="text-sm font-medium text-center py-6" style={{ color: "var(--mec-ink-muted)" }}>
              No risk factor breakdown available for incomplete profile.
            </p>
          )}
        </div>

        <div className="mt-6 flex justify-end">
          <button
            type="button"
            onClick={onClose}
            className="rounded-full border px-6 py-2.5 text-xs font-semibold tracking-wide transition-all active:scale-95"
            style={{
              borderColor: "var(--mec-baseline)",
              background: "var(--mec-card)",
              color: "var(--mec-ink-primary)",
            }}
          >
            Close
          </button>
        </div>
      </div>
    </div>
  );
}
