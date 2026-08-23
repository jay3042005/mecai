# MEC-AI

AI-driven cardiovascular risk monitoring for the MEC-AI wearable.

Three surfaces, one design language:

| Path | What it is | Stack |
|---|---|---|
| `apps/mobile` | Primary app — BLE, GPS, SOS, live vitals | Flutter 3.41 / Dart 3.11 |
| `apps/web` | Guardian + clinician dashboard | Next.js 16, Tailwind v4, Magic UI |
| `services/api` | Risk scoring + AI service | Python 3.12+, FastAPI |
| `packages/tokens` | Design tokens — **single source of truth** | JSON + generator |
| `docs/design.md` | Design system & UI spec | — |

---

## Quickstart

### 1. API (start this first — both clients depend on it)

```bash
./start-api.sh

# Dashboard demo only: enable synthetic reading endpoints.
MECAI_ENABLE_MOCK_ENDPOINTS=true ./start-api.sh

# Manual setup / reload mode:
cd services/api
uv venv && uv pip install -e ".[dev]"

# Loopback only — fine for the web dashboard and emulators:
.venv/bin/python -m uvicorn mecai_api.main:app --reload

# Reachable from a physical phone on the same Wi-Fi:
.venv/bin/python -m uvicorn mecai_api.main:app --host 0.0.0.0 --port 8000
```

Serves on `http://127.0.0.1:8000`. Interactive docs at `/docs`.

```bash
.venv/bin/python -m pytest        # 110 tests
```

### 2. Web dashboard

```bash
pnpm install
cd apps/web && pnpm dev           # http://localhost:3000
```

### 3. Mobile app

```bash
cd apps/mobile
flutter pub get
flutter run
```

```bash
flutter analyze && flutter test   # 83 tests
```

**Multiple profiles.** One phone can serve several people: *Profile → Profiles*
lists them and adds new ones. Each person gets their own questionnaire,
emergency contacts, readings archive, and patient id — so each appears as a
separate row on the clinician dashboard. A pre-multi-profile install keeps its
identity and data untouched on upgrade.

**Pairing is asked once, never forced.** The setup screen has no Skip button:
press-and-hold *Scan & Connect* for three seconds to continue without a watch.
The choice is remembered; pairing stays available in *Settings → MEC-AI watch*.

**Finding the server.** The API announces `_mecai._tcp` over mDNS on startup,
and Settings offers *Find server automatically*. Discovery runs at boot while
the address is still a factory default; a typed address always wins.

**Sample data.** *Settings → Sample data → Generate* writes two days of
back-dated readings for the current profile through the normal archive, so
backup uploads them and the dashboard fills in. Ids derive from timestamps, so
regenerating deduplicates instead of doubling history.

**Setting the server address.** Tap the person icon → *Settings* → enter the address
→ *Save and test connection*. A bare IP works; `http://` and `:8000` are filled in
automatically, and the setting persists across restarts.

| Running on | Address |
|---|---|
| Android emulator | `10.0.2.2:8000` (host loopback alias) |
| iOS simulator | `127.0.0.1:8000` |
| Physical phone on Wi-Fi | your computer's LAN IP, e.g. `192.168.1.11:8000` |

There is no default that works everywhere — a phone cannot reach `127.0.0.1` or
`10.0.2.2`, since those resolve to the phone itself. For a physical device the API
must **also** be started with `--host 0.0.0.0`; bound to loopback it is invisible on
the network no matter what address the app uses.

To pin an address at build time instead (CI, demo builds):

```bash
flutter run --dart-define=MECAI_API_URL=http://192.168.1.11:8000
```

---

## Design tokens — read this before changing any colour

`packages/tokens/tokens.json` is the **only** place colour, radius, type, motion, and
clinical thresholds are defined. It generates:

```
apps/mobile/lib/design/tokens.dart              colours, type, motion, thresholds
apps/web/src/lib/tokens.ts                      same, for the dashboard
apps/web/src/app/tokens.css                     Tailwind v4 @theme
services/api/src/mecai_api/generated_thresholds.py   alert cut-points
packages/tokens/alert-conformance.json          cross-language test vectors
```

```bash
node packages/tokens/generate.mjs
```

Never hand-edit the generated files. Two clients with independent hex values diverge
within a week, and a clinical UI cannot afford "High risk" being one red on Android
and a different red on the web.

### Alerts run locally, and are held to a contract

Acute alerts (`SpO₂ < 90`, hypertensive crisis, fever…) are evaluated **on-device**,
not on the server. An SpO₂ of 88% is an emergency whether or not the phone has
signal — routing that judgement through the network would fail exactly when someone
is somewhere remote, which is when a rural health device matters most.

The ten-year risk score still requires the server, because that's where the
Framingham model lives and a client-side port of clinical coefficients would drift.

That leaves two implementations of one rule set — `lib/data/acute_flags.dart` and
`risk/engine.py`. Both read their cut-points from generated constants, and both are
tested against `packages/tokens/alert-conformance.json`: 41 vectors including
every boundary case, generated from the same thresholds so moving a cut-point moves
its cases with it. If the two ever disagree about a reading, the conformance test
fails on both sides.

```bash
cd services/api && .venv/bin/python -m pytest tests/test_conformance.py
cd apps/mobile && flutter test test/conformance_test.dart
```

