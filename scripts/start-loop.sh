#!/usr/bin/env bash
#
# start-loop.sh — launch the autonomous build loop, detached, and keep the Mac awake.
#
# - `caffeinate` prevents idle/AC sleep for the whole run (keep the lid OPEN or stay on power).
# - `nohup ... & disown` lets it keep running after you close the terminal / log out of the shell.
# - All output goes to .loop/logs/. Stop any time with scripts/stop-loop.sh.
#
# Override any tunable inline, e.g.:  HOURS=11.5 MAX_ITERS=40 PUSH=1 scripts/start-loop.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"

CODEX="$(command -v codex || echo /opt/homebrew/bin/codex)"
CLAUDE="$(command -v claude || echo "$HOME/.local/bin/claude")"

echo "Preflight…"
fail=0
[ -x "$CODEX" ]  && echo "  codex:  $("$CODEX" --version 2>/dev/null | head -1)  ($CODEX)"   || { echo "  codex:  MISSING";  fail=1; }
[ -x "$CLAUDE" ] && echo "  claude: $("$CLAUDE" --version 2>/dev/null | head -1)  ($CLAUDE)" || { echo "  claude: MISSING"; fail=1; }
command -v swift >/dev/null && echo "  swift:  $(swift --version 2>/dev/null | head -1)"      || { echo "  swift:  MISSING";  fail=1; }
[ -f "$HOME/.codex/auth.json" ] && echo "  codex auth: present" || echo "  codex auth: NOT found (run 'codex login' first)"
command -v caffeinate >/dev/null && echo "  caffeinate: present" || echo "  caffeinate: MISSING (Mac may sleep)"
[ "$fail" = "0" ] || { echo "Preflight failed — fix the above and retry."; exit 1; }

if [ -f .loop/loop.pid ] && kill -0 "$(cat .loop/loop.pid 2>/dev/null)" 2>/dev/null; then
  echo "A loop already appears to be running (PID $(cat .loop/loop.pid)). Stop it first: scripts/stop-loop.sh"
  exit 1
fi

mkdir -p .loop/logs
rm -f .loop/STOP

echo "Launching detached, keeping the Mac awake…"
nohup caffeinate -i -s bash "$SCRIPT_DIR/auto-loop.sh" >.loop/logs/loop.out 2>&1 &
echo $! >.loop/loop.pid
disown 2>/dev/null || true

sleep 1
echo
echo "Loop started.  PID $(cat .loop/loop.pid)"
echo "  Watch:   tail -f \"$REPO/.loop/logs/loop.log\""
echo "  Stop:    \"$SCRIPT_DIR/stop-loop.sh\""
echo "  Branch:  all work lands on 'auto/build' (your 'main' is untouched)."
