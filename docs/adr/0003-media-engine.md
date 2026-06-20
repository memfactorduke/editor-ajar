# ADR-0003: Hybrid media engine — AVFoundation/VideoToolbox fast path + FFmpeg at the import boundary

- **Status:** Accepted
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** media, performance, formats, licensing

## Context

The editor must play back and export common formats with real-time, hardware-accelerated
performance (SPEC §5, FR-MED, FR-EXP) **and** open the long tail of formats users actually have
(VP9/AV1-in-MKV, legacy codecs) without compromising that performance or stability. Pure
Apple-native maximizes speed but can't open everything; pure FFmpeg opens everything but isn't the
fastest or lowest-latency path on Apple Silicon and complicates the GPU handoff.

## Decision

We will use a **hybrid** media engine:

1. **Fast path (playback + export):** AVFoundation + VideoToolbox for H.264/HEVC/ProRes and common
   stills, with hardware decode/encode and zero-copy `CVPixelBuffer` → Metal texture interop. The
   real-time playback/render pipeline only ever handles this well-behaved, hardware-friendly set.
2. **Import boundary (FFmpeg):** on import, any source AVFoundation can't open natively is probed
   and **transcoded by FFmpeg to ProRes** (or decoded to frames). FFmpeg therefore runs only at
   ingest/transcode — **never on the playback hot path**.

This keeps FFmpeg cleanly separable (a boundary component), which also simplifies licensing
(ADR-0004).

## Consequences

- Native hardware speed and low latency where it matters (the playback/scrub/export path).
- Universal format coverage via FFmpeg, isolated from performance-critical code.
- Proxy/optimized-media (FR-MED-004) reuses the same transcode machinery.
- **Costs:** import of exotic formats does work up front (transcode time, disk for the working
  copy); we must maintain the FFmpeg integration and its licensing hygiene.
- An invariant for CI/architecture: no FFmpeg calls on the playback pipeline (only at import/
  transcode and offline tooling).

## Alternatives considered

- **Apple-native only.** Simplest and fastest, but can't open formats users have; rejected for a
  "fully featured" goal.
- **FFmpeg-based everything.** Maximum coverage and portability, but not the lowest-latency path
  on Apple Silicon, more GPU glue for real-time playback, and pulls GPL deeper into the core.
- **libav directly with custom HW accel.** Reinventing what VideoToolbox already does well.

## References

- SPEC §6.1 (MED), §6.13 (EXP), §8 (supported media).
- [ADR-0002](0002-platform-and-language.md), [ADR-0004](0004-license-gplv3.md),
  [ADR-0006](0006-gpu-compositing-metal.md).
