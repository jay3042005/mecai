# MEC-AI — Design System & UI Specification

Design spec for the MEC-AI cardiovascular-risk wearable platform.
Scope: what to build, the visual/motion system, and screen-level specs.

---

## 1. What to build

**Three surfaces, one design language.**

| # | Surface | Stack | Why it exists |
|---|---|---|---|
| 1 | **Mobile app** (primary) | Expo / React Native + NativeWind + Reanimated | Non-negotiable. Only surface that gets **BLE**, **background GPS**, **push**, and a **lock-screen SOS**. The spec's SOS + GPS requirement can only live here. |
| 2 | **Web dashboard** (secondary) | Next.js + Tailwind + shadcn/ui + Magic UI | Guardian/clinician multi-patient view, admin, and the panel-defense demo. Read-mostly. Where the 21st.dev components drop in verbatim. |
| 3 | **API + AI service** | FastAPI + MQTT broker + Postgres/TimescaleDB | Hosts the Python AI requirement. MQTT terminates the ESP32 Wi-Fi path; REST/WS serves both clients. |

### Why not desktop
A desktop app fails the core use case: the SOS button must be on the body, and a
laptop isn't. Desktop earns exactly one small tool — a **Python serial/BLE logger
script** (`scripts/`) for capturing raw sensor data during calibration against a
reference BP monitor. That's a script, not a product surface.

### Why not web-only
`Web Bluetooth` does not exist in iOS Safari, requires a user gesture per connect,
and dies when the tab backgrounds. Browser geolocation has no reliable background
mode. A web-only MEC-AI cannot deliver SOS.

### Why Expo over Flutter
One language (TypeScript) across mobile + web + API contracts, one Tailwind token
set via NativeWind, and 21st.dev/Magic UI components port by pattern. Flutter's BLE
stack is marginally more stable — if BLE reliability becomes the dominant risk,
that's the swap, and only §1 and §9 of this doc change.

> **Known friction:** `react-native-ble-plx` requires an Expo **custom dev client**
> (not Expo Go). Budget half a day for the first EAS build.

---

## 2. Design direction — "Clinical Calm"

Health apps fail in two directions: consumer-fitness loudness (undermines trust) or
hospital-software coldness (frightens users). MEC-AI sits between.

**Five principles**

1. **Dark-first.** Reduces glare for night/bedside readings, and the amber
   "Moderate" token only clears contrast on a dark surface (§3).
2. **Data is the only loud thing.** Recessive chrome, hairline grids, generous air.
   No gradient fills behind numbers.
3. **Motion means liveness or change — never decoration.** A pulse means a heart
   beat or a live link. Nothing animates just to look modern.
4. **Risk is never color-alone.** Enforced by measurement, not taste (§4).
5. **Never gamify a medical result.** No confetti, no streaks, no badges on a
   reading. A high-risk result is not an achievement.

---

## 3. Design tokens

### 3.1 Surfaces & ink

| Role | Dark (default) | Light |
|---|---|---|
| Page plane | `#0d0d0d` | `#f9f9f7` |
| Card surface | `#1a1a19` | `#fcfcfb` |
| Elevated / sheet | `#242422` | `#ffffff` |
| Primary ink | `#ffffff` | `#0b0b0b` |
| Secondary ink | `#c3c2b7` | `#52514e` |
| Muted (axis, labels) | `#898781` | `#898781` |
| Gridline (hairline) | `#2c2c2a` | `#e1e0d9` |
| Baseline / axis | `#383835` | `#c3c2b7` |
| Hairline ring | `rgba(255,255,255,0.10)` | `rgba(11,11,11,0.10)` |

Warm-neutral dark, deliberately — not blue-black. Cool blue-black reads as "hospital
IT system." These are the surfaces the palette below was **validated against**; if
you change them, re-run the validator.

### 3.2 Risk band tokens (status — reserved, never themed)

| Band | Token | Hex | Dark contrast | Icon (shape channel) |
|---|---|---|---|---|
| Low | `--risk-low` | `#0ca30c` | 5.19 | `shield-check` |
| Moderate | `--risk-mod` | `#fab219` | 9.49 | `alert-triangle` |
| High | `--risk-high` | `#d03b3b` | 3.62 | `alert-octagon` |
| Acute event (SOS/alarm — *not* a risk band) | `--alarm` | `#d03b3b` + motion | — | `siren` |

**Measured, not assumed** (`validate_palette.js`, all-pairs, both modes):

