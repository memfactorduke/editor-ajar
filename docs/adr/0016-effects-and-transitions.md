# ADR-0016: Effects and transitions architecture

- **Status:** Accepted
- **Date:** 2026-07-09
- **Deciders:** Mem
- **Tags:** effects, transitions, model, rendering, keyframing, performance

## Context

M8 opens the creative FX surface: per-clip effects stacks (FR-FX-003), a core effects library
(FR-FX-002), and transitions on cuts (FR-FX-001), all GPU-resident with no CPU readback
(FR-FX-007). Today `ClipEffects` holds fixed compositing slots (chroma/luma/color/masks) with
typed Codable parameters and dual static + `Animatable` forms — a proven pattern, but not an
ordered, reorderable library stack. ADR-0015 fixed audio crossfades under the abut-only timeline
(ADR-0008) via fade-tail handles and pair agreement; video transitions must not invent a second,
incompatible overlap model. PERFORMANCE §3 requires every effect/transition node to carry a
budgeted GPU benchmark that fails CI when blown. ADR-0013 already targets plugins as effect nodes
with a parameter manifest + Metal shaders — built-ins must share that contract.

## Decision

### 1. Video effect node model (typed, Codable-stable)

A clip carries an ordered **effect stack** separate from the fixed `ClipEffects` compositing
slots:

- **`ClipEffectStack`** — ordered `[ClipEffectNode]`, empty by default.
- **`ClipEffectNode`** — stable `id` (UUID), `enabled` flag, and a **`ClipEffectDefinition`**
  enum whose cases are the effect kinds with **typed associated parameter structs** (same shape
  as `ClipChromaKeySettings`: explicit fields, unit ranges, legacy-safe decode).
- **Kind identity** is the definition enum case (and its `ClipEffectKind` raw string for
  registry / benchmarks / project files). Parameters are never free-form dictionaries.
- **Schema stability (ADR-0007):** the stack fields on `Clip` are optional-or-defaulted on
  decode (`[]` / empty stack). New parameter fields inside a kind's struct use
  `decodeIfPresent` + defaults. Unknown future kinds are a decode error until a migration
  exists — we do not silently drop nodes.
- **v1 bootstrap:** one concrete kind (`placeholder`) lands with FR-FX-003 so the schema and
  commands are exercised; library kinds (blur, sharpen, …) add cases under FR-FX-002 without
  reshaping the stack.

Static evaluated settings and keyframable settings follow the existing dual pattern:

- `Clip.effectStack` / `Clip.effectStackAnimation` mirror `effects` / `effectsAnimation`.
- Setting a parameter via edit commands updates the static snapshot and replaces that node's
  changed parameters with constant `Animatable`s (same replacement discipline as chroma key).

### 2. Per-parameter keyframing rides M4 `Animatable`

Every keyframable scalar/vector on an effect node is an `Animatable<T>` using the M4 keyframe
types already used by clip transform and audio mix (`Keyframe<T>`, `InterpolationMode`,
`RationalValue` / structured values, Bezier timing). Evaluation is at **sequence time** via
`value(at:)`, identical to transform and `AnimatableClipEffects`. Blade splits every
`Animatable` through `Animatable.bladed(at:)` (FR-XFORM-008) so the stack animation is unchanged
across a cut. Non-animatable fields (`enabled`, kind identity, discrete enums) are constant on
the node; toggling enable does not invent keyframes.

### 3. Shader registry in AjarRender

`AjarCore` emits resolved stack nodes on the render graph (later slices; FR-FX-002/007).
**`AjarRender` owns a kind → Metal pipeline registry**: a table mapping `ClipEffectKind` (and,
later, plugin IDs under ADR-0013) to a loaded pipeline state + bind layout. Built-in kinds and
plugins share one registration path. A missing or failed pipeline is a **typed render error**,
never a trap. The core never imports Metal; it only carries kind + resolved parameters.

### 4. Per-node GPU cost budget (PERFORMANCE §3)

Every effect and transition kind ships a **named benchmark metric** in `ajar bench` whose
`budgetMilliseconds` / noise band are declared next to the kind. Adding or changing a shader
that exceeds its budget at the reference machine **fails CI**. The metric ID is stable and
includes the kind raw value so regressions are attributable. Empty/`placeholder` kinds may use
a near-zero budget until a real shader lands; real library kinds must publish budgets before
merge.

