#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
api_dir="$root/services/api"
port="${PORT:-8000}"

if [[ ! -x "$api_dir/.venv/bin/python" ]]; then
  command -v uv >/dev/null || {
    printf 'uv is required: https://docs.astral.sh/uv/\n' >&2
    exit 1
  }
  uv venv "$api_dir/.venv"
  uv pip install --python "$api_dir/.venv/bin/python" -e "$api_dir"
fi

export MECAI_ENABLE_MOCK_ENDPOINTS="${MECAI_ENABLE_MOCK_ENDPOINTS:-false}"
# The mDNS advertisement must name the same port uvicorn binds.
export MECAI_PORT="$port"
printf 'MEC-AI API: http://0.0.0.0:%s\n' "$port"
lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1 || echo "localhost")"
printf 'LAN address: http://%s:%s\n' "$lan_ip" "$port"
exec "$api_dir/.venv/bin/python" -m uvicorn mecai_api.main:app --host 0.0.0.0 --port "$port"
