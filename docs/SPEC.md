# Editor Ajar — Master Specification

> **Status:** Draft v0.1 (founding) · **Last updated:** 2026-06-29
> **Owner:** Mem · **Audience:** maintainers, contributors, and the autonomous build agent
> **Companion docs:** [ARCHITECTURE](ARCHITECTURE.md) · [ROADMAP](ROADMAP.md) ·
> [PERFORMANCE](PERFORMANCE.md) · [TESTING](TESTING.md) · [GLOSSARY](GLOSSARY.md) · [ADRs](adr/)

This is the single source of truth for *what* Editor Ajar is and *what it must do*.
The [ARCHITECTURE](ARCHITECTURE.md) doc covers *how*. Decisions that shaped both live in
the [ADRs](adr/). Every requirement here has a stable ID (e.g. `FR-TL-004`) so code,
tests, ADRs, and the build loop can reference it unambiguously.

---

## 1. Vision

Editor Ajar is a **fast, native, open-source video editor for macOS**. The name says the
intent: the door is left *ajar* — open source, open formats, and approachable.

It exists because the popular consumer editors (Filmora and its peers) are cross-platform
ports that feel sluggish and unstable on the Mac: slow launches, laggy scrubbing, beachballs,
and crashes that lose work. Editor Ajar's wager is that a Mac-native editor built directly on
Apple's hardware media pipeline can be **dramatically faster and more stable** while still
being **fully featured, professional, and good-looking**.

We are not building a toy. v1 is a feature-complete editor a working creator can use as their
daily driver. We are also not building Final Cut or Resolve — we deliberately scope to the
"prosumer" band: the power of keyframes, compositing, color, and multitrack audio, wrapped in
an interface that a motivated beginner can learn in an afternoon.

## 2. Product principles

These are tie-breakers. When two designs conflict, the higher principle wins.

1. **Stability above all.** The editor must not crash and must never lose user work. A
   dropped frame is a bug; a corrupted project is a catastrophe. The headless core is held to
   a "no force-unwrap, no unhandled error, no data race" standard (see [TESTING](TESTING.md)).
2. **Performance you can feel.** Real-time playback and instant scrubbing at the target specs
   (§5) are acceptance criteria, not aspirations. Every feature is measured against the
   [performance budget](PERFORMANCE.md). A feature that regresses playback is not done.
3. **Native, not ported.** We use AVFoundation, VideoToolbox, Core Audio, and Metal directly
   (ADR-0002, ADR-0003, ADR-0006). The app should feel like it belongs on macOS.
4. **Simple by default, deep on demand.** The default workspace is uncluttered. Advanced
   controls (curves, scopes, masks) are one click away, never in your face.
5. **It looks good.** A modern, calm, high-contrast dark UI (with a light variant), smooth
   60 fps interaction, tasteful motion. Polish is a feature.
6. **Open and inspectable.** GPLv3 (ADR-0004). The `.ajar` project format is documented and
   text-diffable. Nothing about the user's media or project is locked in.

## 3. Target users & non-goals

**Primary users**

- YouTubers / short-form creators who need fast turnaround and green-screen.
- Course / tutorial makers (screen recordings, callouts, titles, picture-in-picture).
- Prosumers and editors frustrated with sluggish consumer tools on the Mac.

**Explicit non-goals for v1** (may be revisited; see §13)

- Windows / Linux support (ADR-0002 — Mac-native is the whole point).
- Multi-user / cloud collaboration; real-time co-editing.
- A built-in stock-media store or paid asset marketplace.
- Broadcast/finishing features: full node-based color like Resolve, Fairlight-class audio,
  conform/EDL/XML round-tripping with other NLEs (import is a *future* nicety).
- Mobile (iPad) — though the `AjarCore` split (ADR-0005) keeps that door open.

## 4. Definitions & conventions

See [GLOSSARY](GLOSSARY.md) for the full vocabulary (clip, track, sequence, compound clip,
keyframe, etc.). Throughout this doc:

- **MUST / SHALL** = required for the release the requirement is tagged to.
- **SHOULD** = strongly preferred; omission needs a recorded reason.
- **MAY** = optional / nice-to-have.
- Requirement IDs: `FR-<area>-<n>` (functional), `NFR-<area>-<n>` (non-functional).

