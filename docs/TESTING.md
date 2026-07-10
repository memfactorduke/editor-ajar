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
| **Soak** | seeded edit+render loop for leaks/stability, §8 (NFR-STAB-005) | short: every PR · full 1-hour: pre-release | ~3 min / 1 h |
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

### 2b. Export golden (FR-EXP-007)

- `ajar golden-export [Tests/Fixtures/golden-export]` runs movie/still cases through the real
  `ExportSession`, decodes the output, and compares to the **live** render-path delivery BGRA
  (not a stored PNG reference for movie codecs).
- Tolerances are codec-banded in `ExportGoldenTolerance` (ProRes near-lossless; H.264/HEVC lossy;
  still PNG bit-exact). H.264/HEVC skip cleanly when the hardware encoder is unavailable.
- Determinism tests hash decoded pixel buffers (and PCM when present) across two exports — never
  container bytes.

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
         └─ golden-frame + golden-export (FR-EXP-007) + golden-audio
             └─ integration round-trips
                 └─ benchmarks vs. baseline   (gated NFRs)
                     └─ UI smoke
```

A short soak (§8) runs per PR in parallel with the gates above. Nightly adds: fuzz corpus,
expanded benchmark matrix (secondary HW tier).

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

## 8. Soak testing (NFR-STAB-005)

`ajar soak` is the headless leak/allocations harness. Each iteration runs a deterministic,
seeded scripted loop (SplitMix64; the seed is printed in the run header and settable with
`--seed`, so failures replay exactly): edits through `EditReducer`/`EditHistory` with full
undo/redo replay (blade, trim, constant-speed retime, time-remap, compound make + decompose,
crossfade add + remove), render-graph builds, offline renders (audio always, incl. compound
audio source caching; video via the CLI decode/texture path when a GPU is present), realtime
plan publish/consume handoff cycles (`ownedPointer` slot reclamation), and disk-frame-cache
persist/lookup/quarantine/reset churn across cycled synthetic project variants. Iterations run
inside autoreleasepool boundaries so measured growth is real, not pool noise.

After a warmup (default 3 iterations, excluded while caches and driver pools fill), the
process footprint (mach `task_info` `phys_footprint`; raw resident size is reported alongside)
is sampled every iteration. The run fails with a typed error and the growth curve when:

1. **Band** — any post-warmup sample rises more than the growth band above the baseline-window
   median (default 64 MiB — roughly 10x the observed benign malloc/driver-pool jitter, far
   below what a real per-iteration leak accumulates); or
2. **Quartile monotonic** — the four post-warmup quartile means increase strictly monotonically
   by more than 8 MiB; or
3. **Fitted slope** — with 2,000+ post-warmup samples, the least-squares fitted growth across
   the window exceeds 8 MiB. This catches the slow linear leak the first two checks provably
   cannot: linear growth just under ~10.7 MiB/hour keeps the quartile-mean rise at the 8 MiB
   tolerance and stays inside the band for hours. The 2,000-sample floor exists because the
   fitted-growth noise is ~`jitter * sqrt(12 / n)`: at ~15 MiB worst-case per-sample jitter
   that is ~1.2 MiB at n = 2,000 (threshold ~6.5 sigma above noise — cannot flake) but several
   MiB at short-run counts, where a slope verdict would be jitter, not signal.

**Detection floor** (what NFR-STAB-005 sign-off does and does not attest):

- **150 s PR gate** (~150–500 iterations, below the slope floor): catches any-shape growth
  over 64 MiB within the window and strictly-monotonic trends over 8 MiB within the window.
  Slower leaks are invisible per-PR *by design* — short runs are jitter-dominated.
- **3600 s acceptance run** (~12,000 iterations at ~0.3 s/iteration): the slope check binds —
  fitted linear growth above **8 MiB/hour (~0.7 KiB/iteration)** fails (fit noise ~0.5 MiB at
  that sample count). Leaks below ~8 MiB/hour, or growth confined to the warmup, remain below
  the gate's detection floor and are out of scope of the sign-off.

Cadence: CI runs `ajar soak --duration-seconds 150` on every PR (~3 minutes,
`timeout-minutes: 10` so a hang fails fast). The **NFR-STAB-005 acceptance run** is the full
1-hour soak — `ajar soak --duration-seconds 3600` — executed before releases (nightly wiring
may adopt it later).
