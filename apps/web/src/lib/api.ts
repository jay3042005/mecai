/**
 * Client for services/api.
 *
 * Types mirror `services/api/src/mecai_api/models.py`. The scoring model is not
 * reimplemented here for the same reason it isn't in the Flutter app: a second
 * copy of a clinical calculation drifts, and there is then no way to know which
 * figure a user was shown.
 */

export type RiskBandKey = "low" | "moderate" | "high" | "unknown";
export type Confidence = "complete" | "incomplete";
export type Severity = "info" | "warning" | "critical";
export type FactorSource = "device" | "profile";

/**
 * One measurement set.
 *
 * Every vital is nullable because the hardware is built incrementally — the
 * current firmware reports heart rate and SpO₂ only. Absent is not zero and must
 * never render as a value.
 */
export interface VitalsReading {
  systolic_mmhg: number | null;
  diastolic_mmhg: number | null;
  heart_rate_bpm: number | null;
  spo2_pct: number | null;
  /** **Body** temperature, from a contact sensor. Never populate from ambient. */
  temperature_c: number | null;
  /**
   * Enclosure/room air temperature. Recorded for context; never drives an alert.
   * Routing this to `temperature_c` would fire a hypothermia flag indoors.
   */
  ambient_temp_c: number | null;
  measured_at: string;
  motion_artifact: boolean;
}

/** Placeholder for a vital the device did not measure. */
export const ABSENT = "—";

/** Rounds for display, or returns the absent placeholder. Never renders null as 0. */
export function show(
  value: number | null | undefined,
  decimals = 0,
): string {
  return value == null ? ABSENT : value.toFixed(decimals);
}

export function showBloodPressure(reading: VitalsReading): string {
  const { systolic_mmhg: sys, diastolic_mmhg: dia } = reading;
  return sys == null || dia == null
    ? ABSENT
    : `${Math.round(sys)}/${Math.round(dia)}`;
}

export interface RiskFactor {
  name: string;
  display_value: string;
  contribution: number;
  source: FactorSource;
  modifiable: boolean;
}

export interface RiskAssessment {
  band: RiskBandKey;
  /** Null whenever `confidence` is "incomplete". Never render a substitute. */
  value_pct: number | null;
  horizon: string;
  factors: RiskFactor[];
  confidence: Confidence;
  missing_fields: string[];
  model_version: string;
  disclaimer: string;
}

export interface AcuteFlag {
  severity: Severity;
  vital: string;
  display_value: string;
  threshold: string;
  message: string;
  recommendation: string;
}

export interface AssessmentResponse {
  assessment: RiskAssessment;
  acute_flags: AcuteFlag[];
  reading_accepted: boolean;
  notes: string[];
}

export interface RiskProfile {
  age: number;
  sex: "male" | "female";
  smoker: boolean;
  diabetic: boolean;
  on_bp_medication?: boolean;
  total_cholesterol_mgdl?: number | null;
  hdl_cholesterol_mgdl?: number | null;
  family_history_cvd?: boolean;
}

const BASE_URL = process.env.NEXT_PUBLIC_MECAI_API_URL ?? "http://127.0.0.1:8000";

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status?: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15000);
    response = await fetch(`${BASE_URL}${path}`, {
      ...init,
      headers: { "Content-Type": "application/json", ...init?.headers },
      cache: "no-store",
      signal: controller.signal,
    });
    clearTimeout(timeout);
  } catch {
    throw new ApiError(
      `Could not reach the scoring service at ${BASE_URL}. Start it with: ` +
        `uv run uvicorn mecai_api.main:app --reload`,
    );
  }

  if (!response.ok) {
    throw new ApiError(
      `Scoring service returned ${response.status}: ${await response.text()}`,
      response.status,
    );
  }

  return (await response.json()) as T;
}

export function assess(
  profile: RiskProfile,
  reading: VitalsReading,
): Promise<AssessmentResponse> {
  return request<AssessmentResponse>("/v1/assess", {
    method: "POST",
    body: JSON.stringify({ profile, reading }),
  });
}

/** Synthetic history for the Trends charts. Dev only — see `enable_mock_endpoints`. */
export function mockSeries(
  hours = 24,
  scenario = "normal",
): Promise<VitalsReading[]> {
  return request<VitalsReading[]>(
    `/v1/mock/series?hours=${hours}&scenario=${scenario}`,
  );
}