```
3-band risk — normal vision    ΔE 27.6  PASS
3-band risk — deuteranopia     ΔE  4.1  FAIL  ← #d03b3b ↔ #0ca30c
#fab219 lightness band                  FAIL  (L 0.811, above band)
#fab219 light-surface contrast    1.79  WARN  (passes 9.49 on dark)
```

**This is the most important finding in this document.** Red↔green at ΔE 4.1 means a
deuteranopic reader — roughly 8% of men — literally cannot distinguish *Low risk*
from *High risk* by color. In a cardiovascular app that is a safety defect, not a
polish issue. §4 makes the redundant channels mandatory.

Also why the app is dark-first: `#fab219` is sub-3:1 on light (1.79) and only becomes
safe on the dark surface (9.49).

### 3.3 Series tokens (categorical — vitals charts)

| Slot | Use | Dark | Light |
|---|---|---|---|
| 1 | Systolic; all single-series vitals | `#3987e5` | `#2a78d6` |
| 2 | Diastolic | `#9ec5f4` | `#104281` |

```
BP series (blue ↔ blue, by lightness) — PASS, both modes
  normal ΔE 36.5 dark / 26.6 light   ·   deuteranopia ΔE 40.6 / 28.2
```

Slot 2 was orange (`#d95926` / `#eb6834`). It is now a **second tone of the one data
hue**, drawn from the `sequential.blue` ramp so no new value enters the system. Two
reasons: systolic and diastolic are two bounds of a single quantity, so a single-hue
pair is the more honest encoding; and it keeps the product palette to blue, green,
red and white. It also measures *better* — separating by lightness rather than hue
survives colour-blind vision, which is why the deuteranopia figures here exceed the
normal-vision ones.

> **Note on these numbers.** `tokens.json:$meta.validation.tool` points at
> `dataviz/scripts/validate_palette.js`, which is **not in the repo**. The figures
> above were computed independently (CIE76 ΔE over a Viénot–Brettel deuteranopia
> simulation), so they are not directly comparable to the historical values recorded
> in `$meta` — a different simulation matrix gives different magnitudes. The
> qualitative verdicts agree. Restoring the validator is outstanding work.

Two slots is the whole categorical budget. **Blue = data. Status colors = risk.**
A vital never wears a risk color and a risk band never wears a series color.

Sequential ramp (heatmaps — e.g. readings by hour-of-day): single blue hue,
`#cde2fb → #0d366b`, light→dark. Never a rainbow.

### 3.4 Type

`Inter Variable`, system-ui fallback. No display or serif face anywhere — including
the hero risk figure.

| Role | Size / weight | Notes |
|---|---|---|
| Hero risk figure | 64 / 600 | Exactly one per view. **Proportional figures** — never `tabular-nums` (makes `121` look loose). |
| Stat-tile value | 28 / 600 | Proportional. |
| Section title | 18 / 600 | |
| Body | 15 / 400 | |
| Label / caption | 13 / 500 | Sentence case, no trailing colon. |
| Axis tick / table cell | 12 / 400 | **`tabular-nums` here only.** |

### 3.5 Space, radius, elevation

4pt base grid: `2 · 4 · 6 · 8 · 12 · 16 · 20 · 24 · 32 · 48 · 64`.

**Radius — the Material You shape scale.** This supersedes the earlier card-`12` /
control-`8` pairing, which read as MD2 and is gone from the tokens:

| Step | Value | Used for |
|---|---|---|
| `xs` | `8` | Chips-in-chips, code blocks |
| `sm` | `12` | Text-field top corners, small surfaces |
| `md` | `16` | FABs |
| `lg` | `24` | **Cards** (`radius.card`) |
| `xl` | `28` | Bottom sheets, dialogs |
| `xxl` | `32` | Nested feature containers |
| `hero` | `48` | The risk-ring container, major sections |
| `pill` | `999` | **All** buttons, chips, badges (`radius.control`, `radius.chip`) |

Every button is a pill — that one trait carries more Material You recognition than
anything else in the system. Cards are generously rounded because it is
architectural, not ornamental: the radius shapes the whole page.

Elevation is a **hairline ring + surface step**, not a drop shadow. `elevation`
holds the two exceptions, both for genuinely floating surfaces: `raised`
(`0 2px 8px rgba(0,0,0,.32)` — FAB, snackbar) and `floating`
(`0 8px 32px rgba(0,0,0,.48)` — bottom sheet, dialog, SOS hero). A card at rest
never takes either.

### 3.6 Motion tokens

