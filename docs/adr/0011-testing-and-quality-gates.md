# ADR-0011: Testing strategy & CI quality gates

- **Status:** Accepted
- **Date:** 2026-06-20
- **Deciders:** Mem
- **Tags:** testing, ci, quality, autonomy

## Context

An autonomous loop (ADR-0014) can only be trusted to merge work if "correct" is machine-checkable.
We need gates that catch functional regressions, visual/audio regressions, **performance**
regressions (the product's whole point), and stability defects — without a human inspecting every
diff.

## Decision

We adopt the layered strategy in [TESTING](../TESTING.md) and enforce it as **ordered CI gates**
on every PR; a change is merge-eligible only if all pass (the Definition of Done, TESTING §4):

```
build (warnings-as-errors in AjarCore; dependency-rule check: core imports no UI/GPU)
 └─ lint + format (incl. no force-unwrap/try!/fatalError in AjarCore — NFR-STAB-003)
     └─ unit + property tests   (+ Thread & Address Sanitizer — NFR-STAB-004)
         └─ golden-frame + golden-audio (deterministic, perceptual tolerance)
             └─ integration round-trips (import→edit→render→export; proxy≡original)
                 └─ benchmarks vs. baseline  (gated NFRs from SPEC §5 — fail on regression)
                     └─ UI smoke (launch/open/play/export)
```

Key rules:
- **Golden-frame/audio** comparisons use explicit per-test perceptual tolerance, never bit-equality
  (absorbs benign GPU differences); updating a golden is a deliberate, reviewed commit.
- **Benchmarks** run on the reference machine (PERFORMANCE §1) and fail a PR that regresses a gated
  metric beyond its noise band (default 5%). Baselines change only via reviewed commits.
- **Traceability:** each SPEC requirement maps to ≥ 1 test; uncovered requirements are reported as
  unimplemented (SPEC §12).
- Nightly: fuzz corpus (NFR-STAB-006), 1-hour soak (NFR-STAB-005), expanded benchmark matrix.

## Consequences

- The loop has an objective, fast-failing definition of "safe to merge", spanning correctness,
  visuals, performance, and stability.
- Determinism requirements (ADR-0008/0009/0010) are what make golden tests stable.
- **Costs:** GPU-capable CI runners and a dedicated, quiet reference machine for benchmarks;
  maintaining goldens and baselines; test runtime kept reasonable by tiered ordering.

## Alternatives considered

- **Unit tests only.** Misses the visual and (critically) performance regressions that define this
  product.
- **Manual QA gating.** Defeats the point of an unattended loop; doesn't scale; not reproducible.
- **Exact-match golden frames.** Too brittle across GPU/driver versions; perceptual tolerance is
  the standard solution.

## References

- [TESTING](../TESTING.md), [PERFORMANCE](../PERFORMANCE.md), SPEC §5, §11, §12.
- [ADR-0008](0008-timeline-data-model.md), [ADR-0009](0009-render-graph-and-caching.md),
  [ADR-0014](0014-autonomous-build-loop.md).
