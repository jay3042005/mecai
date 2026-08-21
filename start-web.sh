#!/usr/bin/env bash
# Serves the built dashboard. Mirrors start-web.bat.
#
# This is the production server, not `next dev`: it holds far less memory and
# does not recompile on every request. For editing code use scripts/dev-web.sh.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
web="$root/apps/web"
port="${PORT:-3000}"

command -v node >/dev/null || {
  printf 'Node.js is required: https://nodejs.org/\n' >&2
  exit 1
}

corepack enable >/dev/null 2>&1 || true

if [[ ! -d "$root/node_modules" ]]; then
  printf 'Installing dashboard dependencies (first run only)\n'
  pnpm install --dir "$root"
fi

# BUILD_ID is written last by a successful build, so its absence means either no
# build or a failed one. Either way the answer is to build.
if [[ ! -f "$web/.next/BUILD_ID" ]]; then
  printf 'Building the dashboard (first run, and after code changes)\n'
  pnpm --dir "$web" build
fi

# `hostname -I` only exists on Debian's inetutils; `ip route get` is the portable
# read of "which address would this host use to reach the LAN". Failure here must
# not be fatal — a missing hint is not a reason to refuse to serve, and under
# `set -e` an unguarded command substitution would abort the script.
lan_ip="$(ip route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src )\S+' || true)"
printf 'MEC-AI dashboard: http://127.0.0.1:%s\n' "$port"
# A plain `[[ ... ]] && printf` would return 1 when there is no LAN address, and
# under `set -e` that non-zero status exits the script before it ever serves.
if [[ -n "$lan_ip" ]]; then
  printf 'LAN address: http://%s:%s\n' "$lan_ip" "$port"
fi

exec pnpm --dir "$web" start --port "$port"
