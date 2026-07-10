# AGENTS.md — guide for the Codex builder

Codex reads this automatically. You (Codex) are the **builder** for **Editor Ajar**, a fast,
native, open-source macOS video editor. **Claude Code is the orchestrator**: it files GitHub issues
and reviews your pull requests. You write the code; it manages the work.

## Top priorities (merge gates, not slogans)

1. **Stability** — never crash, never lose user work.
2. **Performance** — real-time playback / instant scrubbing at the `docs/PERFORMANCE.md` targets.

## Sources of truth (read, don't contradict)

- `docs/SPEC.md` — requirements (stable IDs like `FR-…`, `NFR-…`).
- `docs/ROADMAP.md` — milestone order (M0–M9). Build the lowest unfinished one.
- `docs/ARCHITECTURE.md` — how it fits together.
- `docs/adr/` — binding decisions; an Accepted ADR is a constraint.
- `docs/TESTING.md` — the Definition of Done.

## The one hard architectural rule

`AjarCore` MUST NOT import AppKit, SwiftUI, UIKit, Metal, MetalKit, MetalFX, AVFoundation, AVFAudio,
or CoreImage. It is pure, headless, testable. Platform code goes in `AjarRender` / `AjarMedia` /
`AjarAudio` / `AjarExport`. (CI enforces this.)

## Your workflow — one issue, one branch, one PR

1. Pick the lowest-numbered open issue labeled `ready` that nobody has claimed
   (`gh issue list --label ready`). Comment to claim it so two builders never collide. If none are
   ready yet, take the next small task straight from `docs/ROADMAP.md`.
2. `git fetch origin && git switch -c codex/issue-<n> origin/main` — a fresh branch off latest
   main. **Never commit to `main`.**
3. Implement it. Add/update tests. Make `swift build` and `swift test` pass.
4. Commit, push, and open a PR: `gh pr create --fill` with `Closes #<n>` in the body.
5. Address review comments on your open PRs, then take the next issue.

## How we avoid conflicts (built in)

You only ever write code on your own `codex/issue-N` branch and open PRs. The orchestrator only
touches GitHub (issues, PR comments/reviews, merges) and reads code — it never edits files or
switches branches. Different surfaces ⇒ no collisions.

## Never do this

- No `print()` / force-unwrap (`!`) / `try!` / `as!` / `fatalError` in `AjarCore` (NFR-STAB-003).
- Don't edit golden images or performance baselines to make a test pass.
- No CPU readback on the playback path; no allocation/locking on the audio real-time thread.
- No FFmpeg on the playback hot path (import boundary only — ADR-0003).
- Don't commit to `main`; don't work more than one issue at a time.
