# ADR-0010: Color-managed, linear-light pipeline

- **Status:** Accepted
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** color, rendering, correctness

## Context

Correct compositing — especially chroma-key edges, blends, opacity, and transitions
(FR-COMP-007) — requires operating in linear light, not gamma-encoded values. Sources arrive in
varied color spaces (Rec.709, sRGB, Display-P3, and HDR HLG/PQ Rec.2020), and output must be
correctly tagged for the delivery space (FR-EXP-002, NFR-QUAL-002). Doing math in the wrong space
produces dark fringes, wrong blends, and banding.

## Decision

We adopt an explicit, **color-managed pipeline**:

- Every source is tagged with (or assigned) a color space on import; the render graph carries
  color space on its edges.
- Compositing, blending, keying, and effects are performed in a **linear-light working space** at
  **≥ 10-bit** precision (half-float on GPU) to avoid banding (FR-COL-008).
- Conversions (decode-space → working-space → display/delivery-space) are **explicit nodes** in
  the graph (ADR-0009), so they are visible, testable, and cache-correct.
- HDR sources are **tone-mapped** to the timeline/working space for v1; an **HDR timeline + export**
  is a v1.x extension (FR-COL-006).
- Output is converted to the project's delivery space and **tagged** correctly on export.

## Consequences

- Correct edges/blends/keys and accurate color round-trips (NFR-QUAL-002).
- Determinism is preserved: conversions are defined transforms, bounded by golden-frame tolerance
  (ADR-0011).
- Scopes (FR-COL-003) measure the defined working/clip spaces consistently.
- **Costs:** conversion nodes add GPU work (budgeted); we must maintain accurate transfer/primaries
  math and test it; full HDR mastering is deferred to v1.x.

## Alternatives considered

- **Composite in gamma/display space (naïve).** Cheapest, but visibly wrong edges/blends —
  unacceptable for a keying-focused editor.
- **Defer color management to "later".** Retrofitting a managed pipeline after effects are written
  is expensive and error-prone; it must be foundational (sequenced at ROADMAP M5).
- **Full ACES/OCIO pipeline.** More than v1 needs; revisit if we move toward finishing features.

## References

- SPEC §6.5 (COMP), §6.7 (COL), §6.13 (EXP), NFR-QUAL-002.
- [ADR-0006](0006-gpu-compositing-metal.md), [ADR-0009](0009-render-graph-and-caching.md).
