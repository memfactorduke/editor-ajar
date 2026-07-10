# CLAUDE.md — operating guide for the build agent

This file orients an automated coding agent (or any new contributor) working in **Editor Ajar**.
Read it fully before making changes. It is intentionally short; the detail lives in the linked
sources of truth.

## What this project is

A fast, native, **open-source macOS video editor**. Two priorities sit above all others and act as
**merge gates**, not aspirations:

1. **Stability** — never crash, never lose user work.
2. **Performance** — real-time playback and instant scrubbing at the targets in
   [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

If a change improves a feature but regresses stability or a gated performance number, it is **not**
an improvement. Back it out or fix the regression.

## Sources of truth (read these; do not contradict them)

- **[docs/SPEC.md](docs/SPEC.md)** — what to build, as requirements with stable IDs (`FR-…`, `NFR-…`).
- **[docs/ROADMAP.md](docs/ROADMAP.md)** — the order to build it (milestones M0–M9).
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — how it fits together.
- **[docs/adr/](docs/adr/)** — binding decisions. An **Accepted ADR is a constraint.** To change a
  decision, write a new ADR that supersedes the old one — never just code against it.
- **[docs/TESTING.md](docs/TESTING.md)** — the Definition of Done and the CI gates.

## Module map & the one hard rule

```
EditorAjar (app) → AjarExport → AjarRender · AjarAudio · AjarCore
                 → AjarRender · AjarMedia · AjarAudio → AjarCore → (no in-project deps)
```

**`AjarCore` MUST NOT import AppKit, SwiftUI, Metal, or AVFoundation.** It is pure, headless, and
fully unit-testable. This dependency rule is CI-enforced (ADR-0005, ADR-0011). Put platform code in
the platform modules (including the offline `AjarExport` orchestration boundary), not the core.

## How to pick work

1. Find the lowest-numbered milestone in [ROADMAP](docs/ROADMAP.md) that isn't complete.
2. Decompose it into a small task. Tag the task with the requirement ID(s) it satisfies.
3. Implement the smallest correct slice. Prefer many small, verified changes over big ones.
4. Don't start a milestone whose dependencies are unmet.

## Definition of Done (every change)

A change is merge-eligible only when **all** hold (see [TESTING §4](docs/TESTING.md)):

1. The target requirement ID(s) are met and referenced in the new tests.
2. New `AjarCore` logic has unit/property tests; pixel/audio changes have golden tests.
3. The **benchmark suite stays green** — no gated NFR regresses beyond its noise band.
4. New UI is keyboard-accessible and VoiceOver-labelled.
5. Lint/format clean, sanitizers clean, docs + `CHANGELOG.md` updated.

## Commands

```bash
swift build          # build engine modules + ajar CLI
swift test           # unit / property / (later) golden + integration
swiftlint            # lint (config: .swiftlint.yml)
swift-format lint -r Sources Tests   # format check (config: .swift-format)
# ajar render/bench/golden — headless harness (available from M2)
```

## Never do this

- Never put `print()`, force-unwrap (`!`), `try!`, `as!`, or `fatalError` in `AjarCore`
  (NFR-STAB-003). Errors are typed values; the core never crashes on input.
- Never edit a golden image or a performance baseline just to make a test pass. Updating them is a
  separate, explicit, reviewed commit with justification.
- Never do CPU readback of GPU textures on the playback path, or allocate/lock on the audio
  real-time thread (ADR-0012, PERFORMANCE §6).
- Never call FFmpeg on the playback hot path — it lives only at the import boundary (ADR-0003).
- Never merge against a red CI gate or a contradicting Accepted ADR.

## Conventions

- Swift API design guidelines; document all public declarations; keep functions small.
- Conventional-Commits-style messages (`feat:`, `fix:`, `perf:`, `test:`, `docs:`, `refactor:`),
  referencing requirement IDs (e.g. `feat(KEY): bezier interpolation (FR-KEY-003)`).
- One ADR per significant decision; update `docs/adr/README.md`.
- Branch per task; open a PR; CI must be green; a human approves the merge (ADR-0014, initial
  posture).