| Token | Duration | Easing | Use |
|---|---|---|---|
| `--m-instant` | 120ms | `ease-out` | Press feedback, toggles |
| `--m-fast` | 220ms | `cubic-bezier(.2,.8,.2,1)` | Cards, sheets, tab change |
| `--m-value` | 900ms | `ease-out` | Number roll-up, ring fill |
| `--m-ambient` | 1600ms | `ease-in-out` | Heartbeat pulse, live link |
| `--m-stagger` | 60ms | — | Per-item delay in lists/grids |

**Easing — the Material You curves.** `--m-*` above keep their per-token easing for
CSS transitions; these three are the MD3 set every state, shape and position change
uses (`MecEasing` in Flutter, `--ease-*` in CSS):

| Token | Curve | Use |
|---|---|---|
| `standard` | `cubic-bezier(.2,0,0,1)` | MD3 Emphasized. The default. |
| `decelerate` | `cubic-bezier(.05,.7,.1,1)` | Elements entering the screen |
| `accelerate` | `cubic-bezier(.3,0,.8,.15)` | Elements leaving the screen |

**State layers.** MD3 models interaction as an opacity overlay in the *foreground*
colour, never a hue change: `hover .08` · `focus .10` · `press .12` · `drag .16` ·
`disabled .38` (`state.*`). A pressed blue button is the same blue with ink over it,
not a second blue. Reserved status colours keep their hue and take the same overlay.

**`prefers-reduced-motion: reduce` is a hard requirement, not a nicety.** All
ambient/looping motion stops; numbers snap to final value; ring fills without
sweeping. A pulsing red full-screen alert is a vestibular hazard and is exactly the
wrong thing to show someone who may be having a cardiac event.

Concretely, on mobile: the boot sequence skips its burst, strobe and sparkles and
arrives on the settled wordmark; the pairing radar stops and the checklist carries
the state; the SOS siren stops throbbing (its **haptic** cadence continues — reduced
motion asks about visual movement, not about being told less loudly that an ambulance
is coming); skeleton shimmer is dropped; press-scale and staggered entrances are
skipped. `test/motion_test.dart` holds this.

---

## 4. The risk indicator (centerpiece)

The one component that must not be gotten wrong. It carries **four redundant
channels** so it survives colorblindness, grayscale print, and forced-colors:

1. **Word** — `Low` / `Moderate` / `High`, always visible, never truncated. Primary channel.
2. **Icon** — distinct silhouette per band (§3.2). Shape, independent of hue.
3. **Arc length** — the ring fills proportionally. Position/length, readable at zero color.
4. **Color** — the status token. *Last*, and never load-bearing alone.

### Anatomy

```
        ╭───────────────╮
      ╱   ▲  MODERATE    ╲      ← icon + word, 18/600, inside the ring
     │        42%          │    ← hero figure 64/600, proportional
     │   10-yr est. risk   │    ← 13/500 muted — the number's MEANING
      ╲   ● 3 factors     ╱     ← tappable → risk-factor breakdown
        ╰───────────────╯
     Screening indicator · not a diagnosis   ← 12/400 muted, persistent
```

### Non-negotiable label rules

- **Never show a bare `%`.** Always `42% · 10-yr estimated risk`. An unlabeled
  percentage reads as "42% chance I'm having a heart attack now," which is a
  different and terrifying claim.
- **Band is primary, number is secondary.** Larger word weight than the reader
  expects; the number supports it.
- **Persistent disclaimer.** Not a dismissible toast — permanent caption.
- **Show the inputs.** Tapping "3 factors" lists what drove the score, including
  which came from the device vs. the profile questionnaire. A risk score the user
  can't interrogate isn't trustworthy.

### Confidence state

When the profile questionnaire is incomplete (no cholesterol, smoking, or diabetes
status), the device alone cannot produce a validated risk figure. Render the ring
**hairline-dashed, ink-neutral, no band color**, with `Incomplete profile` and a CTA.
Never show a colored band from partial input.

---

## 5. Screens

### 5.1 Mobile

**Home / Live** — the default view.
- Risk ring (§4), centered, above the fold.
- Connection chip: `● Cuff connected · 2s ago`. Dot color is *link* state, not risk.
- 2×2 vital tiles: **BP** `118/76 mmHg` · **HR** `72 bpm` · **SpO₂** `98%` · **Temp** `36.8°C`.
  Each = label + value + 12-point sparkline + out-of-range icon. Stat tiles, **not**
  four bars in one chart.
