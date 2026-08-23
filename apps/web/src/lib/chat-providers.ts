/**
 * Where the assistant's words come from.
 *
 * Two providers, chosen by what the environment has:
 *
 * | Provider | Needs | Used when |
 * |---|---|---|
 * | OpenCode Zen (free tier) | nothing | the default |
 * | Claude | `ANTHROPIC_API_KEY` | that variable is set |
 *
 * Zen's free tier is the default because it needs no key and no account, so the
 * dashboard ships with a working assistant instead of a configuration chore. Claude
 * is strictly better at this task and takes over the moment a key exists.
 *
 * ### Why only `ANTHROPIC_API_KEY`, and not `ANTHROPIC_AUTH_TOKEN`
 *
 * The SDK accepts either, and that is a trap here: `ANTHROPIC_AUTH_TOKEN` is set by
 * some developer tooling with a token scoped to something else entirely. Picking it
 * up produced a 401 on every message on a machine whose owner had never configured
 * this dashboard at all. An explicit key is the only signal that someone meant it.
 *
 * ### The Zen model chain
 *
 * Free models rate-limit (`FreeUsageLimitError`) and occasionally report an
 * unavailable upstream, so one model id is not a working configuration — the chain
 * is tried in order. Switching is only possible **before the first character is
 * emitted**; once a reply has started, a failure has to be reported in-band because
 * half a sentence from one model followed by a fresh start from another is worse
 * than an honest truncation.
 */

import Anthropic from "@anthropic-ai/sdk";

import type { ChatMessage } from "./chat";

/** OpenAI-compatible endpoint. The `/go/` sibling requires a key for every model. */
const ZEN_URL = "https://opencode.ai/zen/v1/chat/completions";

/**
 * Free models, best first, as measured against this app's own system prompt.
 *
 * All of these were checked on the honesty rule that matters most here — asked for
 * a blood pressure the watch cannot measure, plus a medication question, none of
 * them invented a figure and none gave the prescribing advice.
 *
 * `nemotron-3-ultra-free` is deliberately absent despite passing that check: it
 * duplicates spans of its own output mid-sentence, which on a clinical summary reads
 * as a garbled record.
 */
const ZEN_MODELS = [
  // Most complete answers: refuses cleanly and still summarises the snapshot.
  "x-preview-f-free",
  // Shortest correct answer of the four; good fallback.
  "hy3-free",
  // Correct but wordier.
  "laguna-s-2.1-free",
] as const;

const ZEN_MAX_TOKENS = 1400;
const CLAUDE_MAX_TOKENS = 16_000;
const CLAUDE_MODEL = "claude-opus-5";

export type ProviderId = "claude" | "zen";

/** Which provider this deployment will use, and the label the panel shows. */
export function activeProvider(): ProviderId {
  return process.env.ANTHROPIC_API_KEY ? "claude" : "zen";
}

/** Streams a reply from whichever provider is active. */
export function streamReply(
  messages: ChatMessage[],
  system: string,
  signal: AbortSignal,
): AsyncIterable<string> {
  return activeProvider() === "claude"
    ? streamClaude(messages, system)
    : streamZen(messages, system, signal);
}

// ──────────────────────────────── Claude ────────────────────────────────

async function* streamClaude(
  messages: ChatMessage[],
  system: string,
): AsyncIterable<string> {
  const client = new Anthropic();
  const stream = client.beta.messages.stream({
    model: CLAUDE_MODEL,
    max_tokens: CLAUDE_MAX_TOKENS,
    // Stable prefix first so it caches; the volatile snapshot rides the last user
    // turn, after the breakpoint.
    system: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }],
    // `medium` rather than the default `high`: the answer is read off a snapshot
    // already in the prompt, and the reader feels latency more than depth.
    output_config: { effort: "medium" },
    // On a policy decline, retry in-call rather than returning a dead stream.
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    messages,
  });

  for await (const event of stream) {
    if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
      yield event.delta.text;
    }
  }

  // A refusal is an HTTP 200 with no text, so it is checked rather than caught.
  // Unhandled it renders as a blank reply, which reads as a broken panel.
  const final = await stream.finalMessage();
  if (final.stop_reason === "refusal") {
    yield "I can't answer that one. Try rephrasing it, or ask about the readings on this screen.";
  }
}

// ────────────────────────────── OpenCode Zen ──────────────────────────────

/**
 * Walks [ZEN_MODELS] until one produces text, then streams it to completion.
 *
 * A model that fails *before* its first character is skipped silently — that is a
 * capacity fact about somebody's free tier, not something the reader can act on. If
 * every model in the chain fails, the last error is thrown so the route can turn it
 * into a status code.
 */
async function* streamZen(
  messages: ChatMessage[],
  system: string,
  signal: AbortSignal,
): AsyncIterable<string> {
  let lastError: unknown = null;

  for (const model of ZEN_MODELS) {
    let started = false;
    try {
      for await (const chunk of zenChunks(model, messages, system, signal)) {
        started = true;
        yield chunk;
      }
      if (started) return;
      // A 200 that produced nothing at all — treat it as this model failing so the
      // chain moves on rather than returning an empty reply.
      lastError = new Error(`${model} returned an empty reply.`);
    } catch (error) {
      if (started) throw error; // Mid-reply: cannot switch, the route reports in-band.
      if (signal.aborted) throw error;
      lastError = error;
    }
  }

  throw new Error(
    `Every free model was unavailable. ${
      lastError instanceof Error ? lastError.message : String(lastError)
    }`,
  );
}

/** One model's SSE stream, decoded to text deltas. */
async function* zenChunks(
  model: string,
  messages: ChatMessage[],
  system: string,
  signal: AbortSignal,
): AsyncIterable<string> {
  const response = await fetch(ZEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      stream: true,
      max_tokens: ZEN_MAX_TOKENS,
      messages: [{ role: "system", content: system }, ...messages],
    }),
    signal,
  });

  if (!response.ok || response.body == null) {
    const detail = (await response.text().catch(() => "")).slice(0, 300);
    throw new Error(`${model} returned ${response.status}. ${detail}`);
  }

  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
  let buffer = "";

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += value;

    // SSE frames are newline-delimited; the tail may be a partial line, so it is
    // kept in the buffer rather than parsed.
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";

    for (const line of lines) {
      const trimmed = line.trim();
      // `: keep-alive` comments arrive for seconds before the first token on a
      // cold free-tier model. They are not data.
      if (trimmed.length === 0 || trimmed.startsWith(":")) continue;
      if (!trimmed.startsWith("data:")) continue;

      const payload = trimmed.slice(5).trim();
      if (payload === "[DONE]") return;

      let frame: ZenFrame;
      try {
        frame = JSON.parse(payload) as ZenFrame;
      } catch {
        continue; // A malformed frame is not worth failing a whole reply over.
      }

      if (frame.error != null) {
        throw new Error(
          typeof frame.error === "string"
            ? frame.error
            : (frame.error.message ?? "the provider reported an error"),
        );
      }

      // `delta.content` only. These models also stream a `reasoning` field, and
      // relaying it would put the model's private working-out in front of a
      // clinician as though it were the answer.
      const text = frame.choices?.[0]?.delta?.content;
      if (typeof text === "string" && text.length > 0) yield text;
    }
  }
}

/** The subset of the OpenAI chunk shape this reads. */
interface ZenFrame {
  choices?: { delta?: { content?: string | null } }[];
  error?: string | { message?: string };
}
