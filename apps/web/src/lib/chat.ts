/**
 * Wire contract for the assistant, shared by the panel and the route handler.
 *
 * The route streams **plain UTF-8 text**, not SSE and not JSON lines. A chat panel
 * only ever needs "more characters for the current reply", and a framing format
 * would mean a parser on both ends plus a decision about what to do with a half
 * frame — for no gain the reader can see.
 */

export type ChatRole = "user" | "assistant";

export interface ChatMessage {
  role: ChatRole;
  content: string;
}

/**
 * The snapshot the panel sends with every question.
 *
 * The assistant is grounded in what is on screen rather than given database
 * access: it can only discuss figures the console is already showing the same
 * user, so it cannot leak a patient they are not looking at, and it cannot invent
 * a reading that no device reported.
 *
 * Every vital is nullable for the reason `lib/api.ts` gives — absent is not zero,
 * and the system prompt requires the assistant to say "not measured" rather than
 * substitute a number.
 */
export interface ChatContext {
  cohort?: {
    patients: number;
    readingsLast24h: number;
    openSos: number;
    patientsWithAlerts: number;
    bandCounts: Record<string, number>;
    alertedPatients?: { name: string; band: string; flag: string }[];
  };
  patient?: {
    name: string;
    band: string;
    valuePct: number | null;
    confidence: string;
    missingFields: string[];
    measuredAt: string | null;
    systolicMmHg: number | null;
    diastolicMmHg: number | null;
    heartRateBpm: number | null;
    spo2Pct: number | null;
    temperatureC: number | null;
    acuteFlags: { severity: string; vital: string; message: string }[];
    factors?: { name: string; displayValue: string; contribution: number; source: string; modifiable: boolean }[];
    modelVersion?: string;
    age?: number;
    sex?: string;
  };
}

export interface ChatRequest {
  messages: ChatMessage[];
  context?: ChatContext;
}

/** Endpoint. Deliberately **not** under `/api` — see the route handler's note. */
export const CHAT_ENDPOINT = "/ai/chat";

/**
 * Opening prompts.
 *
 * Phrased as the questions a clinician actually arrives with, and each answerable
 * from the snapshot above — an example question the assistant would have to refuse
 * teaches the user that it cannot help.
 */
export const CHAT_SUGGESTIONS = [
  "Summarise this patient's latest readings.",
  "Which patients need attention first?",
  "What is driving this patient's risk band?",
  "Explain what SpO₂ below 95% means.",
] as const;

/**
 * Streams a reply, invoking `onDelta` for each chunk as it lands.
 *
 * Resolves with the complete text. Throws on a non-OK response, using the body as
 * the message — the route sends a readable sentence rather than a status code,
 * because "the assistant is not configured" is something the reader can act on and
 * "500" is not.
 */
export async function streamChat(
  request: ChatRequest,
  onDelta: (chunk: string) => void,
  signal?: AbortSignal,
): Promise<string> {
  const response = await fetch(CHAT_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
    signal,
  });

  if (!response.ok || response.body == null) {
    const detail = (await response.text().catch(() => "")).trim();
    throw new Error(detail || `The assistant returned ${response.status}.`);
  }

  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
  let full = "";

  // No try/finally releasing the lock: an abort rejects this read, and the panel
  // discards the whole response along with the reader. Cancelling a stream that
  // already errored would throw over the top of the real reason.
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (value) {
      full += value;
      onDelta(value);
    }
  }

  return full;
}
