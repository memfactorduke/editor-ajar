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

## M9 — Delivery, proxies & 1.0 hardening *(started)*

**Goal:** ship-quality export and the full performance/stability bar.
**Delivers:** export H.264/HEVC/ProRes via hardware encode, presets, ranges, stills, audio-only
(FR-EXP-001…004); **background export queue** (FR-EXP-005); **proxy/optimized media** pipeline +
toggle (FR-MED-004); relink/consolidate polish (FR-MED-007/008); full accessibility
(NFR-A11Y-001) and localization-readiness (NFR-I18N-001); meet **every** NFR in SPEC §5.
**Exit:** export golden-frame/round-trip tests (FR-EXP-007); the entire benchmark suite green on
the reference machine; crash-free + soak targets met; release candidate.
**Depends on:** all prior.

**Current status:** M9 started with #213 / ADR-0019: the new `AjarExport` module implements the
FR-EXP-001/002 engine, typed settings, deterministic sequential render-graph pulls, offline-mixed
audio, color-tagged H.264/HEVC/ProRes output, and an atomic cancel-safe session lifecycle. Presets,
range-selection UI/stills/audio-only, the FR-EXP-005 queue, proxies, and the remaining 1.0
hardening stay in later M9 slices.

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
