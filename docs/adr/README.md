# Architecture Decision Records

This directory records the significant decisions behind Editor Ajar — the *why* behind the
[SPEC](../SPEC.md) and [ARCHITECTURE](../ARCHITECTURE.md). The format and process are defined in
[ADR-0001](0001-record-architecture-decisions.md).

These records are **load-bearing for the autonomous build loop**: the agent treats Accepted ADRs
as constraints. Changing a decision means writing a new ADR that supersedes the old one — never
silently editing code against an Accepted ADR.

| ADR | Title | Status |
|-----|-------|--------|
| [0000](0000-adr-template.md) | ADR template | — |
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-platform-and-language.md) | macOS-native, Swift + Apple frameworks | Accepted |
| [0003](0003-media-engine.md) | Hybrid media engine: AVFoundation/VideoToolbox + FFmpeg boundary | Accepted |
| [0004](0004-license-gplv3.md) | License: GPLv3-or-later | Accepted |
| [0005](0005-core-ui-separation.md) | Headless core / thin UI separation | Accepted |
| [0006](0006-gpu-compositing-metal.md) | GPU compositing on Metal | Accepted |
| [0007](0007-project-file-format.md) | `.ajar` project file format | Accepted |
| [0008](0008-timeline-data-model.md) | Timeline data model: immutable values + command reducer | Accepted |
| [0009](0009-render-graph-and-caching.md) | Render graph + content-hash caching | Accepted |
| [0010](0010-color-management.md) | Color-managed linear-light pipeline | Accepted |
| [0011](0011-testing-and-quality-gates.md) | Testing strategy & CI quality gates | Accepted |
| [0012](0012-concurrency-and-threading.md) | Concurrency & threading model | Accepted |
| [0013](0013-plugin-architecture.md) | Plugin architecture (Metal + manifest) | Accepted (target v1.x) |
| [0014](0014-autonomous-build-loop.md) | Autonomous build-loop readiness | Accepted |
| [0015](0015-audio-crossfade-overlap-model.md) | Audio crossfade overlap model: fade tail past the cut | Accepted |
| [0016](0016-effects-and-transitions.md) | Effects and transitions architecture | Accepted |
| [0017](0017-title-rendering.md) | Title rendering architecture: Core model + CoreText rasterization | Accepted |
| [0018](0018-schema-minor-versioning.md) | Schema minor versioning and forward-compatible opens | Accepted |
| [0019](0019-export-pipeline-architecture.md) | Export pipeline architecture | Accepted |

To add one: copy `0000-adr-template.md` to the next number, fill it in, set status, and add a row
here.
