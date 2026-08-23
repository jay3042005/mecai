#!/usr/bin/env bash
# Keeps the dashboard dev server up.
#
# `next dev` on this machine dies from memory pressure, not from a code fault:
# the Turbopack worker is the largest process in the tree and the kernel reaps it
# first once swap is in play. Restarting is the honest fix for a dev server —
# for a demo or a client machine use `pnpm --dir apps/web build && pnpm --dir
# apps/web start`, which holds a fraction of the memory and does not recompile.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Turbopack's compiler is the part that grows. A ceiling makes V8 collect rather
# than expand into swap and get killed.
export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=2048"

while true; do
  printf '\n[dev-web] starting next dev\n'
  pnpm --dir "$root/apps/web" dev
  status=$?

  # A deliberate Ctrl-C must exit, not restart.
  if [[ $status -eq 0 || $status -eq 130 ]]; then
    printf '[dev-web] stopped (exit %d)\n' "$status"
    exit "$status"
  fi

  printf '[dev-web] exited %d — restarting in 2s\n' "$status"
  sleep 2
done
