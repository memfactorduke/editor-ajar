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
| **Sanitizers** | Thread Sanitizer on the concurrency-relevant suite (NFR-STAB-004); Address Sanitizer forthcoming on the reference runner | every PR (TSan) | min |
| **UI smoke** | app launches, opens a project, plays; **AX tree walk** asserts every interactive role has a VoiceOver label (NFR-A11Y-001); canvas edit/nudge smokes are local-only (#210) | every PR | min |
| **Release acceptance** | app-model end-to-end usable-app journey (create → import → edit → compound make/open/edit/return → save/reopen → ProRes export decode → decompose/undo); H.264 capability-skipped on encoder-less runners (#236/#269) | every PR (EditorAjarTests / ui-smoke) | seconds–min |

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

The **Thread Sanitizer** gate (`sanitizers` job, NFR-STAB-004 / ADR-0012) also runs per PR in
parallel. It runs `swift test --sanitize=thread` over the concurrency surfaces — the export
queue/session/writer state machine, the real-time audio plan handoff, the seeded soak loop, and
the executor's concurrent-render guard — with `TSAN_OPTIONS=halt_on_error=1` so any **unsuppressed**
data race fails the job (TSan otherwise only warns and exits 0). GPU golden / media-decode tests are
excluded: their cross-thread ordering is owned by Metal/AVFoundation, not our code, and TSan cannot
see through those frameworks. Known framework false positives (Metal command-buffer completion
handlers) are documented, narrowly, in `.tsan-suppressions.txt` — a reviewed commit, never a way to
hide a real race. Sanitizer-runtime SEGV/signal flakes are retried up to twice, while race reports
and ordinary test failures fail immediately. Full-suite TSan plus Address Sanitizer join the matrix
on the dedicated reference runner (PERFORMANCE §1).

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

## 9. Release acceptance (usable-app journey, #236)

The final release gate is an **app-model** end-to-end test — not a UI automation script — so it
is deterministic, CI-runnable, and diagnostic on failure. Implementation:
`app/EditorAjar/Tests/EditorAjarReleaseAcceptanceTests.swift` (`EditorAjarTests` target).

### Journey (every step asserts; typed refusals fail the test)

1. **Create project** from New Project sheet defaults (`EditorAjarNewProjectSettings.sensibleDefaults`).
2. **Import** three temp fixtures via the production import pipeline: a short **ProRes** synthetic
   movie (CI-safe real encode), a solid **PNG** still, and an **audio** placeholder whose probe
   result is injected (same temp-file + injectable-probe pattern as the import app-model tests;
   real codecs are used where CI-safe).
3. **Verify media pool** membership (video + still + audio).
4. **Place clips** with `insertMediaOnTimeline` and a drag-equivalent `moveSelectedClip`.
5. **Blade** one video clip at the playhead mid-point.
6. **Apply** one effect (gaussian blur), one color correction (exposure), and a **styled title**
   (`insertTitleAtPlayhead` + font weight/size).
7. **Audio fade** via `applyDefaultFadeInToSelectedAudioClip`.
8. **Save** to a temp `.ajar` package, **reopen**, and assert **full `Project` equality**.
9. **Export ProRes** through `enqueueActiveSequenceExport` (production queue + Metal render path),
   decode with `ExportMovieDecoder`, and assert frame count + non-trivial pixel content.
10. **Undo-count sanity** on the pre-save edit history (non-empty multi-step journey).

Document lifecycle coverage additionally seeds an older package-local recovery snapshot before an
explicit Save, then proves reopen selects the newly saved canonical project. An injected failure
after staged contents publish verifies that canonical files and the prior recovery checkpoint roll
back together. A symlink fixture proves Save never follows a package recovery entry to write
outside the document. A split-generation canonical pair proves Open falls back to the matching
complete recovery envelope only when a unique Save marker binds the exact canonical transition and
every authoritative recovery file. The suite verifies that those files, `recovery/`, and the package
directory cross macOS `F_FULLFSYNC` ordering barriers before canonical publication. An injected
barrier failure must restore recovery while preserving the canonical files' bytes and file numbers,
proving those saved files were not needlessly republished; the same fixture uses a legacy-minimal
recovery directory with no optional manifest or journal. Preserved opaque recovery sidecars,
including nested directory trees, are synchronized from files to parent directories without
following symbolic links. Canonical publication coverage requires each temporary and renamed
project/media file, the staged and published version tree, and the package directory entries to
cross their durability barriers before the successful-Save boundary. Symlinked canonical manifests
must fail before publication without changing their external target, package peer, or package
entries. Corrupting the marker's manifest or restoring a stale marker while only the unchanged media
file matches must fail closed.
Addition and removal fixtures cover both old/new canonical file orderings that later replacements
can leave after power loss. A valid recovery stays dirty until it is saved again (FR-PROJ-002,
NFR-STAB-002). The repair Save must retain only decodable version snapshots and must not archive the
split pair.

### Hardware-only extension

`testReleaseAcceptanceH264ExportHardwareOnly` repeats a compact edit path and enqueues an H.264
export. On runners without a free hardware encoder it **capability-skips** cleanly (same
`ExportError.isHardwareEncoderUnavailable(for: .h264)` discipline as golden-export / throughput
benches). ProRes remains the hard CI pass.

### Where it runs

- **CI:** `ui-smoke` job → `xcodebuild test -only-testing:EditorAjarTests` (see
  `.github/workflows/ci.yml`). The `EditorAjarCI` test plan does **not** skip these classes.
- **Local:** same target via the `EditorAjar` scheme / `EditorAjarCI` plan; not part of root
  `swift test` (package tests stay headless).