### 5. Transitions attach at the cut; handle validation mirrors ADR-0015

Video transitions attach to a **cut between abutting clips** (outgoing trailing edge + incoming
leading mirror), not as geometry-shifting timeline items and not by relaxing ADR-0008's
non-overlap invariant for v1.

- **Overlap model:** reuse ADR-0015's **fade-tail** vocabulary: over transition duration *D* the
  outgoing clip's source continues past its timeline out-point (effective read window), mixed
  with the incoming clip under the transition shader. Sequence duration is unchanged when a
  transition is added, adjusted, or removed.
- **Pair agreement:** one transition per cut; both edges name each other with identical kind,
  duration, and parameters; rendering is owned by the outgoing trailing record.
- **Handle media:** creating/lengthening a transition **clamps *D* to available source handle**;
  clamp-to-zero is a typed rejection. At render time, confirmed media EOF is deterministic
  padding/black as appropriate for the kind; provider under-delivery is a typed diagnostic —
  never a silent wrong frame.
- **Edit matrix:** the same preserve / clamp / remove rules as ADR-0015 §8 (blade redistributes,
  lift/ripple-delete clears, trim/roll/slip/slide/move/speed clamp or drop). Blade inside an
  active transition region is rejected with a typed error.
- **`TimelineItem.transition`:** remains a UI/layout placeholder until a later slice migrates or
  retires it; the authoritative model is cut-edge metadata on the two clips (parallel to
  `ClipAudioCrossfade`).

### 6. Linked A/V: video transition ⟂ audio crossfade

A video transition and an audio crossfade on the same cut are **independent records**. Neither
auto-creates the other; linked A/V edit commands that move a cut maintain each record under its
own handle and pair rules. A compound "apply both" UI action, if added later, is two commands in
one undo group — not a coupled model field. Desync is allowed when the user intentionally
detaches audio (FR-AUD-008).

## Consequences

- FR-FX-003 can ship the pure stack model + undoable edits without waiting on shaders; render
  and library kinds plug in without codec churn beyond additive enum cases.
- Fixed compositing slots (`ClipEffects`) stay; the stack is the ordered FR-FX library path.
  Both participate in content hashing once the graph wires the stack (ADR-0009).
- Transition work reuses ADR-0015's hardest invariants (abut-only timeline, handles, pair
  taxonomy), keeping the regression surface small.
- **Costs:** dual static/animatable stack fields to maintain on blade/copy/compound paths (same
  discipline as transform/effects — raw `Clip(...)` constructions must propagate the new
  fields); every new kind needs validation ranges, a registry entry, and a budgeted benchmark
  before it is mergeable; transition metadata on both edges is more bookkeeping than a single
  reified transition item, but avoids a second overlap model.

## Alternatives considered

- **Free-form parameter dictionaries / property bags.** Flexible for plugins, but weak typing,
  hard golden/determinism stories, and easy Codable drift. Rejected; plugins still declare a
  typed manifest (ADR-0013) that maps into the same node shape.
- **Fold library effects into `ClipEffects` fixed slots.** Cannot express reorderable stacks or
  multiple instances of one kind. Rejected.
- **Timeline overlap / lanes for video transitions.** Most general, but repeals ADR-0008 and
  explodes edit/compositor surface. Rejected for v1; a future ADR may supersede if multi-source
  transitions require it.
- **Transition-as-item spanning the cut.** Attractive for UI, but either shifts program timing
  (desyncs linked A/V) or needs overlap. Cut-edge metadata matches the shipped audio model.
- **Auto-pairing video transition with audio crossfade.** Surprising for intentional audio-only
  or video-only transitions; rejected in favor of independent records.

## References

- FR-FX-001, FR-FX-002, FR-FX-003, FR-FX-007 (SPEC §6.10); FR-KEY-001… (SPEC §6.4);
  PERFORMANCE §3; NFR-STAB-003.
- [ADR-0007](0007-project-file-format.md), [ADR-0008](0008-timeline-data-model.md),
  [ADR-0009](0009-render-graph-and-caching.md), [ADR-0013](0013-plugin-architecture.md),
  [ADR-0015](0015-audio-crossfade-overlap-model.md).
- Issue #180.