- `Take a reading` primary button.
- Last-sync line; offline queue depth if > 0.

**Measure** — the cuff flow. Five states, one screen:
`Prepare → Inflating → Measuring → Releasing → Result`
- Live cuff-pressure curve, 60fps, single blue series, mmHg y-axis.
- Inflation shown as a **meter** (fill = current / target pressure), not a spinner.
- `Stay still` coaching copy; motion-artifact warning if accelerometer variance is high.
- Result animates in — number roll-up, then the ring re-fills to the new band.

**Trends** — history.
- One filter row above everything: `24h · 7d · 30d · 90d`. Never per-chart filters.
- **Small multiples, one chart per vital** — BP, HR, SpO₂, Temp stacked vertically.
  Four different units (mmHg / bpm / % / °C) means **four charts**, never one chart
  with multiple y-axes.
- BP chart is the only 2-series chart: systolic (slot 1) + diastolic (slot 2),
  legend present, both endpoints direct-labeled.
- Risk timeline: horizontal band strip, status tokens + band word on each segment.
- Every chart has a **table-view toggle**.

**Alerts** — reverse-chronological feed. Newest slides in at top. Each row: icon +
band + plain-language cause + timestamp + `What should I do?` expander carrying the
recommendation text.

**SOS** — see §6.

**Profile / Risk factors** — the questionnaire supplying what sensors can't measure:
age, sex, smoking, diabetes, cholesterol (if known), family history, medications.
Shows completeness as a meter, since §4's confidence state depends on it.

### 5.2 Web dashboard

- **Patient roster** — table, one row per patient, risk band chip (icon + word +
  color), last reading, sync state. Sortable. Rows with `High` do **not** get a red
  row background — that destroys text contrast; the chip carries it.
- **Patient detail** — same charts as mobile Trends at desk scale, plus raw-reading
  export (CSV) for the validation chapter.
- **Live wall** — optional demo view; large risk rings for connected devices.
- **Landing page** — the only place decorative motion is allowed (§7).

---

## 6. SOS — interaction spec

Safety-critical. The failure modes are *pocket-dial* and *no-signal*.

**Activation:** press-and-**hold 3s** with a filling ring around the button.
Tap alone never fires.

**Confirm:** 10s cancel countdown with a large `Cancel` target. Countdown is
haptic-per-second, not just visual.

**Dispatch:** parallel fan-out, each contact shown as its own row with live state:
`Queued → Sent → Delivered`. Never one global spinner — the user must see *who* was
reached.

**Fallback ladder** — the spec says "through an internet connection"; that is not
sufficient. Implement in order:

1. Push/API over Wi-Fi or cellular data
2. **SMS fallback** (Android `SmsManager`; server-side Twilio if data exists but the API is down)
3. **Queue + retry** with exponential backoff
4. **Manual escape hatch** — a pre-filled SMS/dialer intent the user can fire themselves

State 4 must be reachable in one tap from the SOS screen. Always show the coarse GPS
fix and its accuracy radius so the user knows what's being transmitted.

**Reachability:** Android foreground-service notification action + quick-settings
tile. SOS must not require unlocking and navigating the app.

---

## 7. Animation — 21st.dev / Magic UI mapping

21st.dev is a shadcn-registry index; the animation primitives here come from
**Magic UI**, its most relevant indexed library. Install:

```bash
pnpm dlx shadcn@latest add @magicui/<slug>
```

### Web dashboard — use directly

| Need | Component | Slug | Notes |
|---|---|---|---|
| Risk ring | Animated Circular Progress Bar | `animated-circular-progress-bar` | Props: `value`, `min`, `max`, `gaugePrimaryColor`, `gaugeSecondaryColor`. Feed status token as primary; `--gridline` as secondary. |
| Vital value roll-up | Number Ticker | `number-ticker` | `--m-value`. Must snap under reduced-motion. |
| Alert feed | Animated List | `animated-list` | Items enter as they arrive. |
| Card/screen entrance | Blur Fade | `blur-fade` | `--m-stagger` between tiles. |
| Live-link confirm | Border Beam | `border-beam` | **One 2s pass on connect, then settle to a static dot.** A permanently traveling beam is fatiguing and a reduced-motion violation. |
| BLE scanning | Ripple | `ripple` | Radar pulse. Stops on connect. |
| Sync in progress | Animated Shiny Text | `animated-shiny-text` | Subtle; replaces a spinner. |
| SOS armed | Pulsating Button | `pulsating-button` | The one place urgency motion is correct. |
| Landing hero bg | Animated Grid Pattern / Dot Pattern | `animated-grid-pattern`, `dot-pattern` | **Marketing page only** — never behind clinical data. |
| Landing headline | Aurora Text | `aurora-text` | Marketing only. |

