# Editor Ajar — Architecture

> **Status:** Draft v0.1 · **Last updated:** 2026-06-20
> Companion to [SPEC](SPEC.md). Decisions referenced here are recorded in [ADRs](adr/).

This document describes *how* Editor Ajar is built. It is the map the autonomous build agent
and human contributors use to place new code correctly. It is deliberately opinionated about
module boundaries because those boundaries are what protect stability and performance.

---

## 1. Guiding architecture principles

1. **A headless core, a thin shell.** All editing logic, the data model, the render-graph
   description, keyframe evaluation, and project (de)serialization live in `AjarCore`, which
   has **no UI and no GPU dependency** and is fully testable from the command line
   (ADR-0005). The app is a thin SwiftUI/AppKit shell over it.
2. **Describe, then execute.** `AjarCore` produces an immutable *description* of what a frame
   should be (a render graph). Platform modules *execute* that description on the GPU/audio
   hardware. The same description renders identically in the app, the CLI, and tests.
3. **The hot path is sacred.** Playback (decode → composite → present) and the audio render
   thread must never block on the UI, disk, or allocation. Everything else yields to them.
4. **Determinism where it counts.** Given the same project + media + settings, a render
   produces the same frames. This is what makes golden-frame testing (ADR-0011) possible.
5. **Fail safe, never crash.** Errors are values, not traps. The core surfaces typed errors;
   the shell decides how to present them. User work is auto-saved and recoverable (NFR-STAB).

---

## 2. Module map

```
┌──────────────────────────────────────────────────────────────────────┐
│  EditorAjar (app)         SwiftUI + AppKit. Windows, panels, gestures, │
│  app/EditorAjar/          inspector, drag/drop. NO editing logic here. │
└───────────────┬──────────────────────────────────────────────────────┘
                │ depends on
┌───────────────▼───────────┐  ┌──────────────┐  ┌──────────────┐
│  AjarRender (macOS)        │  │ AjarMedia    │  │ AjarAudio    │
│  Metal compositor;         │  │ (macOS)      │  │ (macOS)      │
│  executes the render graph;│  │ AVFoundation/│  │ AVAudioEngine│
│  effect/transition shaders;│  │ VideoToolbox │  │ Core Audio;  │
│  MetalFX; scopes.          │  │ decode/encode│  │ mixer; RT    │
│                            │  │ + FFmpeg     │  │ audio graph. │
│                            │  │ import bdry. │  │              │
└───────────────┬────────────┘  └──────┬───────┘  └──────┬───────┘
                │                       │                 │
                └───────────┬───────────┴─────────────────┘
                            │ all depend on (and only on)
                ┌───────────▼─────────────────────────────────────────┐
                │  AjarCore   (pure Swift, platform-agnostic, no GPU)  │
                │  Model · Time · Keyframing · Effects (descriptors) · │
                │  RenderGraph (description) · Color (math) · Project  │
                │  Fully unit-testable. The source of truth.          │
                └──────────────────────────────────────────────────────┘

        ajar-cli  →  links AjarCore + AjarRender + AjarMedia + AjarAudio
                     headless render / inspect / benchmark / golden-frame harness
```

**Dependency rule:** arrows point downward only. `AjarCore` depends on nothing in the project.
Platform modules depend on `AjarCore`. The app depends on all. Nothing depends on the app.
CI enforces that `AjarCore` imports no UI/GPU framework (ADR-0005, ADR-0011).

### Why this split

- **Testability for the autonomous loop.** The agent can build and verify the vast majority of
  behavior (editing, keyframes, serialization, render-graph construction) with fast headless
  unit tests, and verify pixels with the `ajar` CLI golden-frame harness — no GUI automation
  needed. This is what makes an unattended loop safe (ADR-0014).
- **Stability.** A pure-Swift core with no force-unwraps and value-typed errors is small enough
  to reason about and fuzz. GPU/driver concerns are isolated in `AjarRender`.
- **Performance.** The render graph lets us cache, dedupe, and schedule work optimally before
  touching the GPU.
- **Portability (optional, later).** Only `AjarRender/Media/Audio` are platform-bound. The core
  could back an iPad app or, in a distant future, a non-Apple backend.

---

## 3. Data model (`AjarCore/Model`)

A project is an immutable-by-default tree of value types; edits produce new versions, which is
what gives cheap, unbounded undo (FR-TL-012) and safe concurrency.

