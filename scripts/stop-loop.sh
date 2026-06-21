#!/usr/bin/env bash
#
# stop-loop.sh — ask the loop to stop gracefully (it exits at the next step boundary, so the
# in-flight build/review finishes and nothing is left half-committed).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

mkdir -p .loop
touch .loop/STOP
echo "Requested graceful stop (.loop/STOP). The loop exits at the next step boundary."

if [ -f .loop/loop.pid ]; then
  pid="$(cat .loop/loop.pid 2>/dev/null || true)"
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    echo "If you need it to stop *immediately* (abandons the current step): kill $pid"
  fi
fi
