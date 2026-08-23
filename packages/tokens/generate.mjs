#!/usr/bin/env node
/**
 * MEC-AI token generator.
 *
 * Reads packages/tokens/tokens.json (the single source of truth, mirroring
 * docs/design.md §3) and emits platform bindings:
 *
 *   apps/mobile/lib/design/tokens.dart   Flutter  (Color / TextStyle / Duration)
 *   apps/web/src/lib/tokens.ts           Next.js  (chart + motion values in JS)
 *   apps/web/src/app/tokens.css          Tailwind v4 @theme + light/dark scopes
 *
 * Run: node packages/tokens/generate.mjs
 *
 * Why this exists: Flutter and Tailwind will drift within a week if each keeps
 * its own hex values. The validated palette (see $meta.validation) must have
 * exactly one home, so a colour can't be "fixed" on one client only.
 */

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "../..");
const T = JSON.parse(readFileSync(resolve(HERE, "tokens.json"), "utf8"));

const BANNER = (syntax) => {
  const c = syntax === "css" ? ["/*", " *", " */"] : ["//", "//", "//"];
  return [
    `${c[0]} GENERATED FILE — DO NOT EDIT.`,
    `${c[1]} Source: packages/tokens/tokens.json  (spec: docs/design.md §3)`,
    `${c[1]} Regenerate: node packages/tokens/generate.mjs`,
    `${c[2]}`,
    "",
  ].join("\n");
};

const write = (rel, body) => {
  const abs = resolve(ROOT, rel);
  mkdirSync(dirname(abs), { recursive: true });
  writeFileSync(abs, body);
  console.log(`  ✓ ${rel}`);
};

/** "#0ca30c" | "rgba(255,255,255,0.10)"  ->  Dart 0xAARRGGBB literal */
function toDartColor(v) {
  const rgba = v.match(/^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)$/);
  if (rgba) {
    const [, r, g, b, a = "1"] = rgba;
    const A = Math.round(parseFloat(a) * 255);
    return `0x${[A, +r, +g, +b].map((n) => n.toString(16).padStart(2, "0").toUpperCase()).join("")}`;
  }
  const hex = v.replace("#", "");
  if (hex.length !== 6) throw new Error(`Unsupported colour value: ${v}`);
  return `0xFF${hex.toUpperCase()}`;
}

const camel = (s) => s.replace(/[-_](.)/g, (_, c) => c.toUpperCase());
const pascal = (s) => s.charAt(0).toUpperCase() + s.slice(1);

/** Drops the `$`-prefixed annotation keys the token file uses for notes and rules. */
const noMeta = (o) => Object.entries(o).filter(([k]) => !k.startsWith("$"));

/**
 * The shape scale, then its semantic aliases — flattened, in that order.
 *
 * `radius.$semantic` is nested in the token file so the scale reads as a scale,
 * but every binding wants one flat map (`--radius-card`, `MecRadius.card`).
 */
const RADIUS_SCALE = noMeta(T.radius);
const RADIUS_SEMANTIC = Object.entries(T.radius.$semantic ?? {});
const RADIUS = Object.fromEntries([...RADIUS_SCALE, ...RADIUS_SEMANTIC]);

/** "cubic-bezier(0.2, 0, 0, 1)" -> "Cubic(0.2, 0.0, 0.0, 1.0)" */
function toDartCubic(v) {
  const m = v.match(/^cubic-bezier\(([^)]+)\)$/);
  if (!m) throw new Error(`Unsupported easing value: ${v}`);
  const pts = m[1].split(",").map((n) => asDouble(parseFloat(n.trim())));
  if (pts.length !== 4) throw new Error(`Easing needs 4 control points: ${v}`);
  return `Cubic(${pts.join(", ")})`;
}

/** SCREAMING_SNAKE from camelCase, for Python constants. */
const screaming = (s) => s.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toUpperCase();

/** Dart and Python both want an explicit decimal so these stay doubles/floats. */
const asDouble = (n) => (Number.isInteger(n) ? `${n}.0` : `${n}`);

/* ────────────────────────────── Dart ────────────────────────────── */

