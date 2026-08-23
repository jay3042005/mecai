"use client";

/**
 * The assistant — a full page, with the orb as its subject.
 *
 * ### Why this is a page and not a panel
 *
 * The first version of this was a corner popup, and the orb had nowhere to be: at
 * 44px in a header strip, a luminous deforming field is a smudge. The Gemini Live
 * interaction this borrows from works because the visual *is* the screen — you enter
 * it the way you enter a call, and the conversation arranges itself around the
 * thing that is listening. That needs a viewport, so it gets one.
 *
 * ### The flow, in two stages
 *
 * | Stage | Orb | Everything else |
 * |---|---|---|
 * | Nothing said yet | hero, centred, ~260px | greeting and openers beneath it |
 * | Conversing | docked to the header, ~46px | transcript fills the page |
 *
 * The move between them is a single `layoutId` transition, so the orb visibly
 * *travels* from the middle of the screen up into the header on the first question
 * rather than being replaced by a smaller copy. That transition is the whole reason
 * the flow reads as entering something.
 *
 * Under reduced motion the stages still swap — the layout change is information,
 * not decoration — but it happens without the tween.
 *
 * ### Standalone by construction
 *
 * The page fetches its own cohort and patient list rather than being handed state,
 * so it survives a direct link, a refresh and a bookmark. `?patient=<id>` preselects
 * one; the dashboard's launcher passes the row the clinician was reading.
 *
 * If the scoring service is unreachable the page still works — the assistant simply
 * has no snapshot to read from, and says so rather than pretending otherwise.
 */

import { motion } from "motion/react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { Suspense, useEffect, useMemo, useRef, useState } from "react";
import { ArrowLeft, Send, Square, Trash2 } from "lucide-react";

import { MecBot } from "@/components/ui/mec-bot";
import {
  assess,
  fetchFleetStats,
  fetchPatients,
  type FleetStats,
  type PatientSummary,
} from "@/lib/api";
import { CHAT_SUGGESTIONS, type ChatContext } from "@/lib/chat";
import { useChat, type ChatEntry } from "@/lib/use-chat";
import { usePrefersReducedMotion } from "@/lib/use-reduced-motion";

const HERO_ORB = 260;
const DOCKED_ORB = 46;

export default function AssistantPage() {
  // `useSearchParams` suspends, and the fallback is the hero stage without a
  // patient — which is what the page looks like a beat later anyway.
  return (
    <Suspense fallback={<div style={{ minHeight: "100vh", background: "var(--mec-page)" }} />}>
      <Assistant />
    </Suspense>
  );
}

