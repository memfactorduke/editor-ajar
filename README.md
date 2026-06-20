<div align="center">

# Editor Ajar

**A fast, native, open-source video editor for macOS.**

*The door, left ajar — open source, open formats, approachable.*

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Status](https://img.shields.io/badge/status-pre--alpha%20scaffold-orange)

</div>

---

> **Status: pre-alpha.** This repository is currently the **scaffold** — the specification, the
> architecture decisions, and the skeleton. The implementation is built milestone by milestone per
> the [roadmap](docs/ROADMAP.md). Nothing here edits video *yet*.

## Why

Popular consumer editors are cross-platform ports that feel sluggish and unstable on the Mac —
slow launches, laggy scrubbing, beachballs, lost work. Editor Ajar is a bet that a **Mac-native**
editor built directly on Apple's hardware media pipeline can be dramatically faster and more
stable, while still being **fully featured, professional, and good-looking**.

Two priorities sit above everything else (they are merge gates, not slogans):

- **Stability** — never crash, never lose work.
- **Performance** — real-time playback and instant scrubbing at the [target specs](docs/PERFORMANCE.md).

## What it will do (v1)

Multi-track timeline editing · all transforms (move, **zoom**, **rotate**, crop, opacity) ·
full **keyframing** with a curve editor · **chroma key / green screen**, masks & blend modes ·
**compound clips** (nesting) · color correction, scopes & LUTs · multitrack audio with a mixer,
fades & ducking · titles & animated text · effects & transitions · speed ramping · proxies &
background rendering · hardware-accelerated export (H.264 / HEVC / ProRes).

The complete, requirement-by-requirement definition is in **[docs/SPEC.md](docs/SPEC.md)**.

## Architecture in one picture

A headless, testable core with a thin native shell ([ADR-0005](docs/adr/0005-core-ui-separation.md)):

```
EditorAjar (SwiftUI app)
    → AjarRender (Metal)  ·  AjarMedia (AVFoundation/VideoToolbox + FFmpeg)  ·  AjarAudio (Core Audio)
        → AjarCore  (pure Swift: model · time · keyframes · render-graph · color · .ajar)  → (no deps)
```

`AjarCore` has no UI and no GPU dependency, so the bulk of the editor is verified by fast,
deterministic tests; pixels are checked by the `ajar` CLI golden-frame harness. Details in
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## Repository layout

```
editor-ajar/
├── docs/               # SPEC, ARCHITECTURE, ROADMAP, PERFORMANCE, TESTING, GLOSSARY
│   └── adr/            # Architecture Decision Records (the "why")
├── Sources/
│   ├── AjarCore/       # headless engine core (pure Swift)
│   ├── AjarRender/     # Metal compositor (macOS)
│   ├── AjarMedia/      # decode/encode + FFmpeg import boundary (macOS)
│   ├── AjarAudio/      # real-time audio graph (macOS)
│   └── ajar-cli/       # `ajar` headless render / bench / golden-frame harness
├── Tests/              # unit, property, golden-frame, integration
├── Benchmarks/         # performance gates
├── app/EditorAjar/     # the SwiftUI app (added at M2)
├── Package.swift
└── CLAUDE.md           # operating guide for the autonomous build agent
```

## Building

Requires macOS 14+ and a recent Xcode / Swift toolchain.

```bash
swift build        # build the engine modules + ajar CLI
swift test         # run the test suites
```

The `app/EditorAjar` Xcode project is added at [milestone M2](docs/ROADMAP.md).

## How it's built

Editor Ajar is built largely by an **autonomous coding loop** with human review, driven by the
[spec](docs/SPEC.md), [roadmap](docs/ROADMAP.md), and [ADRs](docs/adr/). The contract that makes
that safe — the Definition of Done and CI quality gates — is in
[docs/TESTING.md](docs/TESTING.md) and [ADR-0011](docs/adr/0011-testing-and-quality-gates.md).
The agent's operating guide is [CLAUDE.md](CLAUDE.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Significant
changes start with an [ADR](docs/adr/).

## License

[GPL-3.0-or-later](LICENSE) ([ADR-0004](docs/adr/0004-license-gplv3.md)). © 2026 Editor Ajar
contributors.
