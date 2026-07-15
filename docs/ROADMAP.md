# Editor Ajar — Roadmap

> **Status:** Draft v0.1 · Drives the build sequence. The autonomous loop (ADR-0014) consumes
> milestones **in order**; within a milestone it decomposes work into tasks, each held to the
> Definition of Done in [TESTING §4](TESTING.md#4-definition-of-done-per-task--the-loop-checks-all-five).

Milestones are vertical where possible: each ends with something runnable and tested, not a pile
of unintegrated parts. **Performance and stability gates (SPEC §5) apply continuously from M2
onward** — they are never deferred to "later".

Requirement areas referenced below are defined in [SPEC §6](SPEC.md#6-functional-specification).

---

## M0 — Foundations *(this repository)*

**Goal:** a coherent, buildable skeleton the loop can extend safely.
**Delivers:** SPEC, ARCHITECTURE, ADRs 0001–0014, glossary, performance & testing strategy;
Swift package with the module split; `ajar` CLI stub; CI gates; agent guide (`CLAUDE.md`).
**Exit criteria:** `swift build` succeeds; CI runs (lint, empty test suites, structure checks)
green; the dependency rule (AjarCore imports no UI/GPU) is enforced.

## M1 — Core model, time, project format, undo *(headless)*

**Goal:** the entire editing brain with no UI and no GPU.
**Delivers:** `RationalTime` math; `Project/Sequence/Track/Clip` model; `Animatable`/`Keyframe`
types; `EditCommand` reducer + unbounded undo/redo (FR-TL-012); `.ajar` (de)serialization +
versioning (FR-PROJ-001/005); media probing model (`MediaRef`).
**Exit:** comprehensive **unit + property tests** (round-trip, undo identity, no overlap, no
compound cycles); fuzz corpus for the project loader (NFR-STAB-006). Zero force-unwraps
(NFR-STAB-003).
**Depends on:** M0.

## M2 — Walking skeleton: render one frame, see it, save it

**Goal:** prove the whole pipeline end to end on the simplest case.
**Delivers:** render-graph build for a single clip (AjarCore); Metal compositor executing it
(AjarRender); zero-copy decode of one source (AjarMedia); on-screen playback of a 1-clip
sequence; minimal app shell (window, canvas, transport, bare timeline); open/save `.ajar`; the
**`ajar render --frame` golden-frame harness** working in CI.
**Exit:** first golden-frame tests pass; 1080p30 single-clip playback hits real-time with **0
dropped frames**; launch/seek benchmarks wired and within budget; UI smoke test launches+plays.
**Depends on:** M1. *This is the most important milestone — it makes everything afterward
measurable.*

## M3 — Editing & the timeline

**Goal:** a real multi-track timeline you can cut with.
**Delivers:** multiple video/audio tracks, lock/mute/solo/hide (FR-TL-001/002); insert/overwrite/
append/replace + three-point (FR-TL-003); blade, ripple/roll/slip/slide, ripple-delete/lift
(FR-TL-004/005); snapping, selection, markers, linked A/V (FR-TL-006/007/008/009); timeline zoom
+ navigation (FR-TL-010); multiple sequences/tabs (FR-TL-011); undo in the UI; auto-save +
crash recovery (FR-TL-014, NFR-STAB-002).
**Exit:** editing covered by unit/property tests; interaction at 60 fps (NFR-PERF-006);
keystroke→edit ≤ 50 ms (NFR-PERF-007); crash-recovery integration test.
**Depends on:** M2.

## M4 — Transforms & keyframing

**Goal:** move, scale, rotate, and animate anything.
**Delivers:** full transform set incl. zoom & rotation (FR-XFORM-001…005); on-canvas manipulation
(FR-XFORM-007); the keyframe system end-to-end (FR-KEY-001…005,007,009): inline keyframe lanes,
interpolation modes incl. Bézier, and the **curve editor**.
**Exit:** golden-frame tests for transforms at multiple keyframe times; keyframe interpolation
unit tests; multi-layer playback with transforms holds real-time (NFR-PERF-003).
**Depends on:** M3.

## M5 — Compositing, keying, masks & color foundation

**Goal:** green screen and correct compositing.
**Delivers:** **chroma key** with tolerance/softness/spill (FR-COMP-001/002); masks
(rect/ellipse/Bézier, feather, combine) (FR-COMP-003); blend modes + alpha (FR-COMP-005/006);
**color-managed linear-light pipeline** (ADR-0010, FR-COMP-007, FR-COL-005/008); primary color
correction (FR-COL-001); **scopes** (FR-COL-003).
**Exit:** golden-frame tests for keying/masks/blends; color round-trip within ΔE tolerance
(NFR-QUAL-002); 4K30 + chroma key holds real-time (NFR-PERF-004).
**Depends on:** M4.

## M6 — Audio

**Goal:** a real mix, glitch-free.
**Delivers:** multitrack audio, keyframable volume/pan (FR-AUD-001); waveforms, fades, crossfades
(FR-AUD-002); real-time **mixer** + meters (FR-AUD-003); **ducking** (FR-AUD-004); detach/replace
(FR-AUD-008); correct SRC/channel mapping (FR-AUD-009); allocation-free audio thread (FR-AUD-007).
**Exit:** golden-audio tests; A/V sync integration test; audio thread verified allocation-free;
no dropouts during a stress mix.
**Depends on:** M3 (timeline), parallelizable with M4/M5 after M3.

## M7 — Compound clips, nesting, caching & speed *(complete)*

**Goal:** structure and time control without losing real-time.
**Delivers:** compound clips: create/open/edit/propagate/decompose, nested with cycle detection
(FR-CMP-001…005); **render cache** (RAM+disk, content-hash keyed) incl. compound caching
(FR-CMP-006, FR-PLAY-005); speed: constant, **ramping**, reverse, freeze, frame-blend
(FR-SPD-001…005).
**Exit:** cache correctness + invalidation tests; cached compound playback holds real-time;
speed-ramp golden-frame tests; soak test stays leak-free (NFR-STAB-005).
**Depends on:** M4, M5.

**Current status:** M7 is complete. Compound create/decompose, nested video + audio, content-hash
RAM/disk cache, constant/ramp/reverse/freeze/frame-blend retiming, pitch-corrected audio, and the
FR-SPD-005 exit benchmarks all landed. Exit criteria met, including the 1-hour NFR-STAB-005
acceptance soak which passed 2026-07-09.

## M8 — Titles, effects, transitions & color depth *(complete)*

**Goal:** the creative toolkit.
**Delivers:** rich text titles + styling + on-canvas edit (FR-TXT-001…003,007); animated title
presets (FR-TXT-004); transitions library (FR-FX-001); core effects library (FR-FX-002/003);
curves + secondary color + **LUTs** (FR-COL-002/004); looks save/recall (FR-COL-007).
**Exit:** golden-frame tests across the effect/transition/title set; each effect within its GPU
cost budget (PERFORMANCE §3); playback stays real-time at target spec with a typical stack.
**Depends on:** M4, M5.

**Current status:** M8 is complete. The #191 exit review closed the remaining transition-golden,
styled-title metric, and typical-stack 1080p30 benchmark coverage. Titles, animation presets,
transitions, the core effects stack/library, curves, LUTs, and reusable looks now satisfy the M8
deliverables and exit gates.

## M9 — Delivery, proxies & 1.0 hardening *(complete — v1.0.0-rc1)*

**Goal:** ship-quality export and the full performance/stability bar.
**Delivers:** export H.264/HEVC/ProRes via hardware encode, presets, ranges, stills, audio-only
(FR-EXP-001…004); **background export queue** (FR-EXP-005); **proxy/optimized media** pipeline +
toggle (FR-MED-004); relink/consolidate polish (FR-MED-007/008); full accessibility
(NFR-A11Y-001) and localization-readiness (NFR-I18N-001); meet **every** NFR in SPEC §5.
**Exit:** export golden-frame/round-trip tests (FR-EXP-007); the entire benchmark suite green on
the reference machine; crash-free + soak targets met; release candidate.
**Depends on:** all prior.

**Current status: COMPLETE (2026-07-10, v1.0.0-rc1).** All M9 deliverables landed: export engine +
ADR-0019 (#213), presets/ranges/stills/audio-only (#215), background export queue (#216),
determinism/export-golden CI gate incl. a render-cache aliasing fix it flushed out (#214), proxy
pipeline with tier-safe caching (#217), relink/offline/consolidate (#218), accessibility audit +
AX-tree CI net (#219, resolves #210), string externalization (#220), and exit hardening (#230:
TSan CI gate, fatalError lint, P3 round-trip, export 3.07x / proxy-gen 21.6x throughput
benchmarks). NFR §5 audit, acceptance evidence (1-hour soak: 20,069 iterations, +3.5 MiB), and
accepted-posture notes are recorded on #221. Reference-machine benchmark gating remains deferred
per PERFORMANCE.md §4 (CI benchmarks stay report-only).

## M10 — Usable app shell *(started)*

**Goal:** turn the proven editor engine into an ordinary macOS document app that a user can start
with their own media instead of a developer sample.
**Delivers:** project New/Open/Recent/Save/Save As/Revert, settings and first-clip auto-detection
(FR-PROJ-001/002/003); video/audio/still and folder intake with native decode plus FFmpeg fallback
(FR-MED-001/002/003); a searchable list/grid media browser (FR-MED-005); incremental cached
thumbnails/waveforms (FR-MED-009); and visible variable-frame-rate detection/conform choices
(FR-MED-010).
**Work items:** #233 — project document lifecycle; #234, #235, and #236 — the remaining media
intake, browser/preview, fallback/VFR, and usable-shell integration slices.
**Exit:** launch offers New/Open; a user can create or reopen a package, safely save/revert it,
import supported/fallback media without blocking the UI, inspect/search that media, and place it
into a stable-timebase project with all keyboard/VoiceOver and recovery gates green.
**Depends on:** M9.

**Current status: COMPLETE (2026-07-11, v1.0.0).** M10 (#233-#235, #238) and M11 (#239-#247: timeline
gestures/transactions, color, audio, effects, titles, playback+cache, stills/auto-detect/relink,
ADR-0020 scope) delivered the full usable editor; #236's release-acceptance journey (create ->
import -> edit -> grade -> title -> mix -> save -> reopen -> export -> decode-verify) gates every
PR via CI. Release evidence on the v1.0.0 tag notes.

## M11 — v1 app-surface completion and acceptance *(complete)*

**Goal:** complete the shippable v1 editing surface and record the intentional v1.x boundary.
**Scope decision:** [ADR-0020](adr/0020-v1-scope-deferrals.md) records the advanced app-surface
deferrals found by the #239 audit, excludes shipped FR-PROJ-002 snapshots, and makes any
FR-PLAY-004/007 deferral conditional on measured performance after #245 wires the FR-PLAY-005
cache. The acceptance evidence must be recorded on #247 or its PR before the ADR is Accepted.
**Work items:** #240–#247.
**Depends on:** M10.

**Current status: COMPLETE (2026-07-11, v1.0.0).** Issues #240–#247 delivered the accepted v1
surface and recorded the intentional v1.x boundary in ADR-0020. The release-acceptance journey
continues to gate every PR.

## M12 — consumer distribution foundation *(pipeline complete; external credentials pending)*

**Goal:** turn the source release into a reproducible macOS consumer artifact without requiring
Apple credentials for ordinary contributors.
**Delivers:** version/tag and platform validation; a clearly marked unsigned test package; opt-in
Developer ID signing with hardened runtime; notarization, stapling, `codesign`, `spctl`, and
`stapler` verification; and a tag-aware GitHub release workflow that refuses to replace an
existing release asset.
**Work item:** #263.
**External exit gate:** provision the Apple Developer ID and App Store Connect notarization
credentials, run the production workflow, and prove the resulting download passes Gatekeeper on a
clean supported Apple Silicon Mac. Pipeline code alone does not satisfy this external gate.
**Depends on:** M11.

---

## Post-1.0 (v1.x / future)

Plugin API (ADR-0013, FR-FX-006), expanded effects, optical-flow slow-mo, HDR timeline
(FR-COL-006), smart bins (FR-MED-006), adjustment layers (FR-TL-013), title templates
(FR-TXT-006), corner-pin (FR-XFORM-006), animated masks/roto (FR-COMP-004), GIF export
(FR-EXP-006). Longer-horizon items (NLE interchange, stabilization, AI features, iPad,
cross-platform) live in [SPEC §13](SPEC.md#13-out-of-scope-for-v1--future).

## How the loop uses this file

1. Pick the lowest-numbered milestone that is not complete.
2. Decompose its deliverables into tasks, each tagged with the requirement IDs it satisfies.
3. Implement, satisfying the Definition of Done (TESTING §4) — including that **no gated NFR
   regresses**.
4. A milestone is complete only when its exit criteria are met by passing, committed tests.
5. Never start a milestone whose dependencies are unmet.
