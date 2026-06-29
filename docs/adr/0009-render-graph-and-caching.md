# ADR-0009: Render graph + content-hash caching

- **Status:** Accepted
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** rendering, performance, caching, determinism

## Context

To hold real-time playback at the target specs (SPEC §5) while supporting layered compositing,
effects, keying, color, and nested compound clips, we need to (a) decide exactly what to draw for
a given frame, (b) avoid recomputing unchanged work, and (c) do so deterministically for testing
(ADR-0011). Rendering directly from the editing model ad hoc would make caching and determinism
hard.

## Decision

`AjarCore` compiles the model, at a given sequence time, into an **immutable render graph**: a DAG
of typed nodes (`source`, `transform`, `colorConvert`, `effect`, `chromaKey`, `mask`, `blend`,
`composite`, …) with fully resolved parameters (all `Animatable`s evaluated, compound clips
expanded with cycle protection). Each node has a **content hash** derived from its type, resolved
parameters, and input hashes — its cache identity.

`AjarRender` executes the graph on Metal (ADR-0006). A **content-hash-keyed cache** (RAM + disk,
budgeted per ADR PERFORMANCE §2/§9) stores rendered frames and reusable intermediates. Editing a
clip changes only the hashes of affected nodes, so only the affected subgraph re-renders; unchanged
compound clips and segments replay from cache (FR-CMP-006, FR-PLAY-005). Background "render in
place" warms the cache at low priority (ADR-0012).

For compound clips, `AjarCore` emits a compound source node whose hash folds in the referenced
sequence render graph's output hash. `AjarRender` renders that nested graph to a GPU-private texture
and feeds it into the outer composite as the compound clip source. The in-memory cache is bounded
and hit-tested by content hash; disk cache warming remains a later M7 step.

## Consequences

- Fine-grained, correct cache invalidation for free (hash changes ⇒ recompute; else reuse).
- **Determinism:** same graph ⇒ same pixels, the precondition for golden-frame tests (ADR-0011).
- The graph is a clean target for the per-node GPU cost budget (PERFORMANCE §3) and for adaptive
  preview quality (FR-PLAY-004).
- Plugins slot in as effect nodes with the same contract (ADR-0013).
- **Costs:** building the graph each frame must stay cheap (< ~1 ms typical — measured); hashing
  must be fast and collision-safe; cache memory must be bounded and evicted (LRU).

## Alternatives considered

- **Render directly from the model per frame, no graph.** Simpler initially, but no clean caching
  or determinism story; couples rendering to model traversal.
- **`AVVideoComposition` / `AVMutableComposition` as the renderer.** Convenient for simple cases
  and useful for export plumbing, but too limiting for custom keying/masks/effects and the
  caching/precision control we need; we may still use AVFoundation for decode/encode (ADR-0003).
- **Retained scene graph mutated in place.** Invalidation becomes manual and bug-prone; conflicts
  with the immutable-value model (ADR-0008).

## References

- [ARCHITECTURE §4–5, §9](../ARCHITECTURE.md), SPEC §5, §6.12 (PLAY).
- [ADR-0006](0006-gpu-compositing-metal.md), [ADR-0008](0008-timeline-data-model.md),
  [ADR-0010](0010-color-management.md), [ADR-0011](0011-testing-and-quality-gates.md).