function dart() {
  const L = [];
  L.push(BANNER("dart"));
  L.push("import 'package:flutter/widgets.dart';", "");

  // Surfaces — one class per mode so ThemeExtension can swap wholesale.
  for (const mode of ["dark", "light"]) {
    const cls = `MecSurface${mode[0].toUpperCase()}${mode.slice(1)}`;
    L.push(`/// ${mode[0].toUpperCase() + mode.slice(1)}-mode surfaces and ink.`);
    L.push(`abstract final class ${cls} {`);
    for (const [k, v] of Object.entries(T.surface[mode])) {
      L.push(`  static const Color ${camel(k)} = Color(${toDartColor(v)});`);
    }
    L.push("}", "");
  }

  // Risk bands — the redundant-channel contract lives here as a record so a
  // caller physically cannot render a band without its word and icon.
  L.push("/// A risk band carries FOUR redundant channels (docs/design.md §4):");
  L.push("/// word + icon + arc length + colour. Colour is never load-bearing alone —");
  L.push("/// low↔high measures ΔE 4.1 under deuteranopia (validator FAIL).");
  L.push("enum MecRiskBand {");
  const bands = Object.entries(T.risk);
  bands.forEach(([key, b], i) => {
    const end = i === bands.length - 1 ? ";" : ",";
    L.push(`  ${camel(key)}(`);
    L.push(`    color: Color(${toDartColor(b.hex)}),`);
    L.push(`    label: ${JSON.stringify(b.label)},`);
    L.push(`    iconName: ${JSON.stringify(b.icon)},`);
    L.push(`  )${end}`);
  });
  L.push("");
  L.push("  const MecRiskBand({");
  L.push("    required this.color,");
  L.push("    required this.label,");
  L.push("    required this.iconName,");
  L.push("  });");
  L.push("");
  L.push("  final Color color;");
  L.push("  final String label;");
  L.push("  final String iconName;");
  L.push("}", "");

  L.push("/// Acute SOS/alarm state. NOT a risk band — carried by motion + siren icon.");
  L.push(`abstract final class MecAlarm {`);
  L.push(`  static const Color color = Color(${toDartColor(T.alarm.hex)});`);
  L.push("}", "");

  // Series
  L.push("/// Categorical series slots. Blue = data; status colours = risk. Never mix.");
  L.push("abstract final class MecSeries {");
  for (const [slot, v] of noMeta(T.series)) {
    L.push(`  /// ${v.use}`);
    L.push(`  static const Color ${slot}Dark = Color(${toDartColor(v.dark)});`);
    L.push(`  static const Color ${slot}Light = Color(${toDartColor(v.light)});`);
  }
  L.push("}", "");

  // Sequential ramp
  L.push("/// Single-hue sequential ramp, light→dark. Never a rainbow.");
  L.push("abstract final class MecSequential {");
  L.push("  static const List<Color> blue = <Color>[");
  for (const c of T.sequential.blue) L.push(`    Color(${toDartColor(c)}),`);
  L.push("  ];");
  L.push("}", "");

  // Clinical thresholds
  L.push("/// Reference lines drawn on trend charts. Muted hairlines, never dashed,");
  L.push("/// never in a series colour (docs/design.md §8).");
  L.push("abstract final class MecChartReference {");
  L.push(`  static const double spo2Min = ${T.threshold.chartReference.spo2Min.value};`);
  L.push(`  static const double tempNormalMin = ${T.threshold.chartReference.tempNormal.min};`);
  L.push(`  static const double tempNormalMax = ${T.threshold.chartReference.tempNormal.max};`);
  L.push(`  static const double bpRefSystolic = ${T.threshold.chartReference.bpRef.systolic};`);
  L.push(
    `  static const double bpRefDiastolic = ${T.threshold.chartReference.bpRef.diastolic};`,
  );
  L.push(`  static const double hrNormalMin = ${T.threshold.chartReference.hrNormal.min};`);
  L.push(`  static const double hrNormalMax = ${T.threshold.chartReference.hrNormal.max};`);
  L.push("}", "");

  // Alert cut-points — the safety-critical ones.
  L.push("/// Clinical alert cut-points, shared byte-for-byte with the Python service.");
  L.push("///");
  L.push("/// These exist on the client because an alert must fire without a network:");
  L.push("/// an SpO2 of 88% is an emergency whether or not the phone has signal. The");
  L.push("/// ten-year risk score still requires the server (that is where the model");
  L.push("/// lives), but immediate danger does not.");
  L.push("abstract final class MecAlert {");
  for (const [group, values] of Object.entries(T.threshold.alert)) {
    if (group.startsWith("$")) continue;
    for (const [key, value] of Object.entries(values)) {
      if (key.startsWith("$")) continue;
      L.push(`  static const double ${camel(group)}${pascal(key)} = ${asDouble(value)};`);
    }
  }
  L.push("}", "");

  // Plausibility bounds.
  L.push("/// Physiological-plausibility bounds. A reading outside these is a sensor");
  L.push("/// fault, rejected rather than displayed.");
  L.push("abstract final class MecPlausible {");
  for (const [vital, range] of Object.entries(T.threshold.plausible)) {
    if (vital.startsWith("$")) continue;
    L.push(`  static const double ${camel(vital)}Min = ${asDouble(range.min)};`);
    L.push(`  static const double ${camel(vital)}Max = ${asDouble(range.max)};`);
  }
  L.push("}", "");

  // Space + radius
  L.push("abstract final class MecSpace {");
  T.space.forEach((n) => L.push(`  static const double s${n} = ${n};`));
  L.push("}", "");
  L.push("abstract final class MecRadius {");
  for (const [k, v] of RADIUS_SCALE) {
    L.push(`  static const double ${camel(k)} = ${v};`);
  }
  if (RADIUS_SEMANTIC.length) {
    L.push("");
    L.push("  // Semantic mappings");
    for (const [k, v] of RADIUS_SEMANTIC) {
      L.push(`  static const double ${camel(k)} = ${v};`);
    }
  }
  L.push("}", "");

  // Easing — Material You's curves, as Flutter Curve constants.
  L.push("/// Material You (MD3) easing curves.");
  L.push("abstract final class MecEasing {");
  for (const [k, v] of noMeta(T.easing)) {
    L.push(`  /// ${v.use}`);
    L.push(`  static const Curve ${camel(k)} = ${toDartCubic(v.curve)};`);
  }
  L.push("}", "");

  // Motion
  L.push("/// Motion tokens. Every ambient/looping animation MUST be gated on");
  L.push("/// MediaQuery.disableAnimationsOf(context) — a pulsing red alert is a");
  L.push("/// vestibular hazard for someone who may be having a cardiac event.");
  L.push("abstract final class MecMotion {");
  for (const [k, v] of Object.entries(T.motion)) {
    if (k.startsWith("$")) continue;
    L.push(`  /// ${v.use}`);
    L.push(`  static const Duration ${camel(k)} = Duration(milliseconds: ${v.ms});`);
  }
  L.push("}", "");

  // State layers — MD3 models interaction as an opacity overlay, not a hue swap.
  L.push("/// MD3 state-layer opacities.");
  L.push("///");
  L.push(`/// ${T.state.$rule}`);
  L.push("abstract final class MecState {");
  for (const [k, v] of noMeta(T.state)) {
    L.push(`  static const double ${camel(k)} = ${v};`);
  }
  L.push("}", "");

  // Elevation — two shadows, for floating surfaces only.
  L.push("/// Drop shadows for genuinely floating surfaces.");
  L.push("///");
  L.push(`/// ${T.elevation.$rule}`);
  L.push("abstract final class MecElevation {");
  for (const [k, v] of noMeta(T.elevation)) {
    L.push(`  /// ${v.use}`);
    L.push(`  static const List<BoxShadow> ${camel(k)} = <BoxShadow>[`);
    L.push(`    BoxShadow(`);
    L.push(`      color: Color(${toDartColor(v.color)}),`);
    L.push(`      blurRadius: ${asDouble(v.blur)},`);
    L.push(`      offset: Offset(0, ${asDouble(v.y)}),`);
    L.push(`    ),`);
    L.push(`  ];`);
  }
  L.push("}", "");

  // Type scale
  L.push("/// Type scale. tabularFigures is true for axis ticks and table cells ONLY —");
  L.push("/// equal-width digits make a hero figure like 121 look loose.");
  L.push("abstract final class MecType {");
  L.push(`  static const String family = ${JSON.stringify(T.type.family)};`);
  L.push("");
  for (const [k, v] of Object.entries(T.type.scale)) {
    L.push(`  static const TextStyle ${camel(k)} = TextStyle(`);
    L.push(`    fontFamily: family,`);
    L.push(`    fontSize: ${v.size},`);
    L.push(`    fontWeight: FontWeight.w${v.weight},`);
    if (v.tabular) {
      L.push(`    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],`);
    }
    L.push(`  );`);
  }
  L.push("}", "");

  // Chart specs
  L.push("/// Chart mark specs (docs/design.md §8). Hard rule: no dual-axis charts.");
  L.push("abstract final class MecChart {");
  for (const [k, v] of Object.entries(T.chart)) {
    if (k.startsWith("$")) continue;
    if (typeof v === "number") L.push(`  static const double ${camel(k)} = ${v};`);
  }
  L.push("}", "");

  return L.join("\n");
}

