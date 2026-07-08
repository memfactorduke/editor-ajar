# ADR-0015: Audio crossfade overlap model — fade tail past the cut, abut-only timeline preserved

- **Status:** Accepted
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

We choose **(b), the fade-tail model**, as an **audio-only v1 strategy** (see §10). The timeline
stays abut-only; a crossfade is derived render-time behavior keyed off the existing
`ClipAudioCrossfade` metadata. Specifically:

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
3. **Effective audio read window + cache contract.** A clip's **effective read window** is its
   `sourceRange` extended by the source-time image of the tail under the clip's mapping —
   `D × speed` past `sourceRange.end` for forward constant-rate, before `sourceRange.start` for
   `reverse`, empty for `freezeFrame`. This window — not `sourceRange` — is the unit of audio
   source acquisition. Two places must adopt it: `OfflineAudioMixer.intersectionFrames` today
   intersects only the clip's own `timelineRange` and must extend the outgoing clip's mix window
   by *D*; and **every audio cache or prepared render-plan key must hash the effective read
   window** — the compound source cache key today is `CompoundAudioSourceKey`
   (`sequenceID + sourceRange + format`, `OfflineAudioCompoundSources.swift`) and would return a
   stale, tail-less buffer after a crossfade is added or lengthened. This is a binding contract
   for `OfflineAudioRenderEnvironment` caches and `RealtimeAudioRenderPlan` alike.
4. **Gain curve contract.** With `x ∈ [0, 1]` across the region, the mixer sums
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
   **Automatic curve selection:** the crossfade-creating command selects `linear` when the two
   edges are **same-source contiguous mappings** — same `ClipSource` media/sequence ID, the
   outgoing `sourceRange.end` equal to the incoming `sourceRange.start`, and identical
   `speed`/`reverse` mapping (the blade-split signature, detectable purely from the model) — and
   `equalPower` otherwise. The user may override either way; the stored curve is the truth.
5. **Pair agreement taxonomy.** Exactly **one transition per cut**: a cut is crossfaded iff the
   outgoing clip has `trailingCrossfade` naming the incoming clip *and* the incoming clip has the
   mirroring `leadingCrossfade` naming the outgoing clip, with identical duration and curve.
   **Rendering is owned by the outgoing clip's trailing edge**; the incoming clip's leading record
   is a mirror for lookup/UI and contributes no second render pass. Validation rejects, with named
   typed errors: a one-sided pair (`crossfadeMirrorMissing`), duration or curve disagreement
   (`crossfadePairMismatched`), a record on the wrong edge for its position — e.g. a
   `trailingCrossfade` naming the *previous* clip (`crossfadeDirectionInvalid`) — partners
   separated by a gap item (`crossfadeSeparatedByGap`), plus the existing
   `crossfadePartnerMatchesClip` (same-clip partner), `crossfadePartnerNotAdjacent`, and
   `crossfadePartnerMissing` (stale partner ID) in `AudioRenderError`.
6. **Fade × crossfade composition: rejected, not composed.** A nonzero `fadeOut` on an edge that
   carries a `trailingCrossfade` (or `fadeIn` with `leadingCrossfade`) is a typed validation error
   (`crossfadeConflictsWithFade`). Composing would multiply the outgoing tail by a
   fade-to-silence envelope that reaches zero at the cut — reintroducing the #101 notch through
   the back door — and silently overriding would discard stored user intent, against the
   typed-error posture (NFR-STAB-003). The crossfade-creating command clears the same-edge fade in
   the same undoable command, so a valid project never persists both; hand-edited JSON that does
   is rejected at validation, never guessed at.
7. **Source-handle rule.** The outgoing media must have **tail content**: the effective read
   window (§3) must lie within the available media. Edit commands that create or lengthen a
   crossfade clamp *D* to the available handle (clamping to zero is a typed rejection, not a
   silent no-op). At render time, two shortfalls are distinguished:
   - **Confirmed media EOF** — the mapped tail extends past the media's *declared* duration
     (media drifted after validation, e.g. relinked to a shorter file): the tail is
     **silence-padded** past the declared end, deterministically; the render never fails because
     a file on disk got shorter.
   - **Provider under-delivery** — the decoder/source returns fewer frames than requested *within*
     the declared bounds (truncated or corrupt media, decoder fault): this must **surface a
     deterministic typed diagnostic** (`AudioRenderError.sourceUnderDelivered`, carrying clip ID
     and the missing range), never silent zeros — a corrupt file must not masquerade as an
     intentional fade to nothing.
