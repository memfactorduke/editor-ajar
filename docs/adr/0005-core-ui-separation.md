# ADR-0005: Headless core / thin UI separation

- **Status:** Accepted
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** architecture, testability, stability

## Context

Two forces dominate: we want the highest possible stability/performance (SPEC §5), and we want an
autonomous loop to build most of the system with confidence (ADR-0014). GUI code is hard to test
unattended; editing logic, by contrast, is pure and very testable. Mixing them couples the part we
can verify cheaply to the part we can't.

## Decision

We will split the system so that **all editing logic, the data model, keyframe evaluation, the
render-graph description, and project (de)serialization live in `AjarCore` — a pure-Swift module
with no UI and no GPU dependency** — and the application (`EditorAjar`) is a thin SwiftUI/AppKit
shell on top. Platform capabilities live in `AjarRender` (Metal), `AjarMedia` (AVFoundation/
FFmpeg), and `AjarAudio` (Core Audio). The dependency graph points downward only:

```
EditorAjar → {AjarRender, AjarMedia, AjarAudio} → AjarCore → (nothing in-project)
```

`AjarCore` **must not import** AppKit, SwiftUI, Metal, or AVFoundation. This is enforced in CI.

## Consequences

- The majority of behavior is covered by fast, deterministic **headless unit tests**; pixels are
  verified via the `ajar` CLI golden-frame harness — minimal GUI automation needed (ADR-0011,
  ADR-0014).
- The core is small enough to reason about, fuzz, and hold to a no-crash standard (NFR-STAB-003).
- Clear seams enable caching and scheduling decisions to be made on data before touching the GPU.
- A future iPad or alternate backend could reuse `AjarCore` unchanged (not a v1 goal).
- **Cost:** some boilerplate at the boundary (the core exposes data/protocols the shell adapts to);
  we accept it for the testability and stability payoff.

## Alternatives considered

- **Monolithic app target.** Faster to start, but couples testable logic to untestable UI and
  invites architectural drift; bad fit for an unattended loop.
- **Split only UI vs. "backend" without the platform-module separation.** Loses the clean "core
  imports no GPU/UI" invariant that makes headless testing trivially enforceable.

## References

- [ARCHITECTURE §1–2](../ARCHITECTURE.md), SPEC §5, §11.
- [ADR-0011](0011-testing-and-quality-gates.md), [ADR-0014](0014-autonomous-build-loop.md).