/* ─────────────────────────────── TS ─────────────────────────────── */

function ts() {
  const strip = (o) =>
    JSON.parse(JSON.stringify(o), (k, v) => (k.startsWith("$") ? undefined : v));

  return (
    BANNER("ts") +
    [
      "export const surface = " + JSON.stringify(T.surface, null, 2) + " as const;",
      "",
      "/** Risk bands carry word + icon + arc length + colour. Colour is never alone:",
      "  * low↔high measures ΔE 4.1 under deuteranopia. See docs/design.md §4. */",
      "export const risk = " + JSON.stringify(strip(T.risk), null, 2) + " as const;",
      "",
      "export const alarm = " + JSON.stringify(strip(T.alarm), null, 2) + " as const;",
      "export const series = " + JSON.stringify(strip(T.series), null, 2) + " as const;",
      "export const sequential = " + JSON.stringify(T.sequential, null, 2) + " as const;",
      "export const threshold = " + JSON.stringify(T.threshold, null, 2) + " as const;",
      "export const type = " + JSON.stringify(T.type, null, 2) + " as const;",
      "export const space = " + JSON.stringify(T.space) + " as const;",
      "export const radius = " + JSON.stringify(RADIUS, null, 2) + " as const;",
      "export const easing = " + JSON.stringify(strip(T.easing), null, 2) + " as const;",
      "export const state = " + JSON.stringify(strip(T.state), null, 2) + " as const;",
      "export const elevation = " + JSON.stringify(strip(T.elevation), null, 2) + " as const;",
      "export const motion = " + JSON.stringify(strip(T.motion), null, 2) + " as const;",
      "export const chart = " + JSON.stringify(strip(T.chart), null, 2) + " as const;",
      "",
      "export type RiskBandKey = keyof typeof risk;",
      "",
    ].join("\n")
  );
}

