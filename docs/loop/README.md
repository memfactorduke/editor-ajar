# Autonomous build loop — runbook

This is the operating manual for building Editor Ajar with two AI agents running unattended.

## The design (why it can't conflict)

- **Codex is the builder.** **Claude Code is the reviewer.**
- A single **conductor** (`scripts/auto-loop.sh`) runs them **one at a time, in strict
  alternation** — they are never active simultaneously, so they can't fight over files.
- All work happens on the **`auto/build`** branch. Your **`main` is never touched** by the loop.
- **The conductor owns git.** The agents never commit or push. (Codex literally can't: in its
  `workspace-write` sandbox, `.git` is read-only and the network is off. It can only edit files
  and run tests.) The conductor commits the builder's work, then the reviewer's note, then pushes
  the branch.

This is the "running both as loops" you wanted — just coordinated by a tiny conductor so nothing
collides, which is what makes it safe to leave alone.

## One iteration

1. **Build** — `codex exec` (sandboxed, no approval prompts) reads `AGENTS.md` +
   `docs/loop/build-prompt.md`: addresses any `CHANGES_REQUESTED` in `.loop/review.md`, else takes
   the smallest next task from `docs/ROADMAP.md`; runs `swift build` + `swift test`; writes
   `.loop/build-note.md`.
2. **Commit** — the conductor commits the builder's changes.
3. **Review** — `claude -p "/loop"` runs the `/loop` command (`.claude/commands/loop.md`): checks
   the change against the Definition of Done, runs the tests, writes a verdict to `.loop/review.md`
   (`APPROVED:` or `CHANGES_REQUESTED:` + specifics).
4. **Commit + push** — the conductor commits the review note and pushes `auto/build`.

The next build iteration starts from the reviewer's verdict, so the two agents form a
build → review → fix → review cycle.

## Run it

```bash
cd "editor-ajar"
scripts/start-loop.sh        # preflight, then launches detached + keeps the Mac awake
tail -f .loop/logs/loop.log  # watch progress
scripts/stop-loop.sh         # graceful stop (exits at the next step boundary)
```

`start-loop.sh` uses `caffeinate` so the Mac won't idle-sleep, and `nohup … & disown` so it
survives closing the terminal. **Keep the lid open or stay on power** (a closed lid can still sleep).

## Safety caps (all overridable via env)

| Var | Default | Meaning |
|-----|---------|---------|
| `HOURS` | `11.5` | wall-clock budget; the loop stops after this |
| `MAX_ITERS` | `40` | hard cap on iterations |
| `BUILD_TIMEOUT` | `1800` | seconds per builder step (then killed) |
| `REVIEW_TIMEOUT` | `900` | seconds per reviewer step |
| `MAX_TURNS` | `30` | cap on the reviewer's agentic turns |
| `PUSH` | `1` | push `auto/build` each iteration (`0` = local only) |
| `BRANCH` | `auto/build` | branch to work on |

Also: it stops if `.loop/STOP` exists, and if the builder makes **no changes for 3 iterations**
(prevents spinning, e.g. if an agent's auth expired). Every successful build step is committed
before review, so a crash or stop loses at most the current step.

Example: `HOURS=8 MAX_ITERS=25 PUSH=0 scripts/start-loop.sh`

## In the morning

```bash
git log --oneline auto/build         # what got built
open .loop/logs/loop.log             # the narrative
gh pr create --base main --head auto/build   # if you like it, open a PR (CI runs)
```
Nothing was merged to `main` automatically — you decide what to keep.

## Files

- `scripts/auto-loop.sh` — the conductor (the loop).
- `scripts/start-loop.sh` / `scripts/stop-loop.sh` — launch / stop.
- `AGENTS.md` — builder (Codex) guide. `.claude/commands/loop.md` — reviewer (`/loop`).
- `docs/loop/build-prompt.md` — the builder prompt.
- `.loop/review.md`, `.loop/build-note.md` — the agents' handoff (committed as an audit trail).
- `.loop/logs/` — per-iteration logs (git-ignored).

## Troubleshooting

- **Nothing happens / "no changes" repeatedly:** check `.loop/logs/iter-*-build.log` — usually
  Codex auth (`codex login`) or a `swift build` error.
- **Reviewer never writes a verdict:** check `iter-*-review.log`; ensure `claude` is logged in. If
  your Claude version doesn't expand `/loop` in `-p` mode, edit `auto-loop.sh` to use
  `claude -p "$(sed '1,/^---$/d;/^---$/d' .claude/commands/loop.md)"` instead.
- **Push fails:** non-fatal; commits are safe locally. Fix remote/SSH and they'll push next round.
