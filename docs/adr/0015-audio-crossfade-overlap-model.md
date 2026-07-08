# ADR-0015: Audio crossfade overlap model — fade tail past the cut, abut-only timeline preserved

- **Status:** Proposed
- **Date:** 2026-07-07
- **Deciders:** Mem
- **Tags:** audio, model, editing, rendering, stability

## Context

FR-AUD-002 requires audio crossfades. ADR-0008 fixes the timeline invariant that items on a track
are **sorted and never overlap** (`ProjectValidation` rejects `itemsOverlap`), and much of the
codebase leans on it: the trim machinery (`Sources/AjarCore/Edit/TrimEditCommands.swift` — ripple,
roll, slip, slide, blade), gap semantics, and the video compositor's documented
"one active clip per track" contracts on `Track.opacity`/`Track.blendMode`.

PR #101 tried to render crossfades under that abut-only model by ramping the outgoing clip down
over its last *D* and the incoming clip up over its first *D*. Because the clips abut, the two
ramps are **sequential, never simultaneous**: at the cut both gains approach zero and the output
dips to silence — a notch audibly worse than a hard cut. It was reverted to validation-only
(`AudioCrossfadeValidator` checks partner existence, adjacency, and touching edges; nothing is
rendered). Issue #102 tracks doing it correctly.

A true crossfade requires both sources to be audible **at the same output frames** for the
transition duration *D*. The model already serializes the intent: `ClipAudioMix` carries optional
`leadingCrossfade`/`trailingCrossfade` (`ClipAudioCrossfade`: partner clip ID, duration, curve),
decoded with `nil` legacy defaults (ADR-0007). What is missing is a model of *where the second
source's samples come from*. Two candidates:

- **(a) Timeline overlap** — allow clips to occupy the same timeline frames (lanes or overlapping
  items on one track).
- **(b) Fade tail** — keep clips abutting; the outgoing clip's *source* keeps playing past its
  timeline out-point for *D*, mixed under the incoming clip.

## Decision

We choose **(b), the fade-tail model**. The timeline stays abut-only; a crossfade is derived
render-time behavior keyed off the existing `ClipAudioCrossfade` metadata. Specifically:

1. **Crossfade region.** For a cut at time *T* with crossfade duration *D*, the region is
   `[T, T + D)`. The outgoing clip's geometry still ends at *T* and the incoming clip still starts
   at *T*; no `timelineRange` changes. Because a trailing crossfade is only valid with an abutting
   partner, the region always lies inside the incoming clip — sequence duration and downstream
   timing never change when a crossfade is added, adjusted, or removed.
2. **Tail sampling.** Over the region the mixer continues evaluating the outgoing clip's existing
   source-time mapping past its out-point (constant `speed` extends linearly; `reverse` continues
   backward past `sourceRange.start`; `freezeFrame` keeps holding its frame; compound sources read
   the nested sequence past the window). Clips with a `timeRemap` curve reject trailing/leading
   crossfades with a typed validation error in v1 — extrapolating a keyframed curve is ambiguous
   and can be added by a later ADR if needed.
3. **Gain curve contract.** With `x ∈ [0, 1]` across the region, the mixer sums
   `out(t)·g_out(x) + in(t)·g_in(x)`:
   - **`equalPower` (the default for crossfades):** `g_in(x) = sin(πx/2)`, `g_out(x) = cos(πx/2)`,
     so `g_in² + g_out² = 1` — constant perceived loudness for **uncorrelated** program (the
     normal case: different recordings).
   - **`linear`:** `g_in(x) = x`, `g_out(x) = 1 − x`, so `g_in + g_out = 1` — constant amplitude
     for **correlated** content (e.g. a blade split of the same source), where equal-power would
     bump +3 dB at the midpoint.
   Crossfade edges accept **exactly** these two curves; `easeIn`/`easeOut`/`easeInOut` remain
   fade-to-silence-only and are rejected on crossfade edges with a typed error. `equalPower` is an
   additive `ClipAudioFadeCurve` case (raw-value string); legacy projects are unaffected.
   The two paired metadata records must agree in partner IDs, duration, and curve.
4. **Source-handle rule.** The outgoing media must have **tail content**: the source-time image of
   `[T, T + D)` under the clip's mapping must lie within the available media (e.g. `D × speed`
   past `sourceRange.end` for forward constant-rate). Edit commands that create or lengthen a
   crossfade clamp *D* to the available handle (clamping to zero is a typed rejection, not a
   silent no-op). If media drifts *after* validation (relinked to a shorter file), the render
   **never fails**: the tail is silence-padded past the available source, deterministically —
   stability outranks fidelity to stale metadata. Structural violations (missing/non-adjacent
   partner, disagreeing pair) stay typed `AudioRenderError`s as today.