/* ─────────────────────────────── CSS ────────────────────────────── */

function css() {
  const L = [];
  L.push(BANNER("css"));
  L.push('@import "tailwindcss";', "");

  // Tailwind v4 is CSS-first: @theme registers the tokens as utility classes
  // (bg-card, text-ink-muted, rounded-card, …). Values indirect through
  // custom properties so the light/dark scopes below swap them in one place.
  L.push("@theme {");
  for (const k of Object.keys(T.surface.dark)) {
    const name = k.replace(/([A-Z])/g, "-$1").toLowerCase();
    L.push(`  --color-${name}: var(--mec-${name});`);
  }
  for (const k of Object.keys(T.risk)) L.push(`  --color-risk-${k}: var(--mec-risk-${k});`);
  L.push(`  --color-alarm: var(--mec-alarm);`);
  for (const [k] of noMeta(T.series)) L.push(`  --color-${k}: var(--mec-${k});`);
  L.push("");
  for (const [k, v] of Object.entries(RADIUS)) L.push(`  --radius-${k}: ${v}px;`);
  L.push("");
  for (const [k, v] of noMeta(T.easing)) L.push(`  --ease-${k}: ${v.curve};`);
  L.push("");
  for (const [k, v] of Object.entries(T.motion)) {
    if (k.startsWith("$")) continue;
    L.push(`  --ease-${k}: ${v.easing};`);
  }
  L.push("");
  for (const [k, v] of noMeta(T.state)) L.push(`  --state-${k}: ${v};`);
  L.push("");
  L.push(`  --font-sans: "${T.type.family}", ${T.type.fallback};`);
  L.push("}", "");

  const vars = (mode) => {
    const out = [];
    for (const [k, v] of Object.entries(T.surface[mode])) {
      out.push(`  --mec-${k.replace(/([A-Z])/g, "-$1").toLowerCase()}: ${v};`);
    }
    for (const [k, b] of Object.entries(T.risk)) out.push(`  --mec-risk-${k}: ${b.hex};`);
    out.push(`  --mec-alarm: ${T.alarm.hex};`);
    for (const [k, s] of noMeta(T.series)) out.push(`  --mec-${k}: ${s[mode]};`);
    for (const [k, m] of Object.entries(T.motion)) {
      if (k.startsWith("$")) continue;
      out.push(`  --mec-dur-${k}: ${m.ms}ms;`);
    }
    return out.join("\n");
  };

  // Dark is the DEFAULT (docs/design.md §2): the Moderate amber only clears
  // contrast on a dark surface (1.79 light vs 9.49 dark).
  L.push("/* Dark is the default — see docs/design.md §2 and §3.2. */");
  L.push(":root {", "  color-scheme: dark;", vars("dark"), "}", "");

  // Light must win under both the OS setting and an explicit toggle.
  L.push(':root[data-theme="light"] {', "  color-scheme: light;", vars("light"), "}", "");
  L.push("@media (prefers-color-scheme: light) {");
  L.push('  :root:where(:not([data-theme="dark"])) {');
  L.push("    color-scheme: light;");
  L.push(
    vars("light")
      .split("\n")
      .map((l) => "  " + l)
      .join("\n"),
  );
  L.push("  }", "}", "");

  L.push("@layer base {");
  L.push("  body {");
  L.push("    background: var(--mec-page);");
  L.push("    color: var(--mec-ink-primary);");
  L.push("    font-family: var(--font-sans);");
  L.push("  }");
  L.push("  /* Axis ticks and table cells only — never a hero figure. */");
  L.push("  .tabular { font-variant-numeric: tabular-nums; }");
  L.push("}", "");

  L.push("/* Hard requirement, not a nicety: docs/design.md §3.6. */");
  L.push("@media (prefers-reduced-motion: reduce) {");
  L.push("  *, *::before, *::after {");
  L.push("    animation-duration: 0.01ms !important;");
  L.push("    animation-iteration-count: 1 !important;");
  L.push("    transition-duration: 0.01ms !important;");
  L.push("    scroll-behavior: auto !important;");
  L.push("  }");
  L.push("}", "");

  return L.join("\n");
}

