# Contributing to Editor Ajar

Thanks for your interest! Editor Ajar is an open-source, Mac-native video editor that prizes
**stability and performance** above all. This guide covers how to get set up and how changes are
accepted. (If you are an automated build agent, start with [CLAUDE.md](CLAUDE.md).)

## Ground rules

- Be excellent to each other — see the [Code of Conduct](CODE_OF_CONDUCT.md).
- The [SPEC](docs/SPEC.md), [ROADMAP](docs/ROADMAP.md), and [ADRs](docs/adr/) are the sources of
  truth. Accepted ADRs are binding; change a decision by proposing a new ADR.
- Stability and performance are merge gates, not nice-to-haves.

## Prerequisites

- macOS 14+ and a recent Xcode / Swift toolchain.
- [SwiftLint](https://github.com/realm/SwiftLint) and
  [swift-format](https://github.com/apple/swift-format) for linting/formatting.

## Getting started

```bash
git clone <your-fork-url> && cd editor-ajar
swift build
swift test
```

## Making a change

1. **Find or open an issue.** Reference the requirement ID(s) from the [SPEC](docs/SPEC.md) and the
   [ROADMAP](docs/ROADMAP.md) milestone it belongs to.
2. **Branch** from `main` (e.g. `feat/key-bezier-FR-KEY-003`).
3. **Implement the smallest correct slice.** Keep `AjarCore` free of UI/GPU imports (ADR-0005).
4. **Test it.** Unit/property tests for core logic; golden-frame tests for anything that changes
   pixels; golden-audio for audio. Don't regress the benchmarks.
5. **Check quality locally:** `swift test`, `swiftlint`, `swift-format lint -r Sources Tests`.
6. **Update docs + `CHANGELOG.md`.**
7. **Open a PR** using the template. CI must pass; a maintainer reviews and merges.

## Definition of Done

See [docs/TESTING.md §4](docs/TESTING.md). In short: requirements met and tested, golden/benchmark
gates green, accessible UI, lint/sanitizers clean, docs updated.

## Commit messages

Conventional-Commits style, referencing requirement IDs where relevant:

```
feat(COMP): spill suppression for chroma key (FR-COMP-001)
perf(render): cache unchanged compound clips (FR-CMP-006)
fix(timeline): ripple delete no longer leaves a 1-frame gap (FR-TL-005)
```

## Proposing an architectural change (ADR)

Copy [`docs/adr/0000-adr-template.md`](docs/adr/0000-adr-template.md) to the next number, fill it
in, set status to *Proposed*, add a row to [`docs/adr/README.md`](docs/adr/README.md), and open a
PR for discussion.

## Sign-off (DCO)

By contributing, you certify you wrote the change or have the right to submit it under the project
license. Sign commits with `git commit -s` (adds a `Signed-off-by` line). Contributions are
accepted under [GPL-3.0-or-later](LICENSE) — inbound equals outbound.
