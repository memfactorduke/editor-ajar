#!/usr/bin/env bash
#
# auto-loop.sh — the conductor for Editor Ajar's autonomous build loop.
#
# Runs Codex (builder) and Claude Code (reviewer) in STRICT ALTERNATION — never at the same time —
# on the `auto/build` branch, and owns all git itself. This is what keeps the two agents from ever
# colliding (see docs/loop/README.md, ADR-0014).
#
# Safe to stop any time: `scripts/stop-loop.sh` (or `touch .loop/STOP`). It exits at the next step.
# Nothing is lost: every successful builder step is committed before review.
#
# Tunables (override via env): MAX_ITERS, HOURS, BUILD_TIMEOUT, REVIEW_TIMEOUT, BRANCH, PUSH, MAX_TURNS
set -uo pipefail

# --- locate repo (this script lives in <repo>/scripts) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"

# --- config ---
MAX_ITERS="${MAX_ITERS:-40}"
HOURS="${HOURS:-11.5}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-1800}"     # seconds per builder step (30 min)
REVIEW_TIMEOUT="${REVIEW_TIMEOUT:-900}"    # seconds per reviewer step (15 min)
MAX_TURNS="${MAX_TURNS:-30}"               # cap on the reviewer's agentic turns
BRANCH="${BRANCH:-auto/build}"
PUSH="${PUSH:-1}"                          # 1 = push the branch each iteration

CODEX="$(command -v codex || echo /opt/homebrew/bin/codex)"
CLAUDE="$(command -v claude || echo "$HOME/.local/bin/claude")"
TIMEOUT="$(command -v timeout || command -v gtimeout || true)"

mkdir -p .loop/logs
LOGFILE=".loop/logs/loop.log"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE"; }

run_with_timeout() { # <seconds> <cmd...>
  local secs="$1"; shift
  if [ -n "$TIMEOUT" ]; then
    "$TIMEOUT" --signal=TERM --kill-after=30s "${secs}s" "$@"
  else
    "$@"
  fi
}

# --- preflight ---
[ -x "$CODEX" ]  || { log "FATAL: codex not found ($CODEX)"; exit 1; }
[ -x "$CLAUDE" ] || { log "FATAL: claude not found ($CLAUDE)"; exit 1; }
command -v swift >/dev/null || { log "FATAL: swift not found"; exit 1; }
[ -n "$TIMEOUT" ] || log "WARN: no timeout binary; steps will run uncapped per-call."

# --- deadline ---
SECS="$(awk "BEGIN{printf \"%d\", ${HOURS}*3600}")"
DEADLINE=$(( $(date +%s) + SECS ))
log "=================================================================="
log "Editor Ajar autonomous loop starting."
log "repo=$REPO branch=$BRANCH max_iters=$MAX_ITERS hours=$HOURS push=$PUSH"
log "codex=$CODEX"
log "claude=$CLAUDE"
log "deadline=$(date -r "$DEADLINE" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "+${HOURS}h")"

# --- branch setup (keep main pristine; all work on $BRANCH) ---
if [ -n "$(git status --porcelain)" ]; then
  log "WARN: working tree dirty; committing as a safety checkpoint before branching."
  git add -A && git commit -q -m "chore(loop): checkpoint before autonomous run" || true
fi
git rev-parse --verify "$BRANCH" >/dev/null 2>&1 && git checkout -q "$BRANCH" || git checkout -q -b "$BRANCH"
log "on branch: $(git branch --show-current)"

rm -f .loop/STOP
no_progress=0
i=0
while [ "$i" -lt "$MAX_ITERS" ]; do
  i=$((i+1))
  now="$(date +%s)"
  if [ "$now" -ge "$DEADLINE" ]; then log "Deadline reached — stopping."; break; fi
  if [ -f .loop/STOP ]; then log "STOP file present — stopping."; break; fi

  pad="$(printf '%03d' "$i")"
  log "------------------------------------------------------------------"
  log "Iteration $i / $MAX_ITERS  (builder)"

  # ---------- BUILDER (Codex) ----------
  # workspace-write sandbox: can edit + run tests; .git is read-only & no network (it CANNOT
  # commit/push — the conductor does). -a never: never pause for approval (unattended).
  run_with_timeout "$BUILD_TIMEOUT" "$CODEX" exec \
      --sandbox workspace-write -a never --skip-git-repo-check \
      "$(cat docs/loop/build-prompt.md)" \
      >".loop/logs/iter-${pad}-build.log" 2>&1
  log "builder exit=$? (log: .loop/logs/iter-${pad}-build.log)"

  # ---------- COMMIT builder work (conductor owns git) ----------
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    note="$(head -c 500 .loop/build-note.md 2>/dev/null)"
    git commit -q -m "build(loop): iteration $i" -m "${note:-no build note}" || true
    log "committed builder changes: $(git rev-parse --short HEAD)"
    no_progress=0
  else
    no_progress=$((no_progress+1))
    log "builder produced no changes (streak=$no_progress)"
  fi

  # ---------- REVIEWER (Claude /loop) ----------
  log "Iteration $i / $MAX_ITERS  (reviewer /loop)"
  run_with_timeout "$REVIEW_TIMEOUT" "$CLAUDE" -p "/loop" \
      --dangerously-skip-permissions --max-turns "$MAX_TURNS" \
      >".loop/logs/iter-${pad}-review.log" 2>&1
  log "reviewer exit=$? (log: .loop/logs/iter-${pad}-review.log)"
  if [ -f .loop/review.md ]; then
    log "verdict: $(head -n1 .loop/review.md)"
  fi

  # ---------- COMMIT review note ----------
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -q -m "review(loop): iteration $i" || true
  fi

  # ---------- PUSH branch (network is fine here — conductor, not Codex) ----------
  if [ "$PUSH" = "1" ]; then
    if git push -q -u origin "$BRANCH" 2>>".loop/logs/iter-${pad}-push.log"; then
      log "pushed $BRANCH"
    else
      log "push failed (non-fatal; commits are safe locally) — see iter-${pad}-push.log"
    fi
  fi

  # ---------- stall guard ----------
  if [ "$no_progress" -ge 3 ]; then
    log "No changes for 3 iterations in a row — stopping to avoid spinning."
    break
  fi
done

log "Loop finished after $i iteration(s) on branch $BRANCH."
log "Review the work:  git log --oneline $BRANCH   |   open PR from $BRANCH into main."
log "=================================================================="