**Explicitly rejected:** `confetti` on a completed reading, `meteors`/`particles` on
any clinical screen, `retro-grid` behind charts. Decorative motion behind medical
data reduces perceived reliability — and any moving field behind a chart makes the
chart harder to read.

### Mobile — same eight primitives, re-implemented

Magic UI is React DOM and will not run in React Native. Port the *patterns*, holding
the §3.6 tokens identical so both surfaces feel like one product.

| Purpose | RN implementation |
|---|---|
| Risk ring | `react-native-svg` circle + `react-native-reanimated` `useAnimatedProps` on `strokeDashoffset` |
| Number roll-up | Reanimated `withTiming` + `useDerivedValue` |
| Alert list entrance | `Moti` `<MotiView from/animate>` + `LayoutAnimation` |
| Card stagger | `Moti` with `delay: index * 60` |
| Live-link beam | Reanimated looped `useSharedValue` driving an SVG gradient stop |
| Scanning ripple | Three Reanimated loops, staggered scale + opacity |
| Live PPG / cuff waveform | **`@shopify/react-native-skia`** — the only option that holds 60fps on streaming sensor data |
| Charts | `victory-native` (Skia) or custom Skia |

Gate everything on `AccessibilityInfo.isReduceMotionEnabled()`.

---

## 8. Chart specs

Applies to every chart on both surfaces.

**Marks:** lines **2px**, round cap/join · markers **≥8px** with a **2px surface
ring** · area fills the series hue at **~10% opacity**, never a saturated block ·
bars ≤24px with a 4px rounded data-end, square at baseline · **2px surface gap**
between touching fills, never a stroke around a mark.

**Chrome:** gridlines and axes are **solid 1px hairlines**, one step off surface —
never dashed. Dashing reads as "threshold" when it's just a grid. Y-ticks round to
clean numbers, `tabular-nums`.

**Labels:** legend present for ≥2 series (BP only); none for single-series charts —
the title already names it. Direct-label **selectively** — endpoint and extreme
only, never a value on every point. **Text never wears the series color**; identity
comes from the swatch beside it.

**Clinical thresholds** are hairline reference lines in muted ink with an outside-edge
label, *not* series-colored and *not* dashed:
- SpO₂ — line at **95%**, region below shaded `--risk-high` at 8%
- Temp — normal band **36.1–37.2°C** as a 10% neutral wash
- BP — **130/80** reference lines
- HR — **60–100 bpm** band

**Interaction:** crosshair + tooltip on every line chart; hit target ≥24px. Tooltips
**enhance, never gate** — every value is also in the table view. On refetch, hold the
previous render at reduced opacity; **never flash a skeleton** (no layout jump).

**Hard rule: no dual-axis charts, ever.** Two units on one plot invents a
correlation that isn't in the data. Four vitals = four charts.

---

## 9. Build order

1. **Tokens** — `tokens.ts` + `tailwind.config` + `globals.css`. Shared by both clients. Nothing else starts first.
2. **Risk indicator** — §4, with all four redundant channels and the incomplete-profile state.
3. **Mobile shell** — nav, Home with mocked data, dark theme.
4. **BLE layer** — custom dev client, ESP32 GATT contract, reconnect + offline queue.
5. **Measure flow** — five states, Skia live waveform.
6. **API + MQTT** — Wi-Fi path, TimescaleDB schema, sync reconciliation.
7. **AI service** — risk scoring behind a versioned endpoint returning `{band, value, horizon, factors[], confidence}`. `factors[]` and `confidence` are required by §4 and are not optional response fields.
8. **SOS** — §6, all four fallback rungs. Ship no rung as TODO.
9. **Trends + charts** — §8, table-view twin per chart.
10. **Web dashboard** — roster, detail, Magic UI motion layer.

### Definition of done (any screen)
- [ ] Dark **and** light rendered and checked — light mode is selected, not an inverted flip
- [ ] Palette re-validated if any surface or token hex changed
- [ ] `prefers-reduced-motion` / `isReduceMotionEnabled` honored
- [ ] Every chart has a table-view twin
- [ ] No risk meaning carried by color alone
- [ ] Rendered and **looked at** — no clipped labels, no overflow, no nested scrollbars