### The palette is validated, not chosen by eye

`tokens.json` carries its own validation record. The finding that shapes the whole
risk UI:

```
3-band risk, normal vision    ΔE 27.6   PASS
3-band risk, deuteranopia     ΔE  4.1   FAIL   ← #d03b3b (High) vs #0ca30c (Low)
```

Roughly 8% of men cannot distinguish Low from High **by colour at all**. So the
risk indicator carries four redundant channels — word, icon, arc length, colour —
and colour is never load-bearing alone. `apps/mobile/test/widget_test.dart`
enforces this; a refactor that reduces the ring to a coloured arc fails there.

**If you change any palette hex or surface, re-run the colour validator** before
shipping. See `tokens.json` → `$meta.validation`.

### Adding Magic UI / 21st.dev components

```bash
cd apps/web
pnpm dlx shadcn@latest add @magicui/animated-list
```

⚠️ **Do not run `shadcn init`.** It rewrites `globals.css` and would clobber the
generated token wiring. The project is already configured; add components directly.

Component-to-need mapping is in `docs/design.md` §7, including which ones are
deliberately rejected (no `confetti` on a medical reading).

---

## Architecture notes

**The risk model lives in exactly one place** — `services/api/src/mecai_api/risk/`.
Neither client reimplements it. A Dart or TypeScript port of the Framingham
coefficients would be a second source of truth for a clinical calculation, and
there would be no way to know which figure a user was shown.

**Two independent scoring paths**, deliberately not merged:

- `engine.assess` — ten-year chronic risk. Needs the questionnaire.
- `engine.acute_flags` — immediate out-of-range vitals. Needs nothing but the reading.

A reassuring ten-year band must never suppress an acute SpO₂ warning, and an
unreachable scoring service must not hide one either.

**Incomplete profiles refuse to score.** The device cannot measure cholesterol,
smoking, or diabetes. When those are missing the API returns `band: "unknown"` and
`value_pct: null` rather than substituting a population mean — a guessed input
produces a confident-looking figure with no validity behind it. This is enforced by
a Pydantic validator, so a client cannot bypass it.

---

## Hardware status

Firmware is `MEC-AI3.ino` (ESP32-S3). It provides a subset of the spec, and the
API is built to accept that subset honestly rather than reject it.

| Metric | Spec | Firmware today | API handling |
|---|---|---|---|
| Heart rate | MAX30102 | ✅ MAX30102 | ✅ scored + flagged |
| SpO₂ | MAX30102 | ✅ MAX30102 | ✅ scored + flagged |
| Temperature | LM35, body | SHT30x, **ambient** | ✅ separate `ambient_temp_c`, never flagged |
| Blood pressure | MPX5050GP cuff | ❌ not implemented | ⚠️ blocks ten-year scoring |
| Connectivity | BLE + Wi-Fi | ❌ serial only | — |
| SOS transmit | app + GPS | ⚠️ local LED/screen (`TODO`) | — |

**Every field on `VitalsReading` is optional.** A model requiring all four vitals
would reject every real reading, so instead:

- Absent vitals are **skipped, not zeroed** — no device without a pressure sensor
  ever produces a blood-pressure finding, and no chart draws a cliff to zero.
- `ambient_temp_c` is a **separate field that never produces a clinical flag**. An
  SHT30x in a wrist enclosure reads air influenced by ambient conditions, body
  heat, and MCU self-heating. Routing it to `temperature_c` would fire a critical
  hypothermia alert in an air-conditioned room.
- Missing systolic BP returns `band: "unknown"` with `systolic_mmhg` in
  `missing_fields`. **Acute SpO₂ and heart-rate alerts still fire** — a missing
  sensor must never silence an alarm for a sensor that works.
- The UI **relabels rather than substitutes**: with no contact sensor the fourth
  tile reads *Room temperature*, not *Temperature*. Showing ambient under a body
  label would imply a reading the device never took.

### Testing against real sensor coverage

```bash
curl 'localhost:8000/v1/mock/firmware-reading?scenario=hypoxic'
```

Returns exactly what the firmware reports — HR, SpO₂, ambient — with the rest
`null`. `/v1/assess` on it yields an unscorable ring plus a live SpO₂ alert, which
is the honest current state of the system.

The Flutter mock defaults to `SensorCoverage.firmware` for the same reason.
Developing against `SensorCoverage.complete` flatters the app: every tile fills
and the ring scores, hiding the states a real user hits today. Switch to
`complete` only to preview the finished device.

Mock endpoints are gated by `MECAI_ENABLE_MOCK_ENDPOINTS` and **must be disabled
in production** so synthetic readings can never be mistaken for a patient's own.

---

## Privacy

Health data plus GPS is regulated under the Philippine **Data Privacy Act of 2012
(RA 10173)**. Before any real deployment: explicit consent, TLS in transit,
encryption at rest, a stated retention policy, and BLE bonding with a passkey
rather than Just Works pairing. Never commit `.env`, credentials, or real patient
data — `.gitignore` covers the obvious cases but is not a substitute for care.

**Nothing in this system is a diagnosis.** Every risk figure ships with a
persistent screening-indicator disclaimer, and that is a product requirement, not
a legal footnote.

# mecai
