# Changelog

All notable changes to Editor Ajar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `AjarCore` and `AjarRender` luma-key settings with undoable set/clear commands, typed
  validation, `.ajar` compatibility, GPU luma matte evaluation, premultiplied alpha passthrough,
  evaluated effect cache keys, and golden coverage for FR-COMP-005.
- `AjarCore` and `AjarRender` primary color correction with lift/gamma/gain, exposure,
  contrast, saturation, temperature/tint, vibrance, undoable set/clear commands, `.ajar`
  compatibility, render-graph cache invalidation, and golden coverage for FR-COL-001.
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
