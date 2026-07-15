# ADR-0020: v1 scope deferrals

- **Status:** Accepted (2026-07-11 — conditional clause satisfied; measurements on #247)
- **Date:** 2026-07-11
- **Deciders:** Editor Ajar maintainers
- **Tags:** release, scope, v1, app-shell

## Context

The v1 functional-requirement audit in #239 found that Editor Ajar's engine is broadly
v1-complete, but its ordinary macOS app surface is not yet equally complete. M10 and M11 therefore
prioritize a coherent, safe editing path that a person can discover and use over exposing every
engine capability in the first public release.

Issues #240–#246 close the highest-value app-surface gaps. In particular, constant speed,
reverse, and freeze ship through #245; rectangle/ellipse masks and chroma/luma keyers ship through
the #243-adjacent app work. The advanced interfaces below are valuable, but are not required for
a trustworthy v1 editing path. Deferral preserves the requirements and moves their release marker
to v1.x rather than silently deleting them.

FR-PROJ-002's rolling keep-N version snapshots are **not** deferred. They shipped in #233 with a
newest-ten retention policy and are covered by
`app/EditorAjar/Tests/EditorAjarDocumentLifecycleTests.swift`.

FR-MED-008 is no longer deferred. Issue #267 delivers its consumer workflow without changing the
project storage model: saved projects copy into their own `.ajar/media` directory, while untitled
projects use the existing Save As flow before confirmation. The confirmation states the exact
destination/count and that originals are never deleted. Hash/copy work runs off-main with
determinate progress and cancellation checks across copy/reuse/collision hashing. Temporary
publication is atomic; failed cleanup is visible. An exclusive cross-process package-media lock is
held before stale cleanup and throughout consolidation. Only exact Editor Ajar transaction names
are retried, using identity-checked, directory-relative, non-recursive unlinking that never follows
symlinks. Interrupted removal uses a separate non-swept quarantine namespace with durable file
identity evidence; a missing match or restore collision stops consolidation and preserves the
uncertain entries. A nonmodal overlay leaves the editor usable, while session and package identity
guards prevent stale reference application. Successful files are rewritten in one undoable
change, including partial runs. `AjarCore` remains platform-pure.
Save As stages and hash-verifies only durable media already owned by the source package, rebases
current and retained-version references to the published destination, and creates final bookmarks
after publication. External originals are not copied, and a failed copy or finalization does not
replace the selected destination.

## Decision

We will ship v1 without the following app surfaces and complete them in v1.x. “Engine status” is
the repository state on 2026-07-11; a complete engine does not imply that a user can reach the
feature from the app.

| FR | SPEC wording | Engine status today and evidence | User impact in v1 | v1.x commitment |
|----|--------------|----------------------------------|-------------------|-----------------|
| FR-SPD-002 | **Speed ramping** (keyframed variable speed) via time-remap keyframes. | Complete: model/edit/render/audio paths are covered by `ClipTimeRemapEditTests`, `ClipTimeRemapRenderGraphTests`, and `OfflineAudioTimeRemapTests`. | No speed-ramp editor; constant speed, reverse, and freeze still ship via #245. | Add the discoverable ramp-editing UI and integrate it with timeline keyframes. |
| FR-KEY-004 | A **curve editor** (graph view) for direct manipulation of value curves and Bézier handles, with multiple parameters overlaid. | Interpolation engine complete, including custom Bézier evaluation (`Tests/AjarCoreTests/AnimatableTests.swift`); graph editor absent. | Values and keyframes can be edited through the v1 controls, but not in an overlaid graph. | Ship the multi-parameter curve editor with editable handles. |
| FR-KEY-007 | Copy/paste keyframes and whole animations between clips and parameters. | Animation storage and rebasing exist (`AnimationRebaseEditTests`); the engine copy/paste command and app action are absent. | Users must recreate an animation instead of copying it. | Add a deterministic undoable engine command, clipboard representation, and app actions. |
| FR-KEY-008 | Time-remap keyframes integrate with the speed system (`SPD`). | Time-remap model/render/audio integration is complete (`ClipTimeRemapModelTests`, `ClipTimeRemapRenderGraphTests`, `OfflineAudioTimeRemapTests`); the integrated UI is absent. | No timeline keyframe workflow for speed ramps in v1. | Expose time-remap keyframes through the speed and keyframe interfaces delivered with FR-SPD-002. |
| FR-COMP-003 | **Masks:** rectangle, ellipse, and free-form Bézier/polygon masks per effect or clip; feather; invert; multiple masks with add/subtract/intersect. | Engine/render support is complete for rectangle, ellipse, polygon, feather/invert, and combining (`EditClipEffectsCommandTests`, `RenderGraphChromaKeyTests`, `MetalRenderExecutorMaskTests`). | Rectangle/ellipse mask controls ship; users cannot draw a free-form Bézier mask on canvas. | Add on-canvas free-form drawing and point/handle editing without narrowing the existing engine model. |
| FR-CMP-001 | **Compound clip:** select clips across tracks and collapse them into a single nested clip that behaves like one clip on the timeline. | Engine complete (`MakeCompoundClipCommandTests`, `MakeCompoundAudioPlaybackTests`); app command absent. | Users cannot create compounds from the v1 timeline. | Add selection validation and a discoverable Make Compound Clip action. |
| FR-CMP-002 | Open a compound clip to edit its contents in its own timeline; changes propagate to all instances. | Sequence-backed resolution/propagation is complete (`CompoundClipModelTests`, `CompoundRenderGraphTests`); navigation UI absent. | Compounds cannot be opened or edited from the app. | Add nested-timeline navigation and instance-aware editing UI. |
| FR-CMP-003 | Effects, transforms, speed, and keyframes can be applied to a compound clip as a whole. | The sequence-backed clip model and render graph support whole-compound processing (`CompoundRenderGraphTests`, `DecomposeCompoundClipFidelityTests`); UI absent. | Users cannot select and adjust a compound as a unit. | Expose compound-level inspector and timeline operations. |
| FR-CMP-004 | “Decompose” / break apart back into component clips in place. | Undoable engine command complete (`DecomposeCompoundClipCommandTests`, `DecomposeCompoundClipFidelityTests`); app action absent. | Users cannot break apart a compound in the app. | Add the validated, undoable Decompose action. |
| FR-CMP-005 | Nested compound clips with cycle detection (a compound can never contain itself — enforced in `AjarCore`). | Engine complete, including cycle validation (`CompoundClipModelTests`, `ProjectCompoundValidation.swift`). | Nested compounds are unavailable because compound creation/editing UI is deferred. | Enable nesting through the compound UI while preserving the existing cycle error. |
| FR-AUD-004 | **Ducking:** automatically lower music under dialogue/voice (sidechain-style, keyframe-baked or live). | Core/audio engine complete (`AudioDuckingModelTests`, `OfflineAudioDuckingTests`, golden-audio ducking fixtures); app setup UI absent. | Users cannot configure automatic dialogue-over-music ducking. | Add source/target selection and threshold, reduction, attack, hold, and release controls. |
| FR-COL-006 | **HDR awareness:** open and tone-map HDR (HLG/PQ, Rec.2020) sources to an SDR timeline; HDR timeline + export. | Not complete: ADR-0010 defines the intended pipeline, but HDR ingest/tone-map still requires engine and validation work. HDR timeline/export was already v1.x. | v1 supports the documented SDR/Display-P3 path, not an HDR-source workflow. | Implement tagged HDR ingest, deterministic tone mapping to SDR, visual/golden validation, then HDR timeline/export. |

### Conditional playback deferral

FR-PLAY-004 and FR-PLAY-007 move to v1.x **only if** the performance gates still hold after #245
wires the FR-PLAY-005 RAM+disk playback cache into the app playback path:

| FR | SPEC wording | Status today | Conditional v1 impact | v1.x commitment |
|----|--------------|--------------|-----------------------|-----------------|
| FR-PLAY-004 | Adaptive playback quality: reduce preview resolution under load, restore full quality when paused, and visibly report quality/drops. | Render architecture anticipates scaled preview (`docs/ARCHITECTURE.md`); no accepted app-level adaptive-quality path. | If measured cached playback meets every applicable gate, v1 may ship at fixed preview quality. | Add automatic quality selection and the required visible indicator. |
| FR-PLAY-007 | Background rendering is fully pausable and never competes with interactive responsiveness (priority-aware — ADR-0012). | Disk-cache population is restricted to offline/background routes (`MetalDiskFrameCacheTests`); a complete priority-aware app scheduler is absent. | If measured cached playback meets every applicable gate, v1 may omit background rendering rather than risk competing with interaction. | Add pausable, priority-aware background rendering before exposing that workflow. |

Before this ADR can be Accepted, the #247 issue or its PR must record the post-#245 measured
numbers, machine/configuration, media fixture, and pass/fail result for every applicable SPEC and
`docs/PERFORMANCE.md` playback/scrubbing gate. If any gate fails, FR-PLAY-004 and/or FR-PLAY-007
remain v1 requirements and the corresponding implementation cannot be descoped under this ADR.
An unmeasured assertion that playback “feels fast” does not satisfy this condition.

## Consequences

- v1 has a smaller, explainable app surface while retaining the completed engine work and tests.
- The SPEC remains the source of truth: deferred requirements stay present and are traceable to
  this ADR through their v1.x markers.
- Project files and engine models should remain forward-compatible with the later v1.x UI work;
  v1 must not add placeholder controls that imply an unavailable operation works.
- Users lose advanced animation, free-form mask drawing, compound workflows, ducking setup, and
  HDR input in v1. Release notes must say so plainly. Consolidation is no longer in this list.
- FR-PLAY-004/007 are not unconditional schedule cuts. Acceptance now carries a measurable
  performance-evidence obligation after cache wiring.
- FR-PROJ-002 remains shipped and must not appear in v1.x scope lists.

## Alternatives considered

### Hold v1 until every audited v1 app surface ships

Rejected because it delays a coherent editor for advanced interfaces whose underlying engine
work is preserved, while increasing the amount of new UI that must stabilize at once.

### Delete or weaken the deferred requirements

Rejected because the product commitments remain valuable. Moving their markers to v1.x makes
the scheduling decision visible without erasing intent or acceptance criteria.

### Defer adaptive quality and background rendering without measurement

Rejected because playback performance is a merge gate. The FR-PLAY-005 cache may make both
features unnecessary for v1, but only post-wiring measurements can establish that safely.

## References

- [SPEC §6](../SPEC.md#6-functional-specification)
- [ROADMAP M10/M11](../ROADMAP.md)
- [ADR-0009: Render graph and caching](0009-render-graph-and-caching.md)
- [ADR-0010: Color management](0010-color-management.md)
- [ADR-0012: Concurrency and threading](0012-concurrency-and-threading.md)
- Issues #233, #239–#247, #267
