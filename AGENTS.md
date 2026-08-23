# AGENTS.md

## Layout — three toolchains

| Path | Stack | Tooling |
|---|---|---|
| `apps/mobile` | Flutter 3.41 | `flutter` CLI, run inside `apps/mobile` |
| `apps/web` | Next.js 16, Tailwind v4 | pnpm workspace (`apps/web` + `packages/*` only) |
| `services/api` | Python 3.12+, FastAPI | uv + pytest, run inside `services/api` |

No root build/test command exists. Root `pnpm` commands do not touch mobile or the API.

## Commands

```bash
./start-api.sh                       # repo root; creates .venv via uv if missing, binds 0.0.0.0:${PORT:-8000}
pnpm install                         # repo root
pnpm --dir apps/web dev              # web dashboard on :3000 (build/lint likewise)
cd apps/mobile && flutter pub get && flutter analyze && flutter test
```

API tests/lint (from `services/api`, after `.venv` exists):

```bash
.venv/bin/python -m pytest                        # all tests
.venv/bin/python -m pytest tests/test_conformance.py   # single file
.venv/bin/python -m ruff check .                  # line-length 100
```

pytest config: `pythonpath = ["src"]`, `asyncio_mode = "auto"`.

## Codegen — tokens are the single source of truth

Colour, radius, type, motion **and clinical alert thresholds** live only in
`packages/tokens/tokens.json`. After editing it, always run:

```bash
node packages/tokens/generate.mjs
```

This regenerates five files that must never be hand-edited:
`apps/mobile/lib/design/tokens.dart`, `apps/web/src/lib/tokens.ts`,
`apps/web/src/app/tokens.css`,
`services/api/src/mecai_api/generated_thresholds.py`,
`packages/tokens/alert-conformance.json`. They are committed but must match
`tokens.json`. Changing any palette hex also requires re-running the colour
validator recorded in `tokens.json` → `$meta.validation`.

## Architecture rules enforced by tests

- The Framingham risk model lives **only** in `services/api/src/mecai_api/risk/`.
  Never port coefficients into Dart or TypeScript.
- Two scoring paths stay separate: `engine.assess` (10-year chronic) and
  `engine.acute_flags` (immediate vitals, evaluated **on-device** in
  `apps/mobile/lib/data/acute_flags.dart`). Don't merge them.
- Acute cut-points exist twice (Dart + Python); both sides are tested against
  `packages/tokens/alert-conformance.json`. To move a cut-point: edit
  `tokens.json` → regenerate → run `tests/test_conformance.py` AND
  `apps/mobile/test/conformance_test.dart`.
- Incomplete profiles refuse to score: missing cholesterol/smoking/diabetes/BP ⇒
  `band: "unknown"`, `value_pct: null`. Enforced by a Pydantic validator — don't
  weaken it or substitute population means.
- Every `VitalsReading` field is optional; absent vitals are skipped, never
  zeroed. `ambient_temp_c` is a separate field and must never produce a clinical
  flag (the sensor reads air, not body temperature).

## Env & gotchas

- All env vars use the `MECAI_` prefix (pydantic-settings). Mock endpoints need
  `MECAI_ENABLE_MOCK_ENDPOINTS=true` and must stay disabled in production.
  `MECAI_PORT` must match uvicorn's `--port` — the mDNS advertisement
  (`_mecai._tcp`, disable with `MECAI_DISABLE_MDNS=true`) announces it to phones.
- Web proxies `/api/*` to `MECAI_API_URL` (default `http://127.0.0.1:8000`);
  mobile takes the same name as a dart-define or via in-app Settings.
- `apps/web/AGENTS.md` is an auto-generated Next.js rules block managed by
  `next dev` — read the docs it points to before writing web code, and keep the
  block committed.
- Never run `shadcn init` in `apps/web`; it clobbers the generated token wiring
  in `globals.css`. Add components with `pnpm dlx shadcn@latest add ...`.
- Flutter's mock defaults to `SensorCoverage.firmware` to match real hardware;
  use `complete` only to preview the finished device.
- Health data is regulated (PH RA 10173): never commit `.env`, credentials, or
  real readings. `.data/` is gitignored for this reason.
- Windows packaging CI (`.github/workflows/windows-package.yml`) builds on push
  to `main` when `apps/web/`, `services/api/`, or `deploy/` change; it expects
  `output: "standalone"` in `next.config.ts` — don't remove it.