8. **Edit-command interaction matrix.** `EditReducer.copying` today carries `audioMix` blindly
   (`ClipCopyingEditCommands.swift`), which would duplicate or orphan crossfade records. Each
   command adopts the following contract, applied **within the same command** so undo restores
   geometry and metadata atomically (ADR-0008 / FR-TL-012):

   | Command | Crossfade behavior |
   |---------|--------------------|
   | Blade | Redistribute: `leadingCrossfade` stays on the left half, `trailingCrossfade` moves to the right half; **mirror-update** partner IDs on adjacent partners to the owning half's ID; the new cut itself gets no automatic crossfade. |
   | Ripple trim | **Preserve** the pair; **clamp** *D* to the post-trim handle and clip durations, mirror-updating both records; clamp-to-zero **removes** the pair. |
   | Roll | **Preserve** the pair (the cut moves with both edges); **clamp** as above against the new handle and durations. |
   | Slip | **Preserve** adjacency (timeline untouched); **clamp** against the slipped tail handle. |
   | Slide | **Preserve** the pairs at both moving cuts; **clamp** each; mirror-update neighbors. |
   | Lift | **Remove** both of the lifted clip's pairs and clear the mirrors on its neighbors — the gap breaks adjacency. |
   | Ripple delete | **Remove** the deleted clip's pairs and mirrors; the newly abutting neighbors get **no** automatic crossfade. |
   | Trim (in place) | **Preserve** while the partners still abut; **clamp** as above; an edge pulled off its partner **removes** the pair and clears the mirror — the gap breaks adjacency. |
   | Move | **Remove** any pair whose cut the move breaks (mirrors cleared on both affected tracks); a move that keeps the partners abutting **preserves** the pair. No automatic crossfade at the destination. |
   | Set speed | **Preserve** the pair (the track ripples like a ripple trim); **clamp** against the retimed clip duration and the speed-scaled tail handle; clamp-to-zero **removes** the pair. |

9. **Render paths and hashing.** `OfflineAudioMixer` applies §3's extended window and §4's curve
   contract; the realtime plan prepares tail frames ahead of time like any other source material —
   no allocation or locking on the audio thread (ADR-0012, FR-AUD-007). Crossfade fields are
   already part of the encoded clip payload, so any content hash derived from clip content
   (ADR-0009) already varies with them; audio-side cache keys additionally hash the effective read
   window per §3. The video render graph is untouched.
10. **Scope: audio only.** This ADR decides the v1 strategy for FR-AUD-002 **audio** crossfades.
    It does not constrain video transitions (SPEC §6.10, `TimelineItem.transition`); a future
    video-transition ADR must either adopt the same handle / effective-read-window vocabulary or
    supersede this ADR — it must not silently introduce a second, incompatible overlap model.

### Clarifications (from slice-1 implementation)