Release tags: **`[v1]`** required for 1.0, **`[v1.x]`** fast-follow, **`[future]`** later.
Areas map to the modules in [ARCHITECTURE](ARCHITECTURE.md).

---

## 5. Non-functional requirements (the headline)

Performance and stability are the product. These are measured automatically in CI on the
reference machine and gate every merge (see [PERFORMANCE](PERFORMANCE.md), ADR-0011).

**Reference machine:** Apple Silicon, M1 Pro / 16 GB, macOS 14+. "1080p30" = 1920×1080 at
30 fps H.264/HEVC; "4K" = 3840×2160.

| ID | Requirement | Target |
|----|-------------|--------|
| NFR-PERF-001 | Cold app launch to interactive | ≤ 1.5 s `[v1]` |
| NFR-PERF-002 | Open a 50-clip project to interactive | ≤ 2.0 s `[v1]` |
| NFR-PERF-003 | Timeline playback, 1080p30, up to 4 simultaneous video layers + 2 effects | sustained real-time, **zero dropped frames** `[v1]` |
| NFR-PERF-004 | Timeline playback, 4K30, 2 layers + chroma key | sustained real-time on reference machine `[v1]` |
| NFR-PERF-005 | Scrub/seek latency (playhead to first correct frame on screen) | ≤ 1 frame / ≤ 50 ms `[v1]` |
| NFR-PERF-006 | UI interaction frame rate (drag, trim, zoom timeline) | 60 fps, no hitch > 16 ms `[v1]` |
| NFR-PERF-007 | Keystroke-to-edit latency (e.g. blade, ripple delete) | ≤ 50 ms `[v1]` |
| NFR-PERF-008 | Export 1080p30 H.264, 5-min timeline (hardware encode) | ≥ 3× real-time `[v1]` |
| NFR-PERF-009 | Idle memory footprint, 10-min 1080p project | ≤ 1.5 GB `[v1]` |
| NFR-PERF-010 | Idle CPU when paused on the timeline | < 3% `[v1]` |
| NFR-PERF-011 | Proxy generation throughput (1080p) | ≥ 5× real-time, background `[v1]` |

| ID | Requirement | Target |
|----|-------------|--------|
| NFR-STAB-001 | Crash-free sessions | ≥ 99.9% `[v1]` |
| NFR-STAB-002 | No data loss on crash/power-off | auto-save + crash recovery restores to ≤ 5 s of work `[v1]` |
| NFR-STAB-003 | `AjarCore` has zero force-unwraps / force-trys / `fatalError` on any input | enforced by lint + tests `[v1]` |
| NFR-STAB-004 | No data races | clean under Thread Sanitizer in CI `[v1]` |
| NFR-STAB-005 | No leaks during a 1-hour edit-and-playback soak | clean under a leak/allocations soak test `[v1]` |
| NFR-STAB-006 | Malformed / truncated media never crashes import | fuzz corpus passes `[v1]` |
| NFR-STAB-007 | Every destructive action is undoable | unbounded undo within a session `[v1]` |

| ID | Requirement | Target |
|----|-------------|--------|
| NFR-QUAL-001 | Render correctness | golden-frame tests within tolerance vs. references (ADR-0011) `[v1]` |
| NFR-QUAL-002 | Color accuracy | managed pipeline, round-trips Rec.709 & Display-P3 within ΔE tolerance `[v1]` |
| NFR-A11Y-001 | Accessibility | full keyboard control; VoiceOver labels on all controls `[v1]` |
| NFR-I18N-001 | Localization-ready | all user strings externalized; English ships, structure supports more `[v1]` |

---

## 6. Functional specification

### 6.1 Media import & management — area `MED`

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-MED-001 | Import video, audio, and still-image files via file picker, drag-and-drop, and folder import. | v1 |
| FR-MED-002 | Native fast path for H.264, HEVC (8/10-bit), ProRes (all flavors), and common stills (PNG, JPEG, HEIF, TIFF). Decode via VideoToolbox/AVFoundation. | v1 |
| FR-MED-003 | FFmpeg fallback for formats AVFoundation won't open (e.g. VP9/AV1-in-MKV, legacy codecs), transcoded to a working format on import. (ADR-0003) | v1 |
| FR-MED-004 | **Proxy / optimized media:** generate ProRes Proxy (or configurable) versions in the background; one-click toggle between proxy and original for playback; export always uses originals. | v1 |
| FR-MED-005 | Media pool / browser: thumbnails, hover-scrub preview, list & grid views, metadata (codec, resolution, fps, duration, color space), search and filter. | v1 |
| FR-MED-006 | Bins / folders to organize media; user-defined tags and ratings; smart collections by metadata. | v1.x |
| FR-MED-007 | Relink workflow when source media moves; clear "media offline" state that never blocks the app. | v1 |
| FR-MED-008 | Reference originals in place by default (no forced copy/import-into-library); optional "consolidate media" to a project folder. | v1.1 |
| FR-MED-009 | Audio waveform + video thumbnail extraction is incremental and cached on disk; never blocks the UI. | v1 |
| FR-MED-010 | Detect and surface variable-frame-rate sources; conform to a stable timebase on import. | v1 |

