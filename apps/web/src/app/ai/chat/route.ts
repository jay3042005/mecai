/**
 * The assistant's streaming endpoint.
 *
 * ### Why this is not under `/api`
 *
 * `next.config.ts` rewrites `/api/:path*` to the FastAPI scoring service. A route
 * handler at `/api/chat` *would* win — the array form of `rewrites()` is
 * `afterFiles`, which Next checks after non-dynamic routes — but it would win by a
 * rule nobody reading `next.config.ts` can see. In this repo `/api/*` means "the
 * Python service", so the assistant lives at its own path and that stays true.
 *
 * ### What it streams
 *
 * Plain UTF-8 text, chunk by chunk (`lib/chat.ts` explains why not SSE). Streaming
 * rather than a single response because a reply the reader watches arrive is a
 * reply they can start reading — and because a long answer on a slow link would
 * otherwise sit behind a request timeout.
 *
 * ### Which model answers
 *
 * `lib/chat-providers.ts` owns that. By default it is OpenCode Zen's free tier,
 * which needs no key — so the assistant works on a fresh clone. Setting
 * `ANTHROPIC_API_KEY` switches it to Claude.
 *
 * Either way the system prompt below is the same, and it is the part that keeps the
 * answers safe. A smaller model held to these rules is worth more here than a large
 * one asked politely: every free model in the chain was checked against the case
 * that matters — asked for a blood pressure the watch cannot measure, and asked to
 * start a medication — before being allowed in.
 */

import { ABSENT } from "@/lib/api";
import { activeProvider, streamReply } from "@/lib/chat-providers";
import type { ChatContext, ChatMessage, ChatRequest } from "@/lib/chat";

/** Bounds on what one request may carry. Validated at the boundary, not trusted. */
const MAX_MESSAGES = 40;
const MAX_CHARS_PER_MESSAGE = 8_000;

/**
 * The assistant's brief.
 *
 * Three rules carry real weight here, and all three come from how the rest of this
 * system already behaves:
 *
 * 1. **Absent is not zero** (`lib/api.ts`). A vital the device did not measure must
 *    be reported as not measured. Filling it in would be inventing a reading, which
 *    `mec_watch_face.dart` calls "the wrong kind of polish" on a medical device.
 * 2. **Screening, not diagnosis** — the product's own framing, in `layout.tsx`.
 * 3. **Only what it was given.** No database, no other patients, no recall between
 *    sessions. The snapshot is the truth; general medical knowledge may be added
 *    only to explain what a reading means, never to invent a reading.
 */
const SYSTEM_PROMPT = `You are the MEC-AI assistant, embedded in the MEC-AI clinical console — a dashboard that monitors cardiovascular risk for patients wearing the MEC-AI watch. Your readers are clinicians, rural health workers, and guardians. Be a proper helper: concise but complete, plain-spoken, and action-oriented.

WHAT YOU KNOW
You are given a snapshot of exactly what the user is looking at right now: cohort counters, triage list of patients with acute flags/SOS, and the selected patient's most recent reading, risk band, confidence, missing fields, acute flags, and — when the profile is complete — the per-factor breakdown that explains the score (each factor has name, display value, contribution 0–1, source device/profile, and whether it is modifiable). That snapshot is your only source of patient data. You have no database access and no memory of previous sessions.

HOW TO BE HELPFUL
- "What is driving this patient's risk band?" — Use the <factors> list in the snapshot. List the top 3 drivers by contribution, give each as "Name: value (X% of model, source/profile vs device, modifiable or not)". Say which are modifiable and which are not. If band is low, say so plainly and note the protective factors. If confidence is incomplete, lead with missing fields and that the figure is screening-only.
- "Which patients need attention first?" — Use <cohort><alertedPatients>. Triage by severity: SOS first, then critical acute flags, then warning. Name 2-4 patients and why.
- "Summarise this patient's latest readings." — Give vitals with units, band/percentage and confidence, flags, and one-line implication.
- Cohort questions — use band counts and alerted list.
- Always lead with urgent findings (critical SpO2, hypertensive crisis, open SOS) and say to seek emergency care. Do not soften it.

HARD RULES
- A vital shown as "not measured" was not measured. Say so. Never estimate it, never substitute a typical value, and never treat a missing number as zero or as normal.
- The current watch hardware reports heart rate, blood oxygen and a temperature reading. It has no blood-pressure cuff. If asked about blood pressure and none is present, say the device does not measure it rather than guessing. (Systolic for the 10-year score comes from the questionnaire baseline, not the watch.)
- Risk figures here are screening indicators, not diagnoses. Never tell a user what condition someone has, and never instruct anyone to start, stop or change a medication or dose. You may explain what a factor means and that the modifiable ones are worth discussing with the clinician.
- If the snapshot does not contain what was asked and it is not general medical knowledge, say plainly that it is not on this screen. Do not speculate to fill the gap.
- Quote figures with their units, exactly as given. Never round a value into a different clinical band.

STYLE
- Answer first, in two or three sentences. Add detail only if it changes what the reader would do.
- Plain prose. No markdown headings, no bold, no tables. A short dash list is fine when you are genuinely listing findings or drivers.
- General clinical questions ("what does SpO2 below 95% mean", "what is HDL") are welcome and should be answered in ordinary language, then tied back to this patient's context where relevant.`;