5. **Edit interaction.** Because geometry is untouched, ripple/roll/slip/slide/blade (FR-TL-004),
   linked A/V (FR-TL-009), and ripple delete keep their existing abut-based logic. Any command
   whose result invalidates a crossfade (trimming away the handle, deleting or separating the
   partner) clamps or removes the metadata **in the same command**, so undo restores both
   geometry and crossfade exactly (command reducer, ADR-0008 / FR-TL-012).
6. **Render paths.** `OfflineAudioMixer` extends the outgoing clip's mix window by *D* and applies
   the curve contract; the realtime plan prepares tail frames ahead of time like any other source
   material — no allocation or locking on the audio thread (ADR-0012, FR-AUD-007). Crossfade
   fields are already part of the encoded clip payload, so any content hash derived from clip
   content (ADR-0009) already varies with them; no hash migration. The video render graph is
   untouched.

## Consequences

- The abut-only invariant survives intact: no changes to `ProjectValidation`, the trim commands,
  track compositing assumptions, or the video renderer. The blast radius is confined to audio
  validation and the two audio render paths — the smallest surface that can satisfy FR-AUD-002,
  which is what the stability and performance merge gates demand.
- **Zero `.ajar` geometry change.** The crossfade fields already round-trip with legacy `nil`
  defaults; the only codec delta is the additive `equalPower` raw value (needs an explicit
  nested-legacy decode test).
- Undo/redo stays trivially correct; performance cost is O(*D*) extra samples per transition on an
  already-accumulating mix loop.
- **Costs we accept:** a cut at the very end of the outgoing media cannot crossfade (standard NLE
  behavior — no handle, no transition); the region is post-cut (asymmetric), so a "centered"
  crossfade requires moving the cut — a symmetric head lead-in for the incoming clip is
  deliberately out of scope for v1; timeline UI must later visualize audio that is audible past a
  clip's drawn right edge (an overlay across the cut, not a lane).
- New invariants for tests/CI: pair agreement (partners, duration, curve); crossfade curve
  ∈ {`linear`, `equalPower`}; handle clamping at edit time and silence-pad clamping at render
  time; golden-audio: a correlated pair under `linear` holds exactly constant amplitude, an
  uncorrelated pair under `equalPower` holds constant RMS within tolerance, and no boundary notch.
- Follow-up implementation for #102, in order: **(1)** core model + validation — pair-agreement
  and handle-availability checks in `AjarCore`, the `equalPower` case with legacy decode tests,
  typed errors; **(2)** `OfflineAudioMixer` tail rendering + golden-audio fixtures per the curve
  contract; **(3)** edit-command clamp/remove semantics with undo tests; **(4)** realtime-plan and
  meter parity.

## Alternatives considered

- **(a) Timeline overlap (lanes or overlapping items).** The most general model and the industry
  endpoint for video transitions, but it repeals ADR-0008's central invariant. Every edit command
  gains lane-aware collision rules; `Track.opacity`/`blendMode` contracts and the compositor's
  one-active-clip assumption break; `.ajar` needs new geometry (lane index) with legacy defaults;
  validation, waveform layout, and undo all grow. That is a large regression surface against both
  merge gates for a feature whose audible result the fade tail reproduces exactly. Rejected for
  v1; a future ADR introducing lanes (likely for video transitions) would supersede this one.
- **Transition-as-item.** `TimelineItem.transition` already exists as a placeholder, and a
  reified item spanning the cut (FCP7-style) is superficially attractive. But an item occupying
  `[T, T + D)` either shifts the incoming clip — adding an *audio* crossfade would change program
  timing and desync linked A/V — or requires overlap semantics anyway, and it duplicates the
  already-shipped `ClipAudioCrossfade` codec. Remains a candidate for *video* transitions, which
  must reuse this ADR's handle semantics or supersede it.
- **Sequential ramps without overlap (PR #101).** Empirically produces the silence notch; worse
  than a hard cut. Rejected by evidence.

## References

- FR-AUD-002, FR-AUD-007 (SPEC §6.8); FR-TL-004, FR-TL-009, FR-TL-012 (SPEC §6.2).
- [ADR-0007](0007-project-file-format.md), [ADR-0008](0008-timeline-data-model.md),
  [ADR-0009](0009-render-graph-and-caching.md), [ADR-0012](0012-concurrency-and-threading.md).
- Issue #102; PR #101 (notch evidence and revert to validation-only).