function Assistant() {
  const params = useSearchParams();
  const reduced = usePrefersReducedMotion();

  const [patients, setPatients] = useState<PatientSummary[]>([]);
  const [fleet, setFleet] = useState<FleetStats | null>(null);
  const [selectedId, setSelectedId] = useState(params.get("patient") ?? "");
  const [offline, setOffline] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void Promise.all([fetchPatients(), fetchFleetStats()])
      .then(([roster, stats]) => {
        if (cancelled) return;
        setPatients(roster);
        setFleet(stats);
        // Fall back to the first row so the page always has something to discuss.
        setSelectedId((current) =>
          current.length > 0 && roster.some((p) => p.patient_id === current)
            ? current
            : (roster[0]?.patient_id ?? ""),
        );
      })
      .catch(() => {
        if (!cancelled) setOffline(true);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const selected = patients.find((p) => p.patient_id === selectedId);

  // Live factor breakdown — the roster stores band but not per-factor contributions.
  // Fetching via `assess` lets the assistant answer "what is driving this band?"
  // without hallucinating, and re-uses the same scoring path the dashboard uses.
  const [liveFactors, setLiveFactors] = useState<
    NonNullable<NonNullable<ChatContext["patient"]>["factors"]> | null
  >(null);
  const [liveModel, setLiveModel] = useState<string | undefined>(undefined);

  useEffect(() => {
    const latest = selected?.latest;
    const profile = selected?.profile;
    if (!selected || !latest || !profile || offline) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- clearing stale factors when selection/offline changes is the intended sync
      setLiveFactors(null);
      setLiveModel(undefined);
      return;
    }
    let cancelled = false;
    const reading = {
      systolic_mmhg: latest.systolic_mmhg,
      diastolic_mmhg: latest.diastolic_mmhg,
      heart_rate_bpm: latest.heart_rate_bpm,
      spo2_pct: latest.spo2_pct,
      temperature_c: latest.temperature_c,
      ambient_temp_c: latest.ambient_temp_c,
      measured_at: latest.measured_at ?? new Date().toISOString(),
      motion_artifact: latest.motion_artifact ?? false,
    } as const;
    void assess(profile as unknown as Parameters<typeof assess>[0], reading as unknown as Parameters<typeof assess>[1])
      .then((res) => {
        if (cancelled) return;
        setLiveFactors(
          res.assessment.factors.map((f) => ({
            name: f.name,
            displayValue: f.display_value,
            contribution: f.contribution,
            source: f.source,
            modifiable: f.modifiable,
          })),
        );
        setLiveModel(res.assessment.model_version);
      })
      .catch(() => {
        if (!cancelled) {
          setLiveFactors(null);
          setLiveModel(undefined);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [selected, offline]);

  const context: ChatContext = useMemo(() => {
    const latest = selected?.latest;
    // Build triage list from roster — lets the assistant answer "who needs attention first?"
    const alertedPatients =
      patients.length > 0
        ? patients
            .filter((p) => (p.latest?.acute_flags?.length ?? 0) > 0 || p.open_sos_count > 0)
            .sort((a, b) => {
              const sev = (s: string) => (s === "critical" ? 0 : s === "warning" ? 1 : 2);
              const aWorst = a.latest?.acute_flags?.[0]?.severity ?? "info";
              const bWorst = b.latest?.acute_flags?.[0]?.severity ?? "info";
              if (sev(aWorst) !== sev(bWorst)) return sev(aWorst) - sev(bWorst);
              return (b.open_sos_count ?? 0) - (a.open_sos_count ?? 0);
            })
            .slice(0, 6)
            .map((p) => ({
              name: p.display_name,
              band: p.latest?.band ?? "unknown",
              flag: p.open_sos_count > 0 ? `SOS ×${p.open_sos_count}` : (p.latest?.acute_flags?.[0]?.message ?? p.latest?.acute_flags?.[0]?.vital ?? "flag"),
            }))
        : undefined;

    return {
      cohort: fleet
        ? {
            patients: fleet.patients,
            readingsLast24h: fleet.readings_last_24h,
            openSos: fleet.open_sos,
            patientsWithAlerts: fleet.patients_with_alerts,
            bandCounts: fleet.band_counts,
            alertedPatients,
          }
        : undefined,
      patient:
        selected && latest
          ? {
              name: selected.display_name,
              band: latest.band,
              valuePct: latest.value_pct,
              confidence: latest.confidence,
              missingFields: latest.missing_fields,
              measuredAt: selected.last_reading_at,
              systolicMmHg: latest.systolic_mmhg,
              diastolicMmHg: latest.diastolic_mmhg,
              heartRateBpm: latest.heart_rate_bpm,
              spo2Pct: latest.spo2_pct,
              temperatureC: latest.temperature_c ?? latest.ambient_temp_c,
              acuteFlags: latest.acute_flags.map((f) => ({
                severity: f.severity,
                vital: f.vital,
                message: f.message,
              })),
              factors: liveFactors ?? undefined,
              modelVersion: liveModel ?? latest.model_version,
              age: selected.profile.age,
              sex: selected.profile.sex,
            }
          : undefined,
    };
  }, [fleet, selected, liveFactors, liveModel, patients]);

  const chat = useChat(context);
  const transcriptRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    transcriptRef.current?.scrollTo({
      top: transcriptRef.current.scrollHeight,
      behavior: reduced ? "auto" : "smooth",
    });
  }, [chat.entries, reduced]);

  useEffect(() => inputRef.current?.focus(), []);

  const orbTransition = reduced
    ? { duration: 0 }
    : { type: "spring" as const, stiffness: 220, damping: 26 };

  return (
    <main
      className="flex h-screen flex-col overflow-hidden"
      style={{ background: "var(--mec-page)" }}
    >
      {/* Atmosphere. Static — a drifting field behind clinical text is the
          decorative motion docs/design.md §2 rules out; the orb is the thing that
          is allowed to move here. */}
      <div
        className="pointer-events-none fixed inset-0 z-0"
        style={{
          background:
            "radial-gradient(circle at 50% 22%, color-mix(in srgb, var(--mec-s1) 15%, transparent), transparent 46%), radial-gradient(circle at 82% 78%, color-mix(in srgb, var(--mec-s2) 9%, transparent), transparent 40%)",
        }}
        aria-hidden
      />

      <header
        className="relative z-10 flex shrink-0 items-center gap-3 border-b px-4 py-3 sm:px-6"
        style={{ borderColor: "var(--mec-hairline)" }}
      >
        <Link
          href="/dashboard"
          className="group inline-flex items-center gap-2 rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors hover:bg-[var(--mec-elevated)]"
          style={{
            borderColor: "var(--mec-hairline)",
            color: "var(--mec-ink-secondary)",
          }}
        >
          <ArrowLeft
            size={14}
            aria-hidden
            className="transition-transform duration-300 group-hover:-translate-x-1"
          />
          Console
        </Link>

        {/* The orb docks here once the conversation starts. Same `layoutId` as the
            hero below, so it travels rather than being swapped. */}
        <div className="flex min-w-0 flex-1 items-center gap-2">
          {chat.started && (
            <motion.div layoutId="assistant-orb" transition={orbTransition}>
              <MecBot state={chat.botState} energy={chat.energy} size={DOCKED_ORB} />
            </motion.div>
          )}
          {chat.started && (
            <div className="min-w-0">
              <p
                className="truncate text-sm font-semibold"
                style={{ color: "var(--mec-ink-primary)" }}
              >
                MEC-AI Assistant
              </p>
              <p
                className="truncate text-xs"
                style={{ color: "var(--mec-ink-muted)" }}
                aria-live="polite"
              >
                {STATUS[chat.botState]}
              </p>
            </div>
          )}
        </div>

        <PatientPicker
          patients={patients}
          selectedId={selectedId}
          onSelect={setSelectedId}
          offline={offline}
        />

        {chat.started && (
          <button
            type="button"
            onClick={chat.clear}
            disabled={chat.busy}
            className="inline-flex shrink-0 items-center gap-1 rounded-full border px-3 py-1.5 text-xs font-medium transition-colors hover:bg-[var(--mec-elevated)] disabled:opacity-40"
            style={{
              borderColor: "var(--mec-hairline)",
              color: "var(--mec-ink-muted)",
            }}
          >
            <Trash2 size={12} aria-hidden />
            <span className="hidden sm:inline">New</span>
          </button>
        )}
      </header>

      {/* The stage area. Positioned and clipped so the two stages can be absolutely
          placed inside it and overlap during the handover without either escaping
          into the header or the composer. */}
      <section className="relative z-10 flex-1 overflow-hidden">
      {/* No `AnimatePresence` around the stage swap, deliberately.
          
          Cross-fading the two stages keeps the outgoing one mounted, and both it and
          the incoming header carry the `assistant-orb` layoutId — two live elements
          claiming one id. The observed result was the hero left painted at full
          opacity on top of the transcript, which looked like the reply had vanished.
          
          A shared `layoutId` animates across a plain unmount/mount in the same
          commit, so the orb still travels from the centre of the page into the
          header. That travel is the transition worth having; the cross-fade was
          not. */}
      {chat.started ? (
          <div
            key="transcript"
            ref={transcriptRef}
            className="absolute inset-0 overflow-y-auto px-4 py-6 sm:px-6"
            role="log"
            aria-live="polite"
            aria-label="Conversation"
          >
            <ul className="mx-auto flex w-full max-w-3xl flex-col gap-5">
              {chat.entries.map((entry) => (
                <li key={entry.id}>
                  <Bubble
                    entry={entry}
                    pending={entry.role === "assistant" && entry.content.length === 0}
                    energy={chat.energy}
                  />
                </li>
              ))}
            </ul>
          </div>
        ) : (
          <div
            key="hero"
            className="absolute inset-0 flex flex-col items-center justify-center gap-6 px-4"
          >
            {/* Entering: the orb scales up into view once, the way Live opens. */}
            <motion.div
              layoutId="assistant-orb"
              transition={orbTransition}
              initial={reduced ? false : { scale: 0.7, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
            >
              <MecBot state={chat.botState} energy={chat.energy} size={HERO_ORB} />
            </motion.div>

            <div className="text-center">
              <h1
                className="text-2xl font-semibold sm:text-3xl"
                style={{ color: "var(--mec-ink-primary)" }}
              >
                {selected ? `Ask about ${selected.display_name}` : "MEC-AI Assistant"}
              </h1>
              <p
                className="mx-auto mt-2 max-w-md text-sm"
                style={{ color: "var(--mec-ink-secondary)" }}
              >
                {offline
                  ? "The scoring service is unreachable, so I have no patient data to read. I can still answer general questions."
                  : selected
                    ? "I read this patient's latest reading and the cohort counters. I won't invent a figure the watch didn't measure."
                    : "No patients have synced yet. I can still answer general clinical questions."}
              </p>
            </div>

            <ul className="flex max-w-2xl flex-wrap justify-center gap-2">
              {CHAT_SUGGESTIONS.map((suggestion) => (
                <li key={suggestion}>
                  <button
                    type="button"
                    onClick={() => chat.send(suggestion)}
                    className="rounded-full border px-4 py-2 text-xs font-medium transition-colors hover:bg-[var(--mec-elevated)]"
                    style={{
                      borderColor: "var(--mec-hairline)",
                      color: "var(--mec-ink-primary)",
                    }}
                  >
                    {suggestion}
                  </button>
                </li>
              ))}
            </ul>
          </div>
        )}
      </section>

      <div
        className="relative z-10 shrink-0 border-t px-4 py-4 sm:px-6"
        style={{ borderColor: "var(--mec-hairline)" }}
      >
        <div className="mx-auto w-full max-w-3xl">
          <div
            className="flex items-end gap-2 rounded-2xl border px-3 py-2 transition-colors focus-within:border-[var(--mec-s1)]"
            style={{
              borderColor: "var(--mec-hairline)",
              background: "var(--mec-card)",
            }}
          >
            <textarea
              ref={inputRef}
              rows={1}
              value={chat.draft}
              onChange={(event) => {
                chat.setDraft(event.target.value);
                // The chat-mode stand-in for microphone amplitude — each edit feeds
                // the orb, so it lifts with how fast the reader is typing.
                chat.noteTyping();
              }}
              onKeyDown={(event) => {
                // Enter sends; Shift+Enter is a newline. `isComposing` guards an IME
                // candidate selection from firing the message.
                if (
                  event.key === "Enter" &&
                  !event.shiftKey &&
                  !event.nativeEvent.isComposing
                ) {
                  event.preventDefault();
                  chat.send(chat.draft);
                }
              }}
              placeholder={
                selected
                  ? `Ask about ${selected.display_name} or the cohort…`
                  : "Ask a question…"
              }
              aria-label="Your question"
              className="max-h-40 min-h-9 flex-1 resize-y bg-transparent text-sm outline-none sm:text-base"
              style={{ color: "var(--mec-ink-primary)" }}
            />

            {chat.busy ? (
              <button
                type="button"
                onClick={chat.stop}
                aria-label="Stop the reply"
                className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border transition-colors hover:bg-[var(--mec-elevated)]"
                style={{
                  borderColor: "var(--mec-hairline)",
                  color: "var(--mec-ink-primary)",
                }}
              >
                <Square size={14} aria-hidden />
              </button>
            ) : (
              <button
                type="button"
                onClick={() => chat.send(chat.draft)}
                disabled={chat.draft.trim().length === 0}
                aria-label="Send"
                className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl transition-transform active:scale-95 disabled:opacity-40"
                style={{ background: "var(--mec-s1)", color: "var(--mec-page)" }}
              >
                <Send size={16} aria-hidden />
              </button>
            )}
          </div>

          {/* Present on every turn. The one caveat a reader must never have to
              scroll to find. */}
          <p
            className="mt-2 text-center text-[11px]"
            style={{ color: "var(--mec-ink-muted)" }}
          >
            Screening support, not a diagnosis. Answers describe only the readings on
            this screen.
          </p>
        </div>
      </div>
    </main>
  );
}

/** Status wording. The orb's silhouette says the same thing without words. */
const STATUS: Record<string, string> = {
  idle: "Ready",
  composing: "Listening…",
  thinking: "Thinking…",
  responding: "Replying…",
  interrupted: "Stopped",
  offline: "Unavailable",
};

function PatientPicker({
  patients,
  selectedId,
  onSelect,
  offline,
}: {
  patients: PatientSummary[];
  selectedId: string;
  onSelect: (id: string) => void;
  offline: boolean;
}) {
  if (offline || patients.length === 0) return null;

  return (
    <label className="shrink-0">
      <span className="sr-only">Patient in context</span>
      <select
        value={selectedId}
        onChange={(event) => onSelect(event.target.value)}
        className="max-w-[9rem] rounded-full border px-3 py-1.5 text-xs font-medium outline-none sm:max-w-none"
        style={{
          borderColor: "var(--mec-hairline)",
          background: "var(--mec-card)",
          color: "var(--mec-ink-primary)",
        }}
      >
        {patients.map((patient) => (
          <option key={patient.patient_id} value={patient.patient_id}>
            {patient.display_name}
          </option>
        ))}
      </select>
    </label>
  );
}

function Bubble({
  entry,
  pending,
  energy,
}: {
  entry: ChatEntry;
  pending: boolean;
  energy: number;
}) {
  if (entry.role === "user") {
    return (
      <div className="flex justify-end">
        <p
          className="max-w-[80%] whitespace-pre-wrap rounded-2xl px-4 py-2.5 text-sm sm:text-base"
          style={{
            background: "color-mix(in srgb, var(--mec-s1) 24%, var(--mec-elevated))",
            color: "var(--mec-ink-primary)",
          }}
        >
          {entry.content}
        </p>
      </div>
    );
  }

  if (entry.role === "system") {
    return (
      <p
        className="rounded-xl border px-4 py-3 text-xs"
        style={{
          // The alarm hue is reserved for clinical alarms, so a transport failure
          // borrows the "high" band's colour with a word beside it rather than
          // presenting itself as a patient emergency.
          borderColor: "color-mix(in srgb, var(--mec-risk-high) 45%, transparent)",
          background: "color-mix(in srgb, var(--mec-risk-high) 10%, transparent)",
          color: "var(--mec-ink-secondary)",
        }}
        role="status"
      >
        <span style={{ color: "var(--mec-risk-high)", fontWeight: 600 }}>
          Assistant unavailable.{" "}
        </span>
        {entry.content}
      </p>
    );
  }

  return (
    <div className="flex gap-3">
      <span className="mt-0.5 shrink-0">
        <MecBot state={pending ? "thinking" : "idle"} energy={energy} size={30} />
      </span>
      <p
        className="max-w-[80%] whitespace-pre-wrap text-sm sm:text-base"
        style={{ color: "var(--mec-ink-secondary)", lineHeight: 1.6 }}
      >
        {pending ? (
          <span style={{ color: "var(--mec-ink-muted)" }}>Reading the screen…</span>
        ) : (
          entry.content
        )}
      </p>
    </div>
  );
}