Four ambiguities surfaced while implementing the §5/§6/§7 validation slice (PR #163) and were
resolved on issue #102; they are recorded here as naming, not as changes to any decision above:

1. **No leading-side read window.** Under the fade-tail model only the outgoing clip's trailing
   edge extends its read window (§3); a leading record never needs media beyond its own
   `sourceRange`, so no leading-side handle check exists — mirror validity is transitive via §5
   pair agreement.
2. **Taxonomy home.** The §5 taxonomy lives in `AjarCore` as `AudioCrossfadeValidationError`
   (produced by `ClipAudioCrossfadeValidator`), with a total mapping onto `AudioRenderError` so
   the model and render paths share one vocabulary.
3. **Error names.** The §2 time-remap rejection is named `crossfadeUnsupportedWithTimeRemap`;
   the §3/§7 validation-time handle rejection is named `crossfadeExceedsSourceHandle`.
4. **Explicit-gap-item semantics.** `crossfadeSeparatedByGap` fires only when an explicit gap
   item sits between the partners; non-touching partners without a gap item stay
   `crossfadePartnerNotAdjacent`.

Two more were resolved while implementing the §8 matrix (slice 3, PR #165), again recorded as
naming rather than changed decisions:

5. **§8 rows for trim/move/speed.** The in-place trim, move, and constant-speed commands also
   mutate cut geometry, so they carry the same §8 contract; their rows were added to the table
   above with the matching preserve/clamp/remove rationale.
6. **Blade limits.** Blading *inside* an active transition region `[T, T + D)` is not defined by
   this ADR and is rejected with the typed `bladeInsideCrossfadeRegion` error; blading reversed
   or time-remapped clips is rejected with `bladeUnsupportedForRetimedClip` until
   direction-aware source-split math exists (FR-SPD-003 follow-up), and a bladed freeze frame
   keeps the same held frame on both halves.

## Consequences

- The abut-only invariant survives intact: no changes to `ProjectValidation`, the trim commands'
  geometry, track compositing assumptions, or the video renderer. The blast radius is confined to
  audio validation, audio-mix metadata maintenance in the edit commands, and the two audio render
  paths — the smallest surface that can satisfy FR-AUD-002, which is what the stability and
  performance merge gates demand.
- **Zero `.ajar` geometry change.** The crossfade fields already round-trip with legacy `nil`
  defaults; the only codec delta is the additive `equalPower` raw value (needs an explicit
  nested-legacy decode test).
- Undo/redo stays trivially correct; performance cost is O(*D*) extra samples per transition on an
  already-accumulating mix loop.
- **Costs we accept:** a cut at the very end of the outgoing media cannot crossfade (standard NLE
  behavior — no handle, no transition); the region is post-cut (asymmetric), so a "centered"
  crossfade requires moving the cut — a symmetric head lead-in for the incoming clip is
  deliberately out of scope for v1; timeline UI must later visualize audio that is audible past a
  clip's drawn right edge (an overlay across the cut, not a lane); edit commands can no longer
  copy `audioMix` blindly and take on the §8 maintenance burden.
- New invariants for tests/CI: the §5 pair taxonomy with its named typed errors; crossfade curve
  ∈ {`linear`, `equalPower`}; fade/crossfade same-edge mutual exclusion (§6); handle clamping at
  edit time, EOF silence-padding vs `sourceUnderDelivered` diagnostics at render time (§7); audio
  cache keys vary with the effective read window (§3); every §8 matrix row; golden-audio: a
  correlated pair under `linear` holds exactly constant amplitude, an uncorrelated pair under
  `equalPower` holds constant RMS within tolerance, and no boundary notch.
- Follow-up implementation for #102, in order: **(1)** core model + validation — the §5 taxonomy
  and §6 exclusion in `AjarCore`, handle-availability checks over the effective read window, the
  `equalPower` case with legacy decode tests, typed errors; **(2)** `OfflineAudioMixer` tail
  rendering, §3 cache-key extension, and golden-audio fixtures per the curve contract;
  **(3)** the §8 edit-command matrix with undo tests; **(4)** realtime-plan and meter parity with
  the §7 under-delivery diagnostic.

## Alternatives considered

- **(a) Timeline overlap (lanes or overlapping items).** The most general model and the industry
  endpoint for video transitions, but it repeals ADR-0008's central invariant. Every edit command
  gains lane-aware collision rules; `Track.opacity`/`blendMode` contracts and the compositor's
  one-active-clip assumption break; `.ajar` needs new geometry (lane index) with legacy defaults;
  validation, waveform layout, and undo all grow. That is a large regression surface against both
  merge gates for a feature whose audible result the fade tail reproduces exactly. Rejected for
  audio v1; a future ADR introducing lanes (likely for video transitions) would supersede.
- **Transition-as-item.** `TimelineItem.transition` already exists as a placeholder, and a
  reified item spanning the cut (FCP7-style) is superficially attractive. But an item occupying
  `[T, T + D)` either shifts the incoming clip — adding an *audio* crossfade would change program
  timing and desync linked A/V — or requires overlap semantics anyway, and it duplicates the
  already-shipped `ClipAudioCrossfade` codec. Remains a candidate for *video* transitions under
  §10's compatibility requirement.
- **Sequential ramps without overlap (PR #101).** Empirically produces the silence notch; worse
  than a hard cut. Rejected by evidence.

## References

- FR-AUD-002, FR-AUD-007 (SPEC §6.8); FR-TL-004, FR-TL-009, FR-TL-012 (SPEC §6.2);
  SPEC §6.10 (FX).
- [ADR-0007](0007-project-file-format.md), [ADR-0008](0008-timeline-data-model.md),
  [ADR-0009](0009-render-graph-and-caching.md), [ADR-0012](0012-concurrency-and-threading.md).
- Issue #102; PR #101 (notch evidence and revert to validation-only).
