# ADR-0002: macOS-native, Swift + Apple frameworks

- **Status:** Accepted
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** platform, language, performance, stability

## Context

The motivating problem is that popular cross-platform consumer editors feel slow and unstable on
the Mac. Editor Ajar's top priorities (SPEC §2, §5) are **performance** and **stability** on
macOS specifically. We must choose a platform target and an implementation language/UI stack that
maximize both, while remaining buildable by an autonomous loop and pleasant to contribute to.

## Decision

We will build Editor Ajar as a **macOS-native application written in Swift**, using Apple's
first-party frameworks: AVFoundation + VideoToolbox (media), Metal/MetalFX (GPU), Core Audio /
AVAudioEngine (audio), and AppKit + SwiftUI (UI). v1 targets macOS 14+ on Apple Silicon
(SPEC §10). Cross-platform support is explicitly out of scope for v1 (SPEC §13).

The editing engine is isolated from the UI as a separate, platform-agnostic Swift module
(`AjarCore`) per ADR-0005, so this decision does not preclude a future non-Mac backend; it simply
declines to pay for one now.

## Consequences

- **Best-in-class Mac performance/stability:** direct access to the hardware video pipeline
  (VideoToolbox), zero-copy GPU texture interop, and the platform's optimized composition/audio
  stacks. This is the most direct route to the NFRs in SPEC §5.
- **Less code to feature-complete:** AVFoundation provides decode/encode, composition primitives,
  and audio plumbing we would otherwise rebuild — fewer lines, fewer bugs, more stability.
- **Native look and feel** (SPEC principle 3), good accessibility via AppKit/SwiftUI.
- **Cost accepted:** Mac-only for v1; a future port would require new `AjarRender/Media/Audio`
  backends (the core would carry over).
- **Loop fit:** Swift has strong typing, `Sendable`/actor concurrency checking, XCTest, and
  sanitizer support — good for an unattended loop. The headless-core split (ADR-0005) keeps most
  work testable without GUI automation.

## Alternatives considered

- **Rust core + Swift UI.** Memory-safety and portability are attractive, but we would forgo
  AVFoundation's leverage and rebuild decode/compose/audio on FFmpeg + `wgpu`, which is more code
  and slightly less optimal on Apple Silicon than raw Metal/VideoToolbox. Chosen against for v1;
  revisit only if cross-platform becomes a hard requirement.
- **C++/Qt cross-platform (Kdenlive/Shotcut-style).** Mature and portable, but heavier and its
  Mac performance/feel won't match native — reintroducing the exact problem we're solving.
- **Electron / Tauri (web UI).** Fastest to a pretty UI, but real-time 4K playback and low-latency
  scrubbing are precisely where web stacks struggle; closest to the tools we're moving away from.

## References

- SPEC §2 (principles), §5 (NFRs), §10 (platform), §13 (non-goals).
- [ADR-0003](0003-media-engine.md), [ADR-0005](0005-core-ui-separation.md),
  [ADR-0006](0006-gpu-compositing-metal.md).