### 6.2 Timeline & editing model — area `TL`

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-TL-001 | **Multiple tracks:** unlimited video and audio tracks, independently lockable, mute/solo (audio), hide/show (video), per-track height. | v1 |
| FR-TL-002 | Track stacking order defines composite order (top track over lower); per-track enable. | v1 |
| FR-TL-003 | Core edit ops: insert, overwrite, append, replace, three-point edit (in/out + target). | v1 |
| FR-TL-004 | Trim ops: ripple, roll, slip, slide; blade/razor (split) at playhead or pointer; trim-to-playhead. | v1 |
| FR-TL-005 | Ripple delete (close gap) and lift (leave gap); copy/cut/paste of clips and attributes. | v1 |
| FR-TL-006 | Snapping (to playhead, clip edges, markers, keyframes) with a momentary disable modifier. | v1 |
| FR-TL-007 | Selection: single, range (in/out), multi-select, select-all-on-track, select-forward. | v1 |
| FR-TL-008 | Markers (timeline and clip), named/colored, with notes; navigate marker-to-marker. | v1 |
| FR-TL-009 | Linked A/V (video + its audio move/trim together) with a momentary unlink modifier; detach audio. | v1 |
| FR-TL-010 | Timeline zoom (horizontal + vertical), fit-to-window, zoom-to-selection; scrollable; minimap. | v1 |
| FR-TL-011 | Multiple sequences per project; open in tabs. | v1 |
| FR-TL-012 | Unlimited, branchable-free linear **undo/redo** spanning all edits and parameter changes (NFR-STAB-007). | v1 |
| FR-TL-013 | Adjustment layer / adjustment track: effects applied to everything beneath it. | v1.x |
| FR-TL-014 | Auto-save of timeline + project state at a configurable interval and on every significant edit (feeds NFR-STAB-002). | v1 |

### 6.3 Transforms — area `XFORM`

The transforms the user explicitly asked for, plus the rest of the standard set.

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-XFORM-001 | **Position** (X/Y translate) per clip, in canvas units. | v1 |
| FR-XFORM-002 | **Scale / zoom** (uniform and non-uniform X/Y), about a configurable **anchor point**. | v1 |
| FR-XFORM-003 | **Rotation** (degrees, unbounded, with revolution count for animation). | v1 |
| FR-XFORM-004 | **Opacity** (0–100%) and **blend mode** (normal, multiply, screen, overlay, add, etc.). | v1 |
| FR-XFORM-005 | **Crop** (inset L/T/R/B) and **flip** (horizontal/vertical). | v1 |
| FR-XFORM-006 | **Corner-pin / distort** (free 4-corner). | v1.x |
| FR-XFORM-007 | On-canvas direct manipulation: drag to move, handles to scale/rotate, anchor handle, live numeric readouts. | v1 |
| FR-XFORM-008 | All transform parameters are **keyframable** (see `KEY`). | v1 |
| FR-XFORM-009 | Drop shadow and basic stroke/outline as clip-level styles. | v1.x |

