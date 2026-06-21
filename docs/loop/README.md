# Autonomous build loop — orchestrator + builder, coordinated through GitHub

Two tools, one shared coordination layer (GitHub). **Claude Code orchestrates; Codex builds.**

- **Orchestrator** — run `/loop` in Claude Code (`.claude/commands/loop.md`). It keeps a backlog of
  small GitHub **issues** for the current milestone, **reviews** the builder's PRs against the
  Definition of Done, leaves **comments** / requests changes, and **merges** the good ones.
- **Builder** — paste [`build-prompt.md`](build-prompt.md) into Codex. It claims an issue, works it
  on its own branch, and opens a PR.

## How they don't conflict — and why it's in the prompts

The conflict-avoidance is built into the two prompts, not bolted on with scripts:

- **Claude (orchestrator) only touches GitHub** — issues, PR reviews, comments, merges — and reads
  code. It never edits files or switches branches locally.
- **Codex (builder) only writes code on its own `codex/issue-N` branch**, one issue at a time, and
  opens a PR. It never commits to `main`.
- **GitHub is the shared state** (issues = task queue, PRs = handoff). Because the two write to
  different places, they can run at the same time without stepping on each other. Claiming an issue
  with a comment keeps them from grabbing the same task.

## Running it

- **Claude Code:** open the repo and run `/loop` (you already use `--dangerously-skip-permissions`).
- **Codex:** paste `build-prompt.md`. Run Codex with **network + write access** (a full-access mode)
  so it can `git push` and use `gh` — Codex's default sandbox blocks the network.
- Both can run in the same folder. If you want extra isolation, give Codex its own clone or a
  `git worktree`.

Nothing reaches `main` without the orchestrator's review — check `main` whenever you like.