export function mockReading(scenario = "normal"): Promise<VitalsReading> {
  return request<VitalsReading>(`/v1/mock/reading?scenario=${scenario}`);
}

/**
 * Only what `MEC-AI3.ino` reports today: heart rate, SpO₂, ambient temp.
 *
 * Use this to see the honest current state — the risk ring comes back unscorable
 * for want of systolic BP while SpO₂ and heart-rate alerts still fire. `mockReading`
 * simulates the *complete* device and flatters the system by comparison.
 */
export function mockFirmwareReading(scenario = "normal"): Promise<VitalsReading> {
  return request<VitalsReading>(`/v1/mock/firmware-reading?scenario=${scenario}`);
}

// ─────────────── SOS types & API ───────────────

export interface SosEvent {
  id: number;
  patient_id: string;
  client_id: string;
  display_name: string;
  triggered_at: string;
  received_at: string;
  resolved_at: string | null;
  source: "app" | "watch";
  latitude: number | null;
  longitude: number | null;
  accuracy_m: number | null;
  heart_rate_bpm: number | null;
  spo2_pct: number | null;
  temperature_c: number | null;
  note: string | null;
}

export interface FleetStats {
  patients: number;
  readings: number;
  readings_last_24h: number;
  open_sos: number;
  patients_with_alerts: number;
  band_counts: Record<string, number>;
  latest_reading_at: string | null;
}

export interface PatientSummary {
  patient_id: string;
  display_name: string;
  profile: RiskProfile;
  device_name: string | null;
  reading_count: number;
  first_reading_at: string | null;
  last_reading_at: string | null;
  latest: StoredReading | null;
  open_sos_count: number;
}

export interface StoredReading extends VitalsReading {
  client_id: string;
  received_at: string;
  band: RiskBandKey;
  value_pct: number | null;
  confidence: Confidence;
  model_version: string;
  missing_fields: string[];
  acute_flags: AcuteFlag[];
}

export function fetchSosEvents(
  unresolvedOnly = false,
  limit = 50,
): Promise<SosEvent[]> {
  return request<SosEvent[]>(
    `/v1/sos?unresolved_only=${unresolvedOnly}&limit=${limit}`,
  );
}

export function resolveSos(eventId: number): Promise<SosEvent> {
  return request<SosEvent>(`/v1/sos/${eventId}/resolve`, { method: "POST" });
}

export function fetchFleetStats(): Promise<FleetStats> {
  return request<FleetStats>("/v1/stats");
}

export function fetchPatients(): Promise<PatientSummary[]> {
  return request<PatientSummary[]>("/v1/patients");
}

export function fetchPatientReadings(
  patientId: string,
  hours = 24,
  limit = 500,
): Promise<StoredReading[]> {
  return request<StoredReading[]>(
    `/v1/patients/${encodeURIComponent(patientId)}/readings` +
      `?hours=${hours}&limit=${limit}`,
  );
}

// The dashboard reads from the archive above rather than from the mock endpoints.
// Mock data re-rolls on every refresh, which makes a trend chart meaningless and
// hides whether ingest works at all.

export interface ApiHealth {
  status: string;
  version: string;
  risk_model: string;
  mock_endpoints: boolean;
  storage: boolean;
  patients: number;
  readings: number;
}

export function health(): Promise<ApiHealth> {
  return request<ApiHealth>("/health");
}

/** Absolute time, for a clinician cross-referencing another record. */
export function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });
}

/**
 * Relative time — the form that answers "is this current?".
 *
 * A dashboard's real question about a reading is how stale it is, and an absolute
 * clock time makes the reader compute that themselves.
 */
export function formatRelative(iso: string | null): string {
  if (iso == null) return "Never";
  const elapsedMs = Date.now() - new Date(iso).getTime();
  const minutes = Math.floor(elapsedMs / 60_000);
  if (minutes < 1) return "Just now";
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} hour${hours === 1 ? "" : "s"} ago`;
  const days = Math.floor(hours / 24);
  return `${days} day${days === 1 ? "" : "s"} ago`;
}
