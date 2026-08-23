"use client";

/**
 * The conversation state machine, separated from any particular layout.
 *
 * Extracted so the full assistant page owns the *presentation* of a chat and
 * nothing else: the transcript, the streaming, the abort handling and the energy
 * signal that drives the orb all live here. A second surface that ever needs a chat
 * — a panel, a modal, an embedded strip — gets identical behaviour by calling this
 * rather than by reimplementing it, which is the same argument `models/vital_spec`
 * makes on the mobile side about three detail screens being one screen.
 */

import { useCallback, useEffect, useRef, useState } from "react";

import { useEnergy, type MecBotState } from "@/components/ui/mec-bot";
import { streamChat, type ChatContext, type ChatMessage } from "@/lib/chat";

/**
 * A transcript entry.
 *
 * `system` is a third kind the wire format does not have: a failure notice. It is
 * shown to the reader and never sent back to the model, so a network blip cannot
 * become part of the conversation the assistant believes it had.
 */
export interface ChatEntry {
  id: number;
  role: ChatMessage["role"] | "system";
  content: string;
}

export interface ChatSession {
  entries: ChatEntry[];
  draft: string;
  setDraft: (value: string) => void;

  /** Feeds the orb. Call on each edit so it tracks typing cadence. */
  noteTyping: () => void;

  send: (text: string) => void;
  stop: () => void;
  clear: () => void;

  busy: boolean;

  /** Whether anything has been said yet — drives the hero → docked transition. */
  started: boolean;

  /** Current orb state and activity level. */
  botState: MecBotState;
  energy: number;
}

export function useChat(context: ChatContext): ChatSession {
  const [entries, setEntries] = useState<ChatEntry[]>([]);
  const [draft, setDraft] = useState("");

  /** `thinking` until the first delta lands, then `responding`. */
  const [phase, setPhase] = useState<"idle" | "thinking" | "responding">("idle");

  /**
   * Set briefly after Stop so the orb collapses through `interrupted` rather than
   * snapping to idle. The Gemini Live flow treats interruption as a transition worth
   * showing; here it is the only confirmation Stop landed, because the half-written
   * reply is discarded.
   */
  const [interrupted, setInterrupted] = useState(false);

  const { energy, bump } = useEnergy();

  const abortRef = useRef<AbortController | null>(null);
  const nextId = useRef(0);

  /**
   * A synchronous mirror of [entries].
   *
   * `send` needs the transcript *now*, to put in the request body. Reading it from
   * inside a `setEntries` updater does not work — React defers the updater, so the
   * variable it assigns is still empty by the time the request goes out, and the
   * route rejected every message with "Ask a question first". Reading `entries`
   * from the closure works but goes stale between renders. A ref is the thing that
   * is both current and readable synchronously.
   */
  const entriesRef = useRef<ChatEntry[]>([]);

  const busy = phase !== "idle";

  /** Writes the ref and the state together — two updates that must never diverge. */
  const commit = useCallback((next: (prev: ChatEntry[]) => ChatEntry[]) => {
    entriesRef.current = next(entriesRef.current);
    setEntries(entriesRef.current);
  }, []);

  useEffect(() => {
    if (!interrupted) return;
    const id = setTimeout(() => setInterrupted(false), 900);
    return () => clearTimeout(id);
  }, [interrupted]);

  // Abandon anything in flight on unmount, so a reply cannot land in a component
  // that is gone.
  useEffect(() => () => abortRef.current?.abort(), []);

  const stop = useCallback(() => {
    abortRef.current?.abort();
    abortRef.current = null;
    setPhase("idle");
    setInterrupted(true);
  }, []);

  const clear = useCallback(() => {
    entriesRef.current = [];
    setEntries([]);
  }, []);

  const send = useCallback(
    (text: string) => {
      const question = text.trim();
      if (question.length === 0 || busy) return;

      const replyId = nextId.current + 1;
      nextId.current += 2;

      setDraft("");
      setPhase("thinking");

      // Read from the ref, so this is the transcript as it stands at this instant.
      // Failure notices are excluded: they were never part of the conversation the
      // assistant had, and replaying them would have it apologise for a network
      // error it never saw.
      const history: ChatMessage[] = [
        ...entriesRef.current
          .filter((e): e is ChatEntry & { role: ChatMessage["role"] } => e.role !== "system")
          .map(({ role, content }) => ({ role, content })),
        { role: "user", content: question },
      ];

      commit((prev) => [
        ...prev,
        { id: replyId - 1, role: "user", content: question },
        { id: replyId, role: "assistant", content: "" },
      ]);

      const controller = new AbortController();
      abortRef.current = controller;

      void (async () => {
        try {
          await streamChat(
            { messages: history, context },
            (chunk) => {
              setPhase("responding");
              bump();
              commit((prev) =>
                prev.map((e) =>
                  e.id === replyId ? { ...e, content: e.content + chunk } : e,
                ),
              );
            },
            controller.signal,
          );
        } catch (error) {
          const aborted =
            controller.signal.aborted ||
            (error instanceof DOMException && error.name === "AbortError");

          commit((prev) => {
            // Drop the empty assistant slot: a half-written reply left on screen
            // with no sign it was interrupted reads as a finished answer.
            const withoutSlot = prev.filter(
              (e) => e.id !== replyId || e.content.length > 0,
            );
            if (aborted) return withoutSlot;
            return [
              ...withoutSlot,
              {
                id: nextId.current++,
                role: "system",
                content:
                  error instanceof Error
                    ? error.message
                    : "The assistant failed to reply.",
              },
            ];
          });
        } finally {
          // Only clear if this request is still the current one — a later send has
          // already replaced the controller and owns the phase.
          if (abortRef.current === controller) {
            abortRef.current = null;
            setPhase("idle");
          }
        }
      })();
    },
    [busy, context, bump, commit],
  );

  // Precedence is the order a reader would expect to see it: a live reply beats
  // everything, then the interrupt flash, then their own typing.
  const botState: MecBotState =
    phase !== "idle"
      ? phase
      : interrupted
        ? "interrupted"
        : draft.trim().length > 0
          ? "composing"
          : "idle";

  return {
    entries,
    draft,
    setDraft,
    noteTyping: bump,
    send,
    stop,
    clear,
    busy,
    started: entries.length > 0,
    botState,
    energy,
  };
}