```
Project
 ├─ settings (resolution, frameRate, colorSpace, audioRate)
 ├─ mediaPool: [MediaRef]            // stable UUID + URL + contentHash + probed metadata
 ├─ sequences: [Sequence]
 └─ version / schema info

Sequence
 ├─ id, name, settings (may inherit Project)
 ├─ videoTracks: [Track]            // index 0 = bottom of composite
 ├─ audioTracks: [Track]
 └─ markers: [Marker]

Track
 ├─ id, kind (.video/.audio), enabled, locked, muted, solo, height
 └─ items: [TimelineItem]           // clips + gaps, sorted, non-overlapping

TimelineItem = .clip(Clip) | .gap(TimeRange) | .transition(Transition)

Clip
 ├─ id, mediaRef (or .compound(SequenceID)), enabled
 ├─ sourceRange (in/out in media time)
 ├─ timelineRange (start + duration in sequence time)
 ├─ speed: SpeedSpec                // constant or time-remap keyframes (SPD)
 ├─ transform: Transform            // position/scale/rotation/anchor/crop/opacity/blend (XFORM)
 ├─ effects: [EffectInstance]       // ordered stack (FX)
 ├─ masks: [Mask]                   // (COMP)
 ├─ colorGrade: ColorGrade?         // (COL)
 ├─ audio: AudioParams              // gain/pan/fades, keyframable (AUD)
 └─ link: LinkGroupID?              // A/V linkage (FR-TL-009)

Every animatable scalar is an `Animatable<T>` = base value + optional [Keyframe<T>].
```

Time is **rational** (`RationalTime` = value/timescale, à la CMTime) everywhere — never
floating-point frame counts — to avoid drift and make frame math exact (see `AjarCore/Time`).
Cycle detection forbids a compound clip from (transitively) containing itself (FR-CMP-005).

### Editing & commands

Edits are expressed as `EditCommand`s (insert, ripple-delete, trim, addKeyframe, setParam…)
applied by a pure reducer `apply(command, to: Project) -> Project`. The command log *is* the
undo stack. This keeps editing logic deterministic and unit-testable, and makes auto-save a
matter of persisting the latest project value (FR-TL-014, NFR-STAB-002).

---

## 4. Render graph (`AjarCore/RenderGraph`) and compositor (`AjarRender`)

To render sequence frame at time *t*:

1. **Build (Core, CPU, cheap):** walk the sequence, evaluate every `Animatable` at *t*
   (keyframe interpolation), resolve compound clips recursively, and emit an immutable
   **`RenderGraph`** — a DAG of nodes: `source(mediaRef, mediaTime)`, `transform`, `effect`,
   `chromaKey`, `mask`, `colorGrade`, `blend`, `composite`. Nodes carry resolved parameters
   and a **content hash** (their identity for caching).
2. **Execute (AjarRender, GPU):** a Metal-based executor turns nodes into texture operations.
   Decoders (AjarMedia) supply source frames as GPU textures (zero-copy from VideoToolbox via
   `CVMetalTextureCache` where possible). Effects are Metal compute/fragment shaders. The final
   composite is presented to a `CAMetalLayer` (or written to an encoder for export).

Properties that fall out of this design:

- **Caching (FR-PLAY-005):** a node's content hash keys a frame/intermediate cache (RAM +
  disk). Unchanged compound clips and segments render once and replay (FR-CMP-006). Editing a
  clip invalidates only the affected subgraph.
- **Color correctness (ADR-0010):** the graph declares color spaces on edges; compositing
  happens in a linear-light working space; conversions are explicit nodes.
- **Determinism (ADR-0011):** the same graph yields the same pixels → golden-frame tests.
- **Adaptive quality (FR-PLAY-004):** under load the executor can render at a reduced scale
  and report it, rather than dropping frames silently.

Core builds *descriptions*; only AjarRender touches Metal. The graph builder is therefore
fully testable on a headless machine (it produces data, not pixels).

---

## 5. Playback engine

Playback is a pipeline with three coordinated stages, decoupled by bounded queues so a stall
in one never stutters another:

```
   Scheduler ──► Decode (AjarMedia) ──► Composite (AjarRender) ──► Present (display link)
   (Core decides what frames are needed, prefetches ahead of the playhead)
```

- A **display-link**-driven clock pulls composited frames at the sequence frame rate.
- The **scheduler** prefetches decode work ahead of the playhead and warms the render cache.
- **Audio** runs on its own real-time path (AVAudioEngine) and is the master clock for A/V sync;
  video presents to match audio time.
- Under sustained overload, adaptive quality (FR-PLAY-004) reduces preview scale; the user sees
  a quality indicator, never a silent dropped frame (NFR-PERF-003 is "zero dropped frames").
- **Proxies (FR-MED-004):** the scheduler simply points sources at proxy media when proxy mode
  is on; the graph is otherwise identical.

Scrubbing reuses the same pipeline with prefetch biased around the pointer for ≤ 1-frame
seek latency (NFR-PERF-005).

---

## 6. Media pipeline (`AjarMedia`)

- **Fast path:** AVFoundation + VideoToolbox for H.264/HEVC/ProRes decode and encode, with
  hardware acceleration and zero-copy `CVPixelBuffer` → Metal texture handoff.
- **Import boundary (ADR-0003):** on import, files AVFoundation can't open natively are probed
  and transcoded by **FFmpeg** to ProRes (or decoded to frames) so the playback engine only
  ever sees a small, well-behaved format set. FFmpeg is *never* on the playback hot path.
