# ADR-0017: Title rendering architecture

- **Status:** Accepted
- **Date:** 2026-07-09
- **Deciders:** Mem
- **Tags:** text, model, rendering, caching, determinism

## Context

M8 opens the text track (FR-TXT-001, FR-TXT-007). Titles need rich styled text (font, size,
weight, color, tracking, leading, alignment; multiple boxes), emoji/complex-script rendering,
and the same stability/caching/golden contracts as every other visual source. ADR-0005/0011
forbid AppKit/CoreText/Metal in `AjarCore`. ADR-0009 requires content-hash-keyed caching.
NFR-STAB-003 forbids crashes on bad input. Goldens (ADR-0011) need a deterministic font
strategy across CI machines.

## Decision

1. **Title is a generator clip.** `ClipSource` gains `.title(TitleSource)`. A title clip is a
   normal timeline clip (source/timeline ranges, transform, effects, blade/copy) whose pixels
   are synthesized, not decoded from media. No media-pool entry is required.

2. **Text model lives in `AjarCore`.** `TitleSource` is pure Codable: ordered text boxes, each
   with canvas-space origin/size and styled runs (font family/size/weight, color, tracking,
   leading, alignment). Empty text is allowed. Validation is typed (size/tracking/leading
   ranges, non-empty font family, positive box size); failures never crash (NFR-STAB-003).
   New schema is additive: legacy media/sequence sources keep decoding; nested compound
   clips without title keys are unaffected.

3. **Rasterization lives in `AjarRender`.** CoreText (`CTFramesetter` per box) draws into a
   bitmap at **output resolution**, uploads once to a Metal texture, and composites like any
   other source. Rasterization runs on content change / first use for a given content hash +
   dimensions — **not** on the playback hot path beyond the texture upload. No CPU readback of
   composited frames for titles (ADR-0006 / PERFORMANCE §6).

4. **Cache identity.** The render graph emits a `title` node whose content hash folds in the
   full `TitleSource` payload (ADR-0009). The frame cache still keys by content hash +
   dimensions + color mode, so unchanged titles replay from cache; a style edit invalidates
   only the affected subgraph.

5. **Deterministic font strategy.** Goldens and the default missing-font fallback pin to the
   macOS-stable PostScript name **`Helvetica`**. Requested families are resolved by exact
   Core Text name match; if unavailable, render with Helvetica and surface a typed
   `TitleRenderError.fontUnavailable(requested:fallback:)` — still produce pixels, never crash.
   A bundled test font is not required for v1; if Helvetica ever diverges across OS majors,
   a later ADR may switch goldens to a repo-bundled font without changing the model.

6. **Reference establishment.** Text golden `reference.png` files are established from the **CI
   golden-frame runner** (`macos-14` in `.github/workflows/ci.yml`), not from arbitrary local
   machines. CoreText/emoji glyph rendering differs across macOS versions, so a render on a
   newer host may diverge from CI even with the Helvetica pin. Workflow for new or intentionally
   updated title goldens: push with a placeholder `reference.png` and tight tolerances
   (`maximumDeltaE` 1 / `minimumSSIM` 0.99 / `maximumAlphaDelta` 1); the gate fails and uploads
   the `golden-frame-actuals` artifact (`_actual/` + `_diff/`); download, review the images, and
   commit them as `reference.png` in an **explicit, reviewed** commit — never auto-promote
   without visual review (ADR-0011).

7. **FR-TXT-002 styling layer.** Stroke, drop shadow, and linear-gradient fill are optional
   static values on `TitleTextStyle`; the background box is optional on `TitleTextBox` because
   its geometry derives from that box's rendered text-run bounds. The existing solid color is
   the fallback when no gradient is present. Core Text shapes once; Core Graphics strokes or
   clips those shaped glyph paths, draws the rounded background first, and shadows the composed
   stroke + fill through a transparency layer. **Only linear gradients ship in v1** (start/end
   colors plus a canvas-space angle); radial and conic gradients remain future additive work.
   The title source has no animation container yet, so these values stay static until the
   FR-TXT-004 animation model supplies one. Bitmap/color glyph runs (such as Apple Color Emoji)
   retain their native system pixels because they have no outline path; path stroke/gradient
   styling applies to vector glyph runs, while shadow and background still cover the composed
   mixed-glyph result.

## Consequences

- FR-TXT-001 model edits are fully unit-testable in `AjarCore`; FR-TXT-007 pixel behavior is
  golden-tested through the existing harness.
- FR-TXT-002 styling stays legacy-safe through optional fields with sparse decode defaults; its
  five new references follow the CI-canonical establishment workflow above.
- Title clips participate in compound nesting, blade/copy, undo, and project codec paths
  without special-case project fields.
- **Costs:** CoreText layout can differ slightly across OS/font versions (mitigated by the
  Helvetica pin and CI-established references); animated titles (FR-TXT-004) layer on later.

## Alternatives considered

- **Model + rasterize both in AjarRender.** Breaks headless project codec / edit tests and
  ADR-0005.
- **CoreText in AjarCore via conditional import.** Violates the CI import boundary.
- **Attributed-string-only model with no layout boxes.** Loses multi-box lower-thirds (FR-TXT-001).
- **Bundle a free font for all runtime use.** Heavier packaging; reserved if Helvetica goldens
  prove unstable.

## References

- SPEC FR-TXT-001, FR-TXT-002, FR-TXT-007; [ARCHITECTURE §3–4](../ARCHITECTURE.md).
- [ADR-0005](0005-core-ui-separation.md), [ADR-0006](0006-gpu-compositing-metal.md),
  [ADR-0008](0008-timeline-data-model.md), [ADR-0009](0009-render-graph-and-caching.md),
  [ADR-0011](0011-testing-and-quality-gates.md),
  [ADR-0018](0018-schema-minor-versioning.md).