export async function POST(request: Request): Promise<Response> {
  let body: ChatRequest;
  try {
    body = (await request.json()) as ChatRequest;
  } catch {
    return new Response("That request was not valid JSON.", { status: 400 });
  }

  const messages = sanitize(body?.messages);
  if (messages.length === 0) {
    return new Response("Ask a question first.", { status: 400 });
  }

  // The client hangs up when the reader presses Stop or closes the panel. Passing
  // the signal down means the upstream request is dropped too, rather than being
  // generated to completion for nobody.
  const aborted = new AbortController();
  request.signal.addEventListener("abort", () => aborted.abort(), { once: true });

  try {
    return await textStream(
      streamReply(withContext(messages, body.context), SYSTEM_PROMPT, aborted.signal),
      // The first chunk is pulled *before* the response headers go out, so a
      // rate-limited free tier or a bad key still becomes a real status code.
      // Without this the request 200s and the failure arrives in-band, which
      // renders as an empty reply — the panel looks broken when it is only
      // unavailable, and only one of those is actionable.
      { probeFirstChunk: true },
    );
  } catch (error) {
    // The reader can act on "every free model is busy" or "the key was rejected".
    // They cannot act on a stack trace, and the panel has nowhere to put one.
    const reason = error instanceof Error ? error.message : String(error);
    return new Response(
      activeProvider() === "claude"
        ? `The assistant could not reach Claude. ${reason}`
        : `The free assistant is unavailable right now. ${reason} ` +
            `Set ANTHROPIC_API_KEY to use Claude instead.`,
      { status: 502 },
    );
  }
}

/** Trims the transcript to what the API should see, and drops anything malformed. */
function sanitize(messages: unknown): ChatMessage[] {
  if (!Array.isArray(messages)) return [];

  const cleaned: ChatMessage[] = [];
  for (const entry of messages) {
    if (typeof entry !== "object" || entry === null) continue;
    const { role, content } = entry as Partial<ChatMessage>;
    if (role !== "user" && role !== "assistant") continue;
    if (typeof content !== "string") continue;
    const text = content.trim().slice(0, MAX_CHARS_PER_MESSAGE);
    if (text.length === 0) continue;
    cleaned.push({ role, content: text });
  }

  // Keep the tail: the recent turns are the ones the current question refers to.
  const tail = cleaned.slice(-MAX_MESSAGES);

  // The API requires the first turn to be `user`. A transcript that opens on an
  // assistant message means the client trimmed mid-exchange.
  const start = tail.findIndex((m) => m.role === "user");
  return start === -1 ? [] : tail.slice(start);
}

/**
 * Attaches the snapshot to the newest user turn.
 *
 * On the last turn rather than in `system` so the cached system prefix stays byte
 * -identical across the conversation while the figures move — the placement
 * `shared/prompt-caching.md` asks for.
 */
function withContext(
  messages: ChatMessage[],
  context: ChatContext | undefined,
): ChatMessage[] {
  const snapshot = describeContext(context);
  if (snapshot === null) return messages;

  const last = messages.length - 1;
  return messages.map((message, i) =>
    i === last
      ? {
          ...message,
          content: `${message.content}\n\n<screen_snapshot>\n${snapshot}\n</screen_snapshot>`,
        }
      : message,
  );
}

/** One number, or the same em-dash the rest of the console uses for absent. */
function value(n: number | null | undefined, unit: string, decimals = 0): string {
  return n == null ? `${ABSENT} (not measured)` : `${n.toFixed(decimals)} ${unit}`;
}

