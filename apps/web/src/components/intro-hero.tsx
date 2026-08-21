"use client";

/**
 * The dashboard's introduction — first thing a clinician sees.
 *
 * A full-viewport hero over [AnimatedGradientBackground], opening with the MEC-AI
 * wordmark's letter-pop so the web surface introduces the product the same way the
 * watch and the phone app do.
 *
 * ### Why the copy is careful
 *
 * This is a medical screening tool, and docs/design.md §2 principle 5 forbids
 * gamifying a clinical result. So the hero states what the product measures and
 * what it does not claim — "screening indicator, not a diagnosis" appears here,
 * not only in the small print beneath a score.
 *
 * "Get Started" scrolls to the console rather than navigating: the dashboard is
 * one page, and a link that reloads to the same document would be a worse answer.
 */

import { motion } from "motion/react";
import Link from "next/link";
import { ArrowRight, Activity, ShieldCheck, Watch } from "lucide-react";

import AnimatedGradientBackground, {
  MEC_GRADIENT,
} from "@/components/ui/animated-gradient-background";
import { MecWordmark } from "@/components/ui/mec-wordmark";
import Image from "next/image";
import { usePrefersReducedMotion } from "@/lib/use-reduced-motion";

/** What the watch actually streams, stated plainly. */
const CAPABILITIES = [
  { icon: Watch, label: "Live from the wrist", detail: "Heart rate · SpO2 · Temperature" },
  { icon: Activity, label: "10-year CVD screening", detail: "Framingham, scored on-device" },
  { icon: ShieldCheck, label: "Alerts without a network", detail: "Acute flags fire offline" },
] as const;

export function IntroHero() {
  const reduced = usePrefersReducedMotion();

  // Entrance for everything below the wordmark. Staggered, and inert under
  // reduced motion, matching MecStagger on mobile.
  const rise = (delay: number) =>
    reduced
      ? {}
      : {
          initial: { opacity: 0, y: 12 },
          animate: { opacity: 1, y: 0 },
          transition: { delay, duration: 0.5, ease: [0.05, 0.7, 0.1, 1] as const },
        };

  return (
    <section
      className="relative flex min-h-[100svh] w-full flex-col items-center justify-center overflow-hidden px-6 py-24 text-center"
      style={{ background: "var(--mec-page)" }}
    >
      <AnimatedGradientBackground
        Breathing
        startingGap={118}
        breathingRange={6}
        topOffset={12}
        gradientColors={[...MEC_GRADIENT.colors]}
        gradientStops={[...MEC_GRADIENT.stops]}
        containerClassName="opacity-[0.22]"
      />

      <div className="relative z-10 flex w-full max-w-3xl flex-col items-center">
        <Image
          src="/mec-ai-logo.png"
          alt="MEC-AI logo"
          width={512}
          height={512}
          priority
          className="mb-5 h-28 w-28 rounded-full object-cover shadow-lg sm:h-32 sm:w-32"
        />
        <MecWordmark className="justify-center text-5xl sm:text-6xl md:text-7xl" />

        <motion.p
          {...rise(0.7)}
          className="mt-6 text-lg font-medium sm:text-xl"
          style={{ color: "var(--mec-ink-primary)" }}
        >
          Cardiovascular risk monitoring for the MEC-AI wearable cuff.
        </motion.p>

        <motion.p
          {...rise(0.8)}
          className="mt-3 max-w-xl text-sm leading-relaxed sm:text-base"
          style={{ color: "var(--mec-ink-secondary)" }}
        >
          Live vitals from the wrist, a ten-year screening score computed on the
          device, and acute alerts that fire with or without a network.
        </motion.p>

        <motion.div {...rise(0.95)} className="mt-10 flex flex-wrap items-center justify-center gap-3">
          <Link
            href="/dashboard"
            className="group inline-flex items-center justify-center gap-2 rounded-full px-8 py-3.5 text-sm font-semibold tracking-wide transition-all duration-300 hover:shadow-lg active:scale-95"
            style={{
              // Near-black ink on the data blue: white on #3987E5 measures 3.64,
              // under AA for a label this size. The page ink measures 5.41.
              background: "var(--mec-s1)",
              color: "var(--mec-page)",
            }}
          >
            Get Started
            <ArrowRight
              size={16}
              aria-hidden
              className="transition-transform duration-300 group-hover:translate-x-0.5"
            />
          </Link>

          <a
            href="#capabilities"
            className="inline-flex items-center justify-center rounded-full border px-8 py-3.5 text-sm font-semibold tracking-wide transition-all duration-300 hover:bg-[var(--mec-elevated)] active:scale-95"
            style={{
              borderColor: "var(--mec-baseline)",
              color: "var(--mec-ink-primary)",
            }}
          >
            What it measures
          </a>
        </motion.div>

        <motion.ul
          {...rise(1.1)}
          id="capabilities"
          className="mt-14 grid w-full gap-3 sm:grid-cols-3"
        >
          {CAPABILITIES.map(({ icon: Icon, label, detail }) => (
            <li
              key={label}
              className="rounded-3xl border p-5 text-left backdrop-blur-sm transition-all duration-300 hover:shadow-md"
              style={{
                background: "color-mix(in srgb, var(--mec-card) 82%, transparent)",
                borderColor: "var(--mec-hairline)",
              }}
            >
              <Icon size={18} aria-hidden style={{ color: "var(--mec-s1)" }} />
              <p
                className="mt-3 text-sm font-semibold"
                style={{ color: "var(--mec-ink-primary)" }}
              >
                {label}
              </p>
              <p className="mt-1 text-xs" style={{ color: "var(--mec-ink-muted)" }}>
                {detail}
              </p>
            </li>
          ))}
        </motion.ul>

        {/* Stated here, not buried under a number. */}
        <motion.p
          {...rise(1.25)}
          className="mt-10 text-xs"
          style={{ color: "var(--mec-ink-muted)" }}
        >
          Screening indicator, not a diagnosis. Consult a physician.
        </motion.p>
      </div>
    </section>
  );
}
