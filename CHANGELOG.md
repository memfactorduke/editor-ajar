# Changelog

All notable changes to Editor Ajar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Hardened FR-CMP-004 decompose fidelity: expansion is now windowed to the compound clip's
  `sourceRange` (trimming partially-overlapping inner clips — including reverse/freeze-frame
  remaps — and dropping fully-outside ones), non-identity compound-level transform/effects/
  audio-mix/reverse/freeze attributes and source-timeline duration mismatches are rejected with
  typed errors instead of silently dropped, and nested clip-anchored markers are restored onto
  the parent through the window and speed mapping.
- Added FR-SPD-003 reverse and freeze-frame clip time-remaps with legacy-safe model fields,
  exact rational source-time mapping, render/audio compound handling, sustained freeze audio,
  cache-key invalidation, codec coverage, and golden frame/audio fixtures.
- Optimized NFR-QUAL-001 nested compound rendering so sequence-backed sources expose cached
  `rgba16Float` linear working textures directly, skip per-level present transfer passes, and
  keep same-content-hash cache entries separated by output descriptor.
- Added FR-CMP-004 compound-clip decomposition as an undoable `AjarCore` edit command, expanding
  sequence-backed clips back onto parent tracks with exact 2x/0.5x speed mapping, typed overlap
  and non-compound errors, and a documented leave-the-nested-sequence-in-place cleanup policy.
- Added FR-CMP-001/FR-AUD-003 nested compound audio rendering so sequence-backed audio clips
  contribute to offline/live control-side mixes, honor compound speed/gain, stop at the
  defensive nesting limit with typed errors, and carry golden-audio coverage.
- Hardened NFR-STAB-003/ADR-0012 Metal render execution by synchronizing shared executor caches
  and adding concurrent compound-render stress coverage for frame-cache and completion-handler
  races.
- Added FR-CMP-001 make-compound edit commands that collapse selected timeline clips into a new
  nested sequence, preserve relative multi-track layout, and route through undo/redo and codec
  coverage.
- Hardened FR-TL-013/NFR-QUAL-001 compound rendering with descriptor-aware frame-cache keys,
  half-float nested outputs, a bounded reusable texture pool, leaner compound hash payloads,
  and a more discriminating nested-transform golden fixture.
- Hardened FR-TL-013 compound-clip cycle detection with iterative graph traversal plus
  transitive decode, three-node cycle, and insert-command commit-guard coverage.
- Added FR-SPD-001 constant-rate clip speed with exact rational speed storage,
  undoable speed edits, retimed render-graph source-time mapping, speed-aware audio rendering,
  `.ajar` round-trip/default coverage, and golden frame/audio fixtures for 2x and 0.5x retiming.
- Added M7 compound-clip video rendering for FR-TL-013/FR-CMP-006 with nested render graphs,
  content-hash cache reuse/invalidation, bounded GPU texture cache coverage, and a golden-frame
  fixture for a transformed inner sequence.
- Added the M7 compound-clip core model for FR-TL-013/FR-CMP-001/005 with
  sequence-backed clip resolution, direct/transitive cycle validation, codec round trips,
  and an undoable insert-compound command.
- Added FR-AUD-003 loudness normalization reports that compute deterministic master-gain
  recommendations for target LUFS values, optional true-peak ceilings, sequence rendering,
  peak-limited outcomes, and silent-program typed errors.
- Hardened FR-AUD-003 program loudness accuracy with the BS.1770-4 RLB high-pass numerator,
  standard-referenced LUFS baselines, stronger true-peak coverage, and an explicit
  mono/stereo guard until layout-aware surround weights are available.
- Hardened live FR-AUD-007 + FR-PLAY-001/003 audio playback with background look-ahead
  refills, paused-scrub publishing gates, channel-count validation, extra-buffer zeroing,
  and windowed deterministic sample-tone rendering for the bundled playback project.
- Added live FR-AUD-007 + FR-PLAY-001/003 audio output with an AVAudioEngine driver
  consuming lock-free realtime render plans, app transport start/stop publishing, and a
  deterministic sample-tone source for the bundled playback project.
- Added deterministic FR-AUD-003 program loudness analysis with BS.1770/R128 integrated LUFS,
  gated silence handling, and 4x offline true-peak dBTP estimation for rendered mixes.
- Added an FR-AUD-007 realtime render-plan handoff in `AjarAudio` using a lock-free atomic
  slot ring so control-side plan publishes stay off the audio callback path.
- Hardened FR-AUD-004 ducking with hold-at-reached-level envelope behavior, multi-rule
  multiplicative target coverage, trigger/target order-independence tests, and a ramp-shaped
  golden-audio fixture.
- Added deterministic FR-AUD-003 mixer metering in `AjarAudio` with per-track and summed
  master peak/RMS levels, 0 dBFS = 1.0 conversion helpers, Codable reports, and typed
  offline render errors.
- Hardened FR-AUD-003/007/009 audio-engine checks with storage-kind-derived realtime safety
  reporting, explicit float master-bus headroom and pan-law documentation, golden-audio
  two-run determinism coverage, and solo/mute/disabled selection tests.