/* ───────────────────────────── Python ───────────────────────────── */

function python() {
  const L = [];
  L.push('"""Alert cut-points and plausibility bounds.');
  L.push("");
  L.push("GENERATED FILE — DO NOT EDIT.");
  L.push("Source: packages/tokens/tokens.json  (spec: docs/design.md §3)");
  L.push("Regenerate: node packages/tokens/generate.mjs");
  L.push("");
  L.push("These are shared with the Flutter client, which evaluates alerts locally so");
  L.push("an SpO2 of 88% raises an emergency without a network. Two hand-maintained");
  L.push('copies would drift, and "is this dangerous" would have two answers.');
  L.push('"""');
  L.push("");
  L.push("# ── alert cut-points ──");
  for (const [group, values] of Object.entries(T.threshold.alert)) {
    if (group.startsWith("$")) continue;
    for (const [key, value] of Object.entries(values)) {
      if (key.startsWith("$")) continue;
      L.push(`${screaming(group)}_${screaming(key)} = ${asDouble(value)}`);
    }
  }
  L.push("");
  L.push("# ── plausibility bounds ──");
  for (const [vital, range] of Object.entries(T.threshold.plausible)) {
    if (vital.startsWith("$")) continue;
    L.push(`PLAUSIBLE_${screaming(vital)}_MIN = ${asDouble(range.min)}`);
    L.push(`PLAUSIBLE_${screaming(vital)}_MAX = ${asDouble(range.max)}`);
  }
  L.push("");
  return L.join("\n");
}

/* ────────────────────── conformance fixtures ────────────────────── */

/**
 * Cross-language conformance vectors for acute-flag evaluation.
 *
 * The Dart and Python evaluators are separate implementations of the same rules,
 * which is a drift risk. This file is the reference contract both are tested
 * against: input vitals in, expected severity out. The comparisons below ARE the
 * specification — if they and an implementation disagree, the implementation is
 * wrong.
 *
 * Cases are derived from the thresholds rather than hand-written, so moving a
 * cut-point in tokens.json moves its boundary cases with it instead of leaving a
 * stale fixture that still passes.
 */