### 6.4 Keyframing & animation — area `KEY`

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-KEY-001 | Any animatable parameter (transform, opacity, effect params, audio gain/pan, color, crop, mask) can hold **keyframes**. | v1 |
| FR-KEY-002 | Add/move/delete keyframes; per-keyframe time + value; multi-select and nudge. | v1 |
| FR-KEY-003 | Interpolation modes per keyframe segment: **linear, hold/step, ease-in, ease-out, ease-in-out, and custom Bézier**. | v1 |
| FR-KEY-004 | A **curve editor** (graph view) for direct manipulation of value curves and Bézier handles, with multiple parameters overlaid. | v1.x[^adr-0020] |
| FR-KEY-005 | Keyframe lanes shown inline under the clip in the timeline for quick edits. | v1 |
| FR-KEY-006 | Spatial interpolation for position (smooth motion path on the canvas with editable tangents). | v1.x |
| FR-KEY-007 | Copy/paste keyframes and whole animations between clips and parameters. | v1.x[^adr-0020] |
| FR-KEY-008 | Time-remap keyframes integrate with the speed system (`SPD`). | v1.x[^adr-0020] |
| FR-KEY-009 | Keyframe interpolation is computed in `AjarCore` deterministically (testable without a GPU). | v1 |

### 6.5 Compositing, keying & masks — area `COMP`

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-COMP-001 | **Chroma key / green screen:** key on green/blue or sampled color; controls for tolerance, edge softness, spill suppression, and de-spill color correction. GPU (Metal) implementation. | v1 |
| FR-COMP-002 | Key refinement: choke/shrink matte, edge feather, view-matte (alpha) preview mode, light-wrap. | v1 |
| FR-COMP-003 | **Masks:** rectangle, ellipse, and free-form Bézier/polygon masks per effect or clip; feather; invert; multiple masks with add/subtract/intersect. | v1.x[^adr-0020] |
| FR-COMP-004 | Animated masks (mask shape + position keyframable) for simple rotoscoping. | v1.x |
| FR-COMP-005 | Luma key and basic alpha-channel passthrough for transparent media (e.g. PNG/ProRes 4444). | v1 |
| FR-COMP-006 | Blend modes (full set) at clip and track level; honor premultiplied alpha correctly. | v1 |
| FR-COMP-007 | Compositing happens in a linear-light, color-managed space (ADR-0010) for correct edges and blends. | v1 |

### 6.6 Compound clips & nesting — area `CMP`

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-CMP-001 | **Compound clip:** select clips across tracks and collapse them into a single nested clip that behaves like one clip on the timeline. | v1.x[^adr-0020] |
| FR-CMP-002 | Open a compound clip to edit its contents in its own timeline; changes propagate to all instances. | v1.x[^adr-0020] |
| FR-CMP-003 | Effects, transforms, speed, and keyframes can be applied to a compound clip as a whole. | v1.x[^adr-0020] |
| FR-CMP-004 | "Decompose" / break apart back into component clips in place. | v1.x[^adr-0020] |
| FR-CMP-005 | Nested compound clips (compounds within compounds) with cycle detection (a compound can never contain itself — enforced in `AjarCore`). | v1.x[^adr-0020] |
| FR-CMP-006 | Render caching of unchanged compound clips to keep playback real-time (ties to `PLAY` cache). | v1 |

Implementation note: M7 has started with the headless sequence-backed clip model, query-time
compound duration/timebase resolution, `AjarCore` cycle validation, and nested video rendering
through the content-hash cache. Compound creation/open/decompose UI, nested audio, disk cache
warming, and retiming remain in later M7 follow-ups.

### 6.7 Color — area `COL`

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-COL-001 | Primary correction: lift/gamma/gain (or shadows/mids/highlights), exposure, contrast, saturation, temperature/tint, vibrance. | v1 |
| FR-COL-002 | Curves: RGB master + per-channel; hue-vs-hue, hue-vs-sat, luma-vs-sat secondary curves. | v1.x |
| FR-COL-003 | **Scopes:** waveform, vectorscope, RGB parade, histogram — live, GPU-accelerated. | v1 |
| FR-COL-004 | **LUTs:** import and apply `.cube` 1D/3D LUTs (input/transform/look); adjustable strength. | v1 |
| FR-COL-005 | Color-managed pipeline with explicit working space; correct handling of Rec.709, sRGB, Display-P3 (ADR-0010). | v1 |
| FR-COL-006 | **HDR awareness:** open and tone-map HDR (HLG/PQ, Rec.2020) sources to an SDR timeline; HDR timeline + export. | v1.x[^adr-0020] |
| FR-COL-007 | Per-clip and adjustment-layer grades; copy grade between clips; save/recall looks. | v1 |
| FR-COL-008 | 10-bit internal processing to avoid banding. | v1 |

