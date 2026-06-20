# ADR-0006: GPU compositing on Metal

- **Status:** Accepted
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** rendering, performance, gpu

## Context

Compositing, transforms, keying, masks, color, and effects must run in real time at up to 4K
(SPEC §5), with zero-copy from hardware decoders and no CPU readback on the playback path
(PERFORMANCE §6). We need a GPU API that is first-class on Apple Silicon and interoperates with
VideoToolbox and Core Video.

## Decision

We will implement the compositor and all pixel effects in **Metal**, executing the render graph
(ADR-0009) in `AjarRender`. Source frames arrive as Metal textures via `CVMetalTextureCache`
(zero-copy from VideoToolbox). Effects/transitions/keying are Metal compute or fragment shaders.
We will use **MetalFX** where it helps (e.g. high-quality upscaling for adaptive preview, optional
optical-flow assistance). **Core Image** may be used selectively for a few stock filters where it
is competitive, but the primary, performance-critical path is hand-written Metal.

## Consequences

- Maximum GPU performance and tight interop with the hardware decode/encode path (ADR-0003).
- Full control over precision (≥ 10-bit, linear-light working space — ADR-0010) and over the
  per-node GPU cost budget the benchmarks enforce (PERFORMANCE §3).
- A shared shader/effect-node abstraction also underpins the plugin API (ADR-0013).
- **Costs:** writing and maintaining Metal shaders is more work than gluing high-level filters;
  we need GPU-capable CI runners for golden-frame/perf tests.
- Effects must be authored to avoid CPU readback and host-sync stalls (a review checklist item).

## Alternatives considered

- **Core Image for everything.** Quick to build, but less control over precision, scheduling, and
  cost; harder to guarantee the perf budget and color correctness.
- **OpenGL.** Deprecated on macOS; non-starter.
- **wgpu / cross-platform GPU.** Only relevant if we go cross-platform (we are not — ADR-0002);
  adds a layer over Metal for no v1 benefit.

## References

- SPEC §5, §6.5 (COMP), §6.10 (FX). [ARCHITECTURE §4](../ARCHITECTURE.md).
- [ADR-0003](0003-media-engine.md), [ADR-0009](0009-render-graph-and-caching.md),
  [ADR-0010](0010-color-management.md), [ADR-0013](0013-plugin-architecture.md).
