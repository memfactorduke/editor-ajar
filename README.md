<div align="center">

# Editor Ajar

**A fast, native, open-source video editor for macOS.**

*The door, left ajar — open source, open formats, approachable.*

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Status](https://img.shields.io/badge/status-v1%20source%20release-blue)

</div>

---

> **Status:** the v1 editor implementation and release-acceptance journey are complete. The source
> builds today; an ordinary-user download is a separate signed and notarized release gate. See
> [Release packaging](#release-packaging) for the exact distinction.

## Why

Popular consumer editors are cross-platform ports that feel sluggish and unstable on the Mac —
slow launches, laggy scrubbing, beachballs, lost work. Editor Ajar is a bet that a **Mac-native**
editor built directly on Apple's hardware media pipeline can be dramatically faster and more
stable, while still being **fully featured, professional, and good-looking**.

Two priorities sit above everything else (they are merge gates, not slogans):

- **Stability** — never crash, never lose work.
- **Performance** — real-time playback and instant scrubbing at the [target specs](docs/PERFORMANCE.md).

## What v1 does

The current app exposes multi-track timeline editing; move, zoom, rotate, crop, and opacity
transforms; parameter keyframes; chroma/luma keying, rectangle/ellipse masks, and blend modes;
color correction, scopes, and LUTs; multitrack mixing and fades; titles and animated text; effects
and transitions; constant-speed, reverse, and freeze controls; proxies and cached playback; and
hardware-accelerated H.264, HEVC, and ProRes export.

Some deeper engine capabilities do not yet have consumer-facing controls. The curve editor, speed
ramp editor, compound-clip workflows, free-form mask drawing, automatic ducking setup, media
consolidation, background-render scheduling, and HDR ingest/export are explicitly tracked for
v1.x in [ADR-0020](docs/adr/0020-v1-scope-deferrals.md). We do not present those as shipped UI.

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

To build the macOS app itself without Apple credentials:

```bash
xcodebuild -project app/EditorAjar/EditorAjar.xcodeproj -scheme EditorAjar \
  -configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## Release packaging

The reproducible local packaging path builds a macOS 14+, arm64 Release app and emits an artifact
whose filename and included warning identify it as unsuitable for consumers:

```bash
scripts/package-release.sh --mode unsigned --version 1.1.0
```

Signed consumer artifacts are produced only by the fail-closed Developer ID + hardened-runtime +
notarization path. Exact credentials, production steps, verification output, and rollback are in
**[docs/RELEASING.md](docs/RELEASING.md)**. Until a real production artifact passes Gatekeeper on a
clean supported Mac, a source tag is not the same thing as a consumer-ready release.

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