### 6.8 Audio — area `AUD`

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-AUD-001 | Multitrack audio with per-clip and per-track gain; **keyframable volume** (rubber-band on the clip) and pan. | v1 |
| FR-AUD-002 | Waveform display; sample-accurate trimming; fade-in/out handles + crossfades. | v1 |
| FR-AUD-003 | Real-time **mixer**: per-track faders, pan, mute/solo, master bus; true-peak meters with clip indication. | v1 |
| FR-AUD-004 | **Ducking:** automatically lower music under dialogue/voice (sidechain-style, keyframe-baked or live). | v1.x[^adr-0020] |
| FR-AUD-005 | **Noise reduction / de-noise** and basic EQ, compressor, limiter as built-in audio effects. | v1.x |
| FR-AUD-006 | Audio effect chain per clip/track; effects are keyframable. | v1.x |
| FR-AUD-007 | Audio meters and processing run on a real-time, glitch-free audio thread (no allocations on the audio render path — NFR-STAB). | v1 |
| FR-AUD-008 | Detach/replace audio; sync detached audio; basic waveform-based sync of dual-system audio. | v1 (detach), future (auto-sync) |
| FR-AUD-009 | Sample-rate conversion and channel mapping (mono/stereo/5.1 downmix) handled correctly. | v1 |

### 6.9 Titles, text & motion graphics — area `TXT`

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-TXT-001 | Rich text titles: font, size, weight, color, tracking, leading, alignment; multiple text boxes; system + user fonts. | v1 |
| FR-TXT-002 | Text styling: fill, stroke/outline, drop shadow, background box, gradient fill. | v1 |
| FR-TXT-003 | On-canvas text editing and positioning; safe-area / title-safe guides. | v1 |
| FR-TXT-004 | **Animated titles:** built-in presets (fade, slide, typewriter, pop, lower-thirds) — all built on the keyframe system. | v1 |
| FR-TXT-005 | Shapes (rectangle, ellipse, line, polygon) and simple vector graphics as generators. | v1.x |
| FR-TXT-006 | Title templates: save a styled/animated title as a reusable, parameterized template. | v1.x |
| FR-TXT-007 | Emoji and complex-script (RTL, combining) rendering via the system text stack. | v1 |

### 6.10 Effects & transitions — area `FX`

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-FX-001 | Transitions: cross-dissolve, dip-to-color, fade, push, slide, wipe family, zoom; adjustable duration; drag onto a cut or clip edge. | v1 |
| FR-FX-002 | Effects library: blur (gaussian/box/zoom), sharpen, glow, basic distortions, vignette, mirror, mosaic/pixelate, color effects, stylize set. | v1 (core set), v1.x (expanded) |
| FR-FX-003 | Effects stack per clip with reorder, enable/disable, reset, and per-parameter keyframing. | v1 |
| FR-FX-004 | Effect presets: save/recall a configured effect or a whole stack. | v1.x |
| FR-FX-005 | Built-in **stabilization** and lens/optical distortion correction. | future |
| FR-FX-006 | **Plugin API** for third-party effects/generators/transitions implemented as Metal shaders + a parameter manifest (ADR-0013). | v1.x |
| FR-FX-007 | Speed/transition/effect rendering is GPU-resident; no CPU readback on the playback path. | v1 |

### 6.11 Speed & time — area `SPD`

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-SPD-001 | Constant speed change (e.g. 50%, 200%) with pitch-corrected or pitch-shifted audio option. | v1 |
| FR-SPD-002 | **Speed ramping** (keyframed variable speed) via time-remap keyframes. | v1.x[^adr-0020] |
| FR-SPD-003 | Reverse; freeze frame (hold) at a point; instant "still" from a frame. | v1 |
| FR-SPD-004 | Frame-blending and **optical-flow** interpolation for smooth slow-motion. | v1.x (frame-blend v1) |
| FR-SPD-005 | Speed changes preview in real-time at the timeline target rate. | v1 |