/** The snapshot as prose. Null when the console has nothing loaded yet. */
function describeContext(context: ChatContext | undefined): string | null {
  if (!context?.cohort && !context?.patient) return null;

  const lines: string[] = [];

  if (context.cohort) {
    const c = context.cohort;
    const bands = Object.entries(c.bandCounts)
      .map(([band, n]) => `${n} ${band}`)
      .join(", ");
    lines.push(
      `Cohort: ${c.patients} enrolled patients, ${c.readingsLast24h} readings in the last 24 hours, ` +
        `${c.openSos} unresolved SOS alerts, ${c.patientsWithAlerts} patients with acute flags.` +
        (bands ? ` Risk bands: ${bands}.` : ""),
    );
    if (c.alertedPatients && c.alertedPatients.length > 0) {
      lines.push(
        `Patients needing attention (sorted, worst first): ` +
          c.alertedPatients.map((a) => `${a.name} — ${a.band}, ${a.flag}`).join(" | "),
      );
    }
  }

  if (context.patient) {
    const p = context.patient;
    const profileBits: string[] = [];
    if (p.age != null) profileBits.push(`age ${p.age}`);
    if (p.sex) profileBits.push(String(p.sex));
    lines.push(
      `Selected patient: ${p.name}` + (profileBits.length ? ` (${profileBits.join(", ")})` : "") + `.`,
      `Risk band ${p.band}` +
        (p.valuePct == null
          ? ` — no percentage, because the profile is ${p.confidence}.`
          : ` at ${p.valuePct.toFixed(1)}% ten-year risk (${p.confidence} profile).`),
      p.missingFields.length > 0
        ? `Missing profile fields: ${p.missingFields.join(", ")}.`
        : "Profile is complete.",
      ...(p.modelVersion ? [`Model: ${p.modelVersion}.`] : []),
      ...(p.factors && p.factors.length > 0
        ? [
            `Risk drivers (per-factor contribution, sums to 1.0, sorted high → low):`,
            ...[...p.factors]
              .sort((a, b) => b.contribution - a.contribution)
              .map(
                (f) =>
                  `- ${f.name}: ${f.displayValue} — ${(f.contribution * 100).toFixed(1)}% of model, source ${f.source}, ${f.modifiable ? "modifiable" : "not modifiable"}`,
              ),
          ]
        : p.confidence === "complete"
          ? ["Factors: not yet scored for this reading — ask to re-evaluate if needed."]
          : ["No factors: profile incomplete, so the score is not computed."]),
      `Latest reading${p.measuredAt ? ` (${p.measuredAt})` : " (never)"}:`,
      `- blood pressure: ${
        p.systolicMmHg == null || p.diastolicMmHg == null
          ? `${ABSENT} (this watch has no cuff)`
          : `${Math.round(p.systolicMmHg)}/${Math.round(p.diastolicMmHg)} mmHg`
      }`,
      `- heart rate: ${value(p.heartRateBpm, "bpm")}`,
      `- blood oxygen: ${value(p.spo2Pct, "%")}`,
      `- temperature: ${value(p.temperatureC, "C", 1)}`,
      p.acuteFlags.length === 0
        ? "No acute flags on this reading."
        : `Acute flags: ${p.acuteFlags
            .map((f) => `${f.severity} — ${f.vital}: ${f.message}`)
            .join("; ")}`,
    );
  }

  return lines.join("\n");
}

/**
 * Wraps an async iterable of strings as a streaming text response.
 *
 * With `probeFirstChunk`, the first chunk is awaited before the `Response` is
 * constructed, so a failure that happens on the very first read is still throwable
 * — and therefore still catchable by the caller as a status code. Everything after
 * that point is reported in-band, because the headers have already gone out.
 */
async function textStream(
  chunks: AsyncIterable<string>,
  { probeFirstChunk = false }: { probeFirstChunk?: boolean } = {},
): Promise<Response> {
  const encoder = new TextEncoder();
  const iterator = chunks[Symbol.asyncIterator]();

  // Throws on the caller's side if the upstream rejects immediately.
  const first = probeFirstChunk ? await iterator.next() : null;

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        if (first != null) {
          if (first.done) {
            controller.close();
            return;
          }
          controller.enqueue(encoder.encode(first.value));
        }

        for (;;) {
          const { done, value } = await iterator.next();
          if (done) break;
          if (value) controller.enqueue(encoder.encode(value));
        }
      } catch (error) {
        // The response has already begun, so the status cannot change. Say what
        // happened in-band instead of truncating and letting it read as a
        // complete answer that simply stopped making sense.
        controller.enqueue(
          encoder.encode(
            `\n\n[The reply was cut short: ${
              error instanceof Error ? error.message : String(error)
            }]`,
          ),
        );
      } finally {
        controller.close();
      }
    },
    // The client aborting is the common case, not an error — tell the upstream so
    // the Claude request is dropped rather than billed to completion.
    cancel: () => void iterator.return?.(),
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
      // Without this a browser may sniff a partial body as another type.
      "X-Content-Type-Options": "nosniff",
    },
  });
}
