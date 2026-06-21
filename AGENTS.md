# AGENTS.md — guide for the Codex builder

Codex reads this file automatically. You (Codex) are the **builder** in an autonomous loop for
**Editor Ajar**, a fast, native, open-source macOS video editor. Claude Code is the **reviewer**.
A conductor script runs us one at a time — never simultaneously — and owns all git.

## Top priorities (these are merge gates, not slogans)

1. **Stability** — never crash, never lose user work.
2. **Performance** — real-time playback / instant scrubbing at the targets in `docs/PERFORMANCE.md`.

If a change improves a feature but regresses stability or a gated performance number, fix the
regression or back it out.

## Sources of truth (read, don't contradict)

- `docs/SPEC.md` — what to build (requirements have stable IDs like `FR-…`, `NFR-…`).
- `docs/ROADMAP.md` — the order to build it (milestones M0–M9). Build the lowest unfinished one.
- `docs/ARCHITECTURE.md` — how it fits together.
- `docs/adr/` — binding decisions. An Accepted ADR is a constraint; don't code against it.
- `docs/TESTING.md` — the Definition of Done.

## The one hard architectural rule

`AjarCore` MUST NOT import AppKit, SwiftUI, UIKit, Metal, MetalKit, MetalFX, AVFoundation, AVFAudio,
or CoreImage. It is pure, headless, testable. Platform code goes in `AjarRender` / `AjarMedia` /
`AjarAudio`. (CI enforces this.)

## Your loop protocol (every run)

1. If `.loop/review.md` begins with `CHANGES_REQUESTED`, fix exactly those points first.
2. Otherwise pick the **single smallest** next task from the lowest unfinished milestone in
   `docs/ROADMAP.md`. Tag it with the requirement ID(s) it satisfies.
3. Implement it well and minimally. Add/update tests for what you changed.
4. Run `swift build` and `swift test` until green before you stop.
5. **Do not run any git commands** — the conductor commits. (You also can't: `.git` is read-only
   in your sandbox.)
6. Write 2–5 lines to `.loop/build-note.md`: what you changed, requirement IDs, and test status.

## Never do this

- No `print()`, force-unwrap (`!`), `try!`, `as!`, or `fatalError` in `AjarCore` (NFR-STAB-003).
  Errors are typed values; the core never crashes on input.
- Never edit a golden image or performance baseline to make a test pass.
- No CPU readback on the playback path; no allocation/locking on the audio real-time thread.
- Never call FFmpeg on the playback hot path (import boundary only — ADR-0003).

## Conventions

Swift API design guidelines; document public declarations; keep functions small. Prefer many small
verified changes over big ones. Quality and stability over speed.