function conformance() {
  const a = T.threshold.alert;
  const cases = [];

  // Fixed so the fixture is byte-stable across regenerations, and so both sides
  // can feed `reading` straight into their JSON deserializer. Keys are the API's
  // snake_case wire format for the same reason.
  const measuredAt = "2026-08-18T09:00:00Z";

  const add = (id, reading, vital, severity) =>
    cases.push({
      id,
      reading: { ...reading, measured_at: measuredAt },
      expect: severity === null ? null : { vital, severity },
    });

  // ── SpO2: critical below `critical`, warning below `warning` ──
  const spo2 = a.spo2;
  for (const [value, severity] of [
    [spo2.critical - 1, "critical"],
    [spo2.critical, "warning"], // at the critical cut-point it is not yet critical
    [spo2.warning - 0.1, "warning"],
    [spo2.warning, null], // at the warning cut-point it is normal
    [spo2.warning + 3, null],
  ]) {
    add(`spo2/${value}`, { spo2_pct: value }, "SpO2", severity);
  }

  // ── Heart rate: inclusive at both critical and warning bounds ──
  const hr = a.heartRate;
  for (const [value, severity] of [
    [hr.lowCritical - 1, "critical"],
    [hr.lowCritical, "critical"],
    [hr.lowCritical + 5, "warning"],
    [hr.lowWarning, "warning"],
    [hr.lowWarning + 5, null],
    [(hr.normalMin + hr.normalMax) / 2, null],
    [hr.highWarning - 1, null],
    [hr.highWarning, "warning"],
    [hr.highCritical - 1, "warning"],
    [hr.highCritical, "critical"],
  ]) {
    add(`heartRate/${value}`, { heart_rate_bpm: value }, "Heart rate", severity);
  }

  // ── Body temperature: hypothermia, sub-normal info, fever tiers ──
  const t = a.temperature;
  for (const [value, severity] of [
    [t.hypothermiaCritical - 0.5, "critical"],
    [t.hypothermiaCritical, "critical"],
    [t.hypothermiaCritical + 0.5, "info"],
    [t.normalMin - 0.1, "info"],
    [t.normalMin, null],
    [(t.normalMin + t.normalMax) / 2, null],
    [t.feverWarning - 0.1, null],
    [t.feverWarning, "warning"],
    [t.feverCritical - 0.1, "warning"],
    [t.feverCritical, "critical"],
  ]) {
    const rounded = Number(value.toFixed(1));
    add(`temperature/${rounded}`, { temperature_c: rounded }, "Temperature", severity);
  }

  // ── Blood pressure: a stage fires when EITHER half reaches its cut-point ──
  const bp = a.bloodPressure;
  for (const [sys, dia, severity, note] of [
    [118, 76, null, "normal"],
    [bp.stage1Systolic, bp.stage1Diastolic, "info", "stage1-both"],
    [bp.stage1Systolic + 2, 78, "info", "stage1-systolic-only"],
    [118, bp.stage1Diastolic, "info", "stage1-diastolic-only"],
    [bp.stage2Systolic, bp.stage2Diastolic, "warning", "stage2-both"],
    [bp.stage2Systolic + 5, 85, "warning", "stage2-systolic-only"],
    [125, bp.stage2Diastolic, "warning", "stage2-diastolic-only"],
    [bp.crisisSystolic, bp.crisisDiastolic, "critical", "crisis-both"],
    [bp.crisisSystolic + 5, 95, "critical", "crisis-systolic-only"],
    [140, bp.crisisDiastolic, "critical", "crisis-diastolic-only"],
  ]) {
    add(
      `bloodPressure/${note}`,
      { systolic_mmhg: sys, diastolic_mmhg: dia },
      "Blood pressure",
      severity,
    );
  }

  // ── A lone systolic cannot be staged ──
  add(
    "bloodPressure/systolic-only-unstageable",
    { systolic_mmhg: bp.crisisSystolic + 5 },
    "Blood pressure",
    null,
  );

  // ── Ambient temperature never produces a clinical flag ──
  // The firmware's SHT30x reads enclosure air. Routing it to body temperature
  // would fire hypothermia in an air-conditioned room.
  for (const value of [18, 24, 28, 34, 41]) {
    add(`ambient/${value}`, { ambient_temp_c: value }, "Temperature", null);
  }

  return JSON.stringify(
    {
      $generated:
        "GENERATED — DO NOT EDIT. Source: packages/tokens/tokens.json. " +
        "Regenerate: node packages/tokens/generate.mjs",
      $purpose:
        "Cross-language conformance vectors. The Dart and Python acute-flag " +
        "evaluators must both satisfy every case. expect=null means no flag for " +
        "that vital. `reading` uses the API's snake_case wire format.",
      cases,
    },
    null,
    2,
  );
}

/* ───────────────────────────── emit ─────────────────────────────── */

console.log("MEC-AI tokens → generating");
write("apps/mobile/lib/design/tokens.dart", dart());
write("apps/web/src/lib/tokens.ts", ts());
write("apps/web/src/app/tokens.css", css());
write("services/api/src/mecai_api/generated_thresholds.py", python());
write("packages/tokens/alert-conformance.json", conformance());
console.log("\nDone. Reminder: if any palette hex changed, re-run the colour validator");
console.log("before shipping (see tokens.json $meta.validation.rule).");
