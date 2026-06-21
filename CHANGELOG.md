# Changelog

All notable changes to Editor Ajar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