- `AjarCore` and `AjarAudio` deterministic sidechain audio ducking for FR-AUD-004 with
  validated sequence rules, undoable set/clear commands, offline attack/hold/release envelope
  rendering, `.ajar` codec defaults, and golden-audio coverage.
- `AjarAudio` waveform summary generation for FR-AUD-002 with deterministic per-channel
  peak/RMS bins, partial-final-bin handling, typed resolution errors, and Codable cache output.
- Hardened FR-AUD-003/007 audio mixer follow-ups with multi-clip and multi-track summation
  golden-audio fixtures, pointer-backed realtime render plans, selected-track crossfade
  validation, 5.1-to-stereo downmixing, and overflow-safe sample counts.
- `AjarCore` detach/replace audio edit commands for FR-AUD-008 with undoable linked-audio
  detaching, audio-source replacement validation, and `.ajar` round-trip coverage.
- Hardened FR-AUD-001 audio model follow-ups with animation-preserving clip audio edits,
  sparse `.ajar` audio-mix decoding coverage, video-track audio-field round trips, and
  typed pre-validation for invalid track audio patches.
- `AjarAudio` deterministic offline audio mixer with gain/pan/fade evaluation, mix-time
  automation clamping, crossfade adjacency validation, sample-rate/channel mapping,
  `ajar render-audio` WAV output, a golden-audio harness, and CI coverage for FR-AUD-003/007/009.
- `AjarCore` audio mix model for FR-AUD-001 with keyframable clip and track gain/pan,
  clip fade and crossfade metadata, typed validation, undoable set/clear commands, and
  `.ajar` legacy defaults.
- Hardened FR-COL-003 GPU scopes with width-keyed triple-buffered resource pooling,
  display-encoded input API documentation, density-graded scope textures, and a report-only
  scope analyzer benchmark.
- Hardened FR-COMP-001/002 chroma-key choke coverage with fractional multi-pixel matte
  assertions, documented normalized-chroma/border-erosion limits, and a report-only 4K30
  two-layer choke benchmark for NFR-PERF-004.
- Hardened FR-COMP-003 mask follow-ups with effect-animation-preserving edits, narrowed legacy
  animatable effect decoding tests, mask cache-key field coverage, pinned flip/mask render
  behavior, de-duplicated mask validation errors, and source-space polygon documentation.
- Hardened FR-COMP-006 track compositing follow-ups with forward-compatible blend-mode
  decoding, documented track/clip blend precedence, split cache-key tests, and selected-track
  opacity/blend inspector controls.
- Hardened luma-key/alpha passthrough follow-ups for FR-COMP-005 with sparse `.ajar`
  decode defaults, full-field cache-key coverage, a documented premultiplied source-texture
  contract, and spatial alpha-edge Metal coverage.
- `AjarRender` GPU scope analyzer for FR-COL-003 with histogram, waveform, RGB parade, and
  vectorscope buffers plus rendered scope textures and deterministic Metal coverage.
- `AjarRender` chroma-key hardening with chroma-normalized matte distance, spatial choke
  erosion for hard mattes, faithful mid-range view-matte preview output, Swift/Metal uniform ABI
  guard coverage, and golden coverage for FR-COMP-001/002.
- `AjarCore` and `AjarRender` complete standard blend-mode set with track-level
  blend/opacity, premultiplied-alpha-correct Metal compositing, cache invalidation, and
  golden coverage for FR-COMP-006.
- `AjarCore` and `AjarRender` luma-key settings with undoable set/clear commands, typed
  validation, `.ajar` compatibility, GPU luma matte evaluation, premultiplied alpha passthrough,
  evaluated effect cache keys, and golden coverage for FR-COMP-005.
- `AjarCore` and `AjarRender` primary color correction with lift/gamma/gain, exposure,
  contrast, saturation, temperature/tint, vibrance, undoable set/clear commands, `.ajar`
  compatibility, render-graph cache invalidation, and golden coverage for FR-COL-001.
- Hardened primary color-correction decoding for sparse legacy `.ajar` payloads, documented the
  shader grading order, and added lift/gamma/gain golden plus vibrance GPU pixel coverage.
- `AjarCore` and `AjarRender` clip masks with rectangle, ellipse, and polygon/Bézier-point-list
  shapes, feathering, invert, add/subtract/intersect combine modes, undoable reducer commands,
  `.ajar` compatibility, render-graph cache invalidation, and golden coverage for FR-COMP-003.
- `AjarRender` GPU chroma-key shader with linear-light matte evaluation, de-spill, choke,
  view-matte preview, evaluated effect cache keys, and golden coverage for FR-COMP-001/002.
- `AjarRender` linear-light compositing with half-float working textures, explicit color-space
  transfer/primary conversion, cache-key color metadata, and golden coverage for FR-COMP-007,
  FR-COL-005/008, ADR-0010, and NFR-QUAL-002.