- **Probing & conform:** detect codec, resolution, fps (incl. variable frame rate → conformed
  timebase, FR-MED-010), color space, and channel layout; store on the `MediaRef`.
- **Encode/export (EXP):** VideoToolbox hardware encoders for H.264/HEVC; AVAssetWriter for
  muxing; correct color tagging on output (ADR-0010). Export reads originals, not proxies
  (FR-EXP-007).
- **Licensing:** FFmpeg is integrated as a GPL-compatible component consistent with the
  project license (ADR-0004); the boundary keeps it cleanly separable.

---

## 7. Audio architecture (`AjarAudio`)

- Built on **AVAudioEngine / Core Audio**. A graph of per-track player nodes → effect nodes →
  per-track mixer → master bus → output, mirroring the timeline (AUD).
- The **render thread is real-time and allocation-free** (FR-AUD-007): no locks, no Swift
  allocations, no Obj-C messaging on the audio callback. Parameter changes are delivered via
  lock-free ring buffers / atomics from the UI thread.
- Volume/pan are sample-accurate and **keyframable** (FR-AUD-001) by baking the `Animatable`
  curve into a per-sample gain ramp.
- Metering, ducking (FR-AUD-004), and effects (EQ/compressor/limiter/denoise, FR-AUD-005) are
  nodes in this graph. Audio is the A/V sync master (see §5).

---

## 8. Concurrency & threading model (ADR-0012)

- **Main thread:** UI only. Never blocked by I/O or rendering.
- **Core editing:** the project model is a value type mutated through an actor (`ProjectStore`)
  that serializes edits and publishes immutable snapshots to the UI (Swift Concurrency).
- **Render queue:** a prioritized executor. *Interactive* requests (current playhead, scrub)
  outrank *background* requests (cache warming, render-in-place, proxy gen). Background work is
  pausable and yields instantly to interactive work (FR-PLAY-007).
- **Audio thread:** real-time, isolated, lock-free (see §7).
- **Decode workers:** a bounded pool feeding the playback pipeline.
- **Safety:** Swift `Sendable` checking + actors guard shared state; the whole thing must run
  clean under Thread Sanitizer in CI (NFR-STAB-004).

---

## 9. Memory & caching

- **Budgets:** explicit caps for the frame cache, proxy cache, and decode buffers, scaled to
  available RAM; eviction is LRU keyed by render-graph content hashes. Idle footprint is bounded
  (NFR-PERF-009).
- **Two-tier render cache:** hot frames in RAM, warm frames spilled to a disk cache under the
  `.ajar` package's `caches/` (excluded from project identity).
- **Zero-copy** GPU texture handling on the decode→composite path; CPU readback only for export
  and scopes, off the interactive path.
- **No leaks:** a 1-hour soak test must stay flat (NFR-STAB-005).

---

## 10. Color management (ADR-0010)

A managed pipeline end to end: sources are tagged (or assumed) with a color space; the graph
converts to a **linear-light working space** for compositing and effects (correct edges, blends,
and keying — FR-COMP-007); output is converted and tagged for the delivery space (FR-EXP-002).
Internal processing is ≥ 10-bit to avoid banding (FR-COL-008). HDR sources are tone-mapped to
the timeline space in v1, with an HDR timeline as a v1.x extension (FR-COL-006).

---

## 11. Plugin architecture (ADR-0013, target v1.x)

Third-party effects/generators/transitions are packages declaring a **parameter manifest**
(typed, keyframable params) plus **Metal shader(s)**. The host instantiates them as render-graph
effect nodes — they get source textures + resolved parameters and return a texture. Plugins run
in the same GPU pipeline (no CPU readback, FR-FX-007) but cannot touch the project model or the
file system, preserving stability. GPLv3 implications for plugins are noted in ADR-0004/0013.

---

## 12. Error handling & stability strategy

- **Errors are typed values** (`throws` / `Result`) in `AjarCore`; **no** `try!`, `as!`, or
  `fatalError` on any input path (NFR-STAB-003, enforced by lint).
- The shell renders errors as recoverable UI; the engine degrades gracefully (e.g. offline media
  shows a placeholder, FR-MED-007).
- **Auto-save + crash recovery** (NFR-STAB-002): the latest project value and command log are
  journaled; on relaunch after a crash, work is restored to within seconds.
- **Fuzzing** of importers and the project loader (NFR-STAB-006) guards the untrusted-input edges.

---

## 13. How the architecture serves the autonomous loop

The module boundaries are chosen so an unattended agent can make safe, verifiable progress:

- Most tasks touch `AjarCore` and are covered by **fast, deterministic unit tests**.
- Pixel-affecting tasks are verified by the **`ajar` CLI golden-frame harness** (no GUI needed).
- Performance-affecting tasks are gated by the **benchmark suite** (NFRs in §5 of the SPEC).
- The dependency rule and lint budgets are **machine-checkable**, so architectural drift fails CI
  rather than rotting silently.

See [TESTING](TESTING.md) for the harness and ADR-0014 for the loop design.