### 6.12 Playback & preview — area `PLAY`

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-PLAY-001 | Real-time playback meeting NFR-PERF-003/004; J/K/L shuttle; play/pause; loop a range. | v1 |
| FR-PLAY-002 | Frame-accurate stepping (←/→), jump to in/out, start/end, next/prev edit or marker. | v1 |
| FR-PLAY-003 | Scrubbing with ≤ 1-frame latency (NFR-PERF-005); audio scrubbing toggle. | v1 |
| FR-PLAY-004 | Adaptive playback quality: drop to a lower preview resolution under load to hold real-time, snap back to full when paused (never drop frames silently — show a quality/dropped indicator). | v1.x if performance gates hold[^adr-0020] |
| FR-PLAY-005 | Render/playback cache: cache composited frames and unchanged segments to RAM + disk; background "render in place"; cache invalidation keyed to the render graph (ADR-0009). | v1 |
| FR-PLAY-006 | Full-screen and second-display playback; loupe/zoom of the canvas; safe-area & checkerboard-alpha overlays. | v1 (full-screen), v1.x (2nd display) |
| FR-PLAY-007 | Background rendering is fully pausable and never competes with interactive responsiveness (priority-aware — ADR-0012). | v1.x if performance gates hold[^adr-0020] |

### 6.13 Export & delivery — area `EXP`

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-EXP-001 | Export to H.264 and HEVC (8/10-bit) via VideoToolbox hardware encode; ProRes (422/422 HQ/4444); configurable bitrate/quality, fps, resolution. | v1 |
| FR-EXP-002 | Container support: MP4, MOV; audio AAC/PCM; correct color tagging on output (ADR-0010). | v1 |
| FR-EXP-003 | Presets for common targets (YouTube 1080p/4K, square, vertical 9:16, etc.); custom presets. | v1 |
| FR-EXP-004 | Export range (whole timeline / in-out), still-frame export (PNG/JPEG), and audio-only export. | v1 |
| FR-EXP-005 | **Background export queue:** batch multiple exports; continue editing while exporting; progress + time estimate; cancel/pause. | v1 |
| FR-EXP-006 | GIF and animated-image export. | v1.x |
| FR-EXP-007 | Export is deterministic and uses original (not proxy) media; verified by golden-frame export tests. | v1 |
| FR-EXP-008 | Direct upload to YouTube and similar. | future |

### 6.14 Project & document model — area `PROJ`

| ID | Requirement | Tag |
|----|-------------|-----|
| FR-PROJ-001 | A project is a documented `.ajar` package (see §9) containing sequences, media references, and settings — no media baked in by default. | v1 |
| FR-PROJ-002 | Save / Save As / revert; auto-save; crash recovery (NFR-STAB-002); version-on-save snapshots (keep N). | v1 |
| FR-PROJ-003 | Project settings: resolution, frame rate, color space, audio rate; sensible auto-detect from first clip. | v1 |
| FR-PROJ-004 | Import media references with stable IDs so relinking survives renames/moves (FR-MED-007). | v1 |
| FR-PROJ-005 | Backward/forward compatibility policy: the format is versioned and migratable; older Ajar opens newer projects read-only with a clear message. | v1 |
| FR-PROJ-006 | Import from other NLEs (FCPXML / OTIO). | future |

[^adr-0020]: Deferred by [ADR-0020](adr/0020-v1-scope-deferrals.md). The conditional
    FR-PLAY-004/007 deferrals require post-cache performance evidence before Acceptance.

---

## 7. User interface & experience

The interface is a single main window with a familiar NLE layout, tuned for calm and speed.

- **Layout:** media browser / effects (left), program monitor / canvas (center-top),
  inspector (right, context-sensitive: transform, effects, color, audio, text), timeline
  (bottom, full width). Panels are resizable, collapsible, and remember their state.
  Workspaces (Edit, Color, Audio, Titles) are saved layout presets.
- **Canvas:** the program monitor doubles as the direct-manipulation surface for transforms,
  masks, and on-canvas text (FR-XFORM-007, FR-COMP-003, FR-TXT-003).
- **Inspector:** every selected item exposes its parameters here, each with a keyframe toggle
  (the stopwatch), reset, and numeric + slider input.
- **Theme:** modern dark theme by default (deep neutral greys, one accent), plus a light
  variant; respects the system appearance setting. High contrast, legible at a glance,
  generous hit targets. `[v1]`
- **Motion & feel:** 60 fps interactions (NFR-PERF-006), spring-based panel and zoom
  animations, no spinners on the hot path. The app should feel *quiet and quick*.
- **Onboarding:** first-run shows a sample project; non-blocking tips; an always-available
  keyboard-shortcut overlay.
- **Keyboard-first:** every common action has a shortcut; shortcuts are remappable; an FCP/
  Premiere-familiar default set. Full keyboard navigation (NFR-A11Y-001). `[v1]`