- `AjarCore` clip effects and chroma-key settings model with undoable reducer commands,
  validation, `.ajar` codec compatibility, and render-graph propagation for FR-COMP-001.
- Transform/keyframe UI in the macOS app, including reducer-backed inspector fields,
  program-monitor manipulation handles, inline timeline keyframe lanes, and UI-smoke coverage
  for FR-XFORM-007 and FR-KEY-005.
- Animated transform rendering now evaluates keyframed clip transforms at render time, with
  multi-time golden fixtures and a report-only multi-layer transform benchmark for FR-XFORM-008,
  FR-KEY-001/003, and NFR-PERF-003.
- Keyframed clip transform animation in `AjarCore`, including deterministic cubic Bézier/ease
  interpolation, undoable add/move/delete keyframe commands, validation, and `.ajar` round-trip
  coverage for FR-KEY-001/002/003/009 and FR-XFORM-008.
- `AjarRender` static clip transforms in the Metal composite path with render-graph cache
  invalidation and golden-frame coverage for FR-XFORM-001..005.
- `AjarCore` per-clip transform model and undoable set-transform reducer command with exact
  position/scale/anchor/rotation/opacity/blend/crop/flip storage for FR-XFORM-001..005.
- Multi-sequence project editing with undoable core add/remove/duplicate sequence commands,
  `.ajar` two-sequence round-trip coverage, and macOS sequence tabs that preserve per-sequence
  timeline editing context for FR-TL-011.
- Undo/redo menu items, standard keyboard shortcuts, action-name labels, redo support, and
  UI-smoke shortcut coverage in the macOS app for FR-TL-012.
- Linked A/V clip groups in `AjarCore`, including undoable link/unlink commands, linked
  move/trim propagation, momentary unlink edit mode, `.ajar` codec coverage, and macOS detach
  audio controls for FR-TL-009.
- Named, colored, note-bearing timeline and clip markers with undoable reducer commands, pure
  next/previous navigation, codec compatibility, and macOS timeline/inspector controls for
  FR-TL-008 and FR-PLAY-002.
- `AjarCore` auto-save snapshot, command journal, and best-effort recovery helpers with app
  launch/checkpoint wiring for FR-TL-014 and NFR-STAB-002.
- Timeline zoom, selection, range, and snapping interaction state in the macOS app with pure
  helper tests for FR-TL-006/007/010.
- Multi-track timeline lanes in the macOS app with reducer-backed track enable, lock, hide,
  mute, and solo toggles for FR-TL-001/002.
- `AjarCore` track-state edit command and ordered multi-input render graph composition for
  FR-TL-001/002.
- `AjarCore` trim reducer commands for blade, ripple trim, roll, slip, slide,
  ripple-delete, and lift with undo coverage for FR-TL-004/005/012.
- `AjarCore` edit reducer commands for insert, overwrite, append, replace-source, and
  three-point edits with undo coverage for FR-TL-003/012.
- macOS app XCUITest smoke target and CI job for the ROADMAP M2 launch/play gate
  (NFR-A11Y-001).
- `ajar bench` report-only JSON metrics, baseline capture, and CI benchmark reporting for
  NFR-PERF-001/002/005 under ADR-0011.
- Metal-backed program monitor playback in the macOS app for the synthetic single-clip sequence
  (FR-PLAY-001/003), including display-link play/pause, stepping, and scrubbing.
- `ajar render --frame` PNG output plus the first manifest-driven golden-frame gate in CI
  (TESTING §2, ADR-0011, NFR-QUAL-001).
- `AjarRender` Metal render graph executor for single-clip composites with content-hash frame
  caching and CVMetalTexture-backed source tests.
- Minimal macOS SwiftUI app shell under `app/EditorAjar` with FR-PLAY-001 transport controls and
  NFR-A11Y-001 accessibility labels.
- `AjarMedia` native AVFoundation frame decoder with CVMetalTextureCache zero-copy handoff tests.
- `AjarCore` immutable render graph primitives and single-clip graph builder with deterministic
  content hashes.
- `AjarCore` animatable parameter, keyframe, interpolation mode, and deterministic linear/hold
  evaluation primitives.
- `AjarCore` canonical `.ajar` project JSON codec with schema migration and typed loader errors.
- `AjarCore` edit command reducer and unbounded per-session undo/redo history.
- `AjarCore` project, sequence, track, clip, and validation primitives for the M1 timeline model.
- `AjarCore` `MediaRef`, media metadata, content hashing, and relink-match primitives.
- `AjarCore` exact `RationalTime`, `FrameRate`, and `TimeRange` primitives for M1 timeline math.
- Repository scaffold: master specification, architecture docs, founding ADRs (0001–0014).
- Swift package skeleton with the `AjarCore` / `AjarRender` / `AjarMedia` / `AjarAudio`
  module split and the `ajar` headless CLI.
- CI quality gates (build, unit, golden-frame, benchmark) and the autonomous-loop agent guide.

[Unreleased]: https://github.com/editor-ajar/editor-ajar/commits/main
