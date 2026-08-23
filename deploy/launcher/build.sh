#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
echo "Building MECAI-Launcher (Linux test)..."
pip install --quiet pyinstaller 2>&1 | tail -n 5
# noconsole -> windowed on linux not supported, use normal
pyinstaller --noconfirm --onefile --name MECAI-Launcher --clean "$DIR/mecai_launcher.py"
echo "Built: $DIR/dist/MECAI-Launcher"
ls -lh "$DIR/dist/" 2>&1 | tail -n 20