- **Accessibility:** VoiceOver labels, Dynamic-Type-aware panel text, reduced-motion honoring,
  sufficient contrast. `[v1]`

Visual design language, exact spacing, and component specs are tracked in a forthcoming
`docs/DESIGN.md` (not blocking the spec); the build agent should produce a clickable UI
skeleton early (ROADMAP M2) for review.

---

## 8. Supported media (summary)

| Class | v1 native (fast path) | v1 via FFmpeg fallback | Export |
|-------|----------------------|------------------------|--------|
| Video | H.264, HEVC (8/10-bit), ProRes (Proxy/LT/422/HQ/4444), HDV/AVCHD where AVFoundation supports | VP9, AV1, legacy/DV, MKV-wrapped, odd codecs → transcode-to-ProRes on import | H.264, HEVC, ProRes |
| Image | PNG, JPEG, HEIF, TIFF, GIF (still) | WebP, exotic raw stills | PNG, JPEG |
| Audio | AAC, ALAC, PCM/WAV, AIFF, MP3 | FLAC, OGG/Vorbis, AC-3 | AAC, PCM |
| Color | Rec.709, sRGB, Display-P3; HDR HLG/PQ Rec.2020 (tone-mapped) | — | Tagged Rec.709 / P3 (HDR `[v1.x]`) |

Exotic formats are normalized at the import boundary so the playback engine only ever sees a
small set of well-behaved formats (ADR-0003). Hardware decode/encode is preferred everywhere
it is available.

---

## 9. Project file format — `.ajar`

Specified fully in ADR-0007. Summary:

- `.ajar` is a **package directory** (a macOS bundle) so it can hold sidecar resources while
  presenting as a single document.
- Internally: a versioned, human-readable, **diff-friendly** document (JSON, canonical key
  order) describing sequences, tracks, clips, effects, keyframes, and media references;
  plus a `media/` references manifest (paths + stable UUIDs + content hashes), an optional
  `caches/` dir (proxies/render cache, excluded from the doc's identity), and `versions/`
  snapshots.
- Media is **referenced, not embedded** by default (FR-MED-008); "consolidate" copies media
  in.
- The format is **versioned** with a migration path (FR-PROJ-005). The schema lives in
  `AjarCore` and is the same model used at runtime and in tests.

---

## 10. Platform & system requirements

- **OS:** macOS 14 (Sonoma) or later `[v1]` (revisit floor before 1.0).
- **Architecture:** Apple Silicon required for the v1 performance targets; Intel is best-effort
  and not gated by the NFRs.
- **Frameworks:** AVFoundation, VideoToolbox, Core Audio / AVAudioEngine, Core Image (select
  filters), Metal / MetalFX, AppKit + SwiftUI (ADR-0002/0003/0006).
- **Third-party:** FFmpeg (import/transcode boundary only, GPL-compatible build — ADR-0003/
  0004); no proprietary dependencies in the core.

---

## 11. Quality, testing & acceptance

Full strategy in [TESTING](TESTING.md). A feature is **done** only when:

1. Its functional requirements are met and demonstrated by automated tests.
2. `AjarCore` logic has unit tests; rendered output has **golden-frame** tests within tolerance.
3. It does not regress any NFR in §5 (the benchmark suite stays green — ADR-0011).
4. It is keyboard-accessible and VoiceOver-labelled where it has UI.
5. Docs/CHANGELOG updated; the relevant requirement IDs are referenced in tests.

These five points are the global **Definition of Done** the autonomous loop must satisfy per
task before a change is merge-eligible.

---

## 12. Traceability

Each requirement ID is referenced by: the ROADMAP milestone that schedules it, the tests that
verify it, and (where relevant) the ADR that constrains it. The build loop maintains this map;
a requirement with no covering test is considered unimplemented regardless of code presence.

---

## 13. Out of scope for v1 / future

Cross-platform (Win/Linux), iPad, cloud/collab, node-based color, Fairlight-class audio,
NLE interchange (FCPXML/OTIO/EDL), stock-media marketplace, AI features (auto-captions,
auto-reframe, generative), object/face tracking, 360/VR, direct social upload. None are
precluded by the architecture; several are eased by the `AjarCore`/UI split (ADR-0005) and the
plugin API (ADR-0013). They are simply not required for 1.0.

---

*This spec is a living document. Material changes go through an ADR or a spec PR and bump the
version at the top.*
