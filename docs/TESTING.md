# Editor Ajar — Testing & Quality Strategy

> **Status:** Draft v0.1 · Implements the Definition of Done in [SPEC §11](SPEC.md#11-quality-testing--acceptance)
> and the gates in ADR-0011. This is how the autonomous loop knows a change is safe to merge.

The test suite is the contract that lets an unattended agent make progress without a human
watching every diff. If it's not tested, it's not done.

## 1. Test layers

| Layer | Scope | Runs where | Speed |
|-------|-------|-----------|-------|
| **Unit** | `AjarCore` logic: model edits, command reducer, keyframe interpolation, time math, render-graph construction, `.ajar` (de)serialization | headless, every PR | milliseconds |
| **Property-based** | invariants: edits never overlap clips on a track, undo∘do = identity, round-trip serialize/parse, no compound cycles | headless, every PR | fast |
| **Golden-frame** | rendered pixels for transforms, chroma key, masks, blends, color, transitions, text | `ajar` CLI + GPU runner, every PR | seconds |
| **Golden-audio** | rendered audio buffers for gain/pan/fades/ducking | runner, every PR | seconds |
| **Integration** | import → edit → render → export round-trips; relink; proxy on/off equivalence | runner, every PR | seconds–min |
| **Benchmark** | the SPEC §5 NFRs on the reference machine | reference runner, every PR | min |
| **Fuzz** | importers + project loader against malformed/truncated input (NFR-STAB-006) | nightly + corpus on PR | min |
| **Soak** | 1-hour edit+playback for leaks/stability (NFR-STAB-005) | nightly | long |
| **Sanitizers** | Thread + Address Sanitizer on unit/integration (NFR-STAB-004) | every PR | min |
| **UI smoke** | app launches, opens a project, plays, exports (XCUITest, minimal) | every PR | min |

## 2. Golden-frame testing (the core visual gate)

- A golden test = a tiny project (or programmatic graph) + a frame time + a stored reference PNG.
- The `ajar render --frame <t> <project>` CLI produces the actual frame **deterministically**
  (same graph → same pixels, ADR-0009/0011).
- Comparison is **perceptual within tolerance** (e.g. per-pixel ΔE + an SSIM floor), not exact
  bit-equality, to tolerate benign GPU/driver differences. Tolerances are per-test and explicit.
- On failure the runner writes `_actual/` and a `_diff/` heatmap next to the golden for human
  review (ignored by git). Updating a golden is a deliberate, reviewed commit — never automatic.
- Goldens live under `Tests/Fixtures/golden/`; source media is tiny or synthetic.

## 3. Determinism rules (what makes the above possible)

- All time is `RationalTime`; no float frame indices.
- Render-graph build is pure; no wall-clock, no RNG without a seeded, recorded seed.
- Effects declare their parameters fully; no hidden global state.
- Floating-point compositing differences are bounded by the working-space spec (ADR-0010) and
  absorbed by tolerance.

## 4. Definition of Done (per task — the loop checks all five)

A change is merge-eligible only when:

1. Functional requirement(s) it targets are met and referenced by ID in the new tests.
2. New `AjarCore` logic has unit/property tests; pixel/audio changes have golden tests.
3. The **benchmark suite stays green** — no gated NFR regresses beyond its noise band.
4. UI additions are keyboard-accessible and VoiceOver-labelled (smoke + manual checklist).
5. Lint/format clean (incl. the no-force-unwrap rule in `AjarCore`), sanitizers clean, docs +
   CHANGELOG updated.

## 5. CI gates (ADR-0011)

On every PR, in order, failing fast:

```
build (all modules, warnings-as-errors in AjarCore)
 └─ lint + format check
     └─ unit + property tests        (+ Thread/Address Sanitizer)
         └─ golden-frame + golden-audio
             └─ integration round-trips
                 └─ benchmarks vs. baseline   (gated NFRs)
                     └─ UI smoke
```

Nightly adds: fuzz corpus, 1-hour soak, expanded benchmark matrix (secondary HW tier).

## 6. Coverage & traceability

- Every SPEC requirement ID should map to ≥ 1 test. A requirement with no covering test is
  reported as **unimplemented** by the traceability check (SPEC §12), regardless of code.
- Coverage is tracked for `AjarCore` (target high; it's pure logic) and reported, not hard-gated,
  for platform modules.

## 7. Test data policy

- Commit only tiny fixtures and synthetic generators. Large media is produced by `scripts/`
  (e.g. `gen-fixtures.sh`) or fetched to a local cache, never committed (see `.gitignore`).
- Synthetic media (color bars, gradients, moving shapes, tone) gives exact, license-free,
  deterministic inputs for most visual/audio goldens.
