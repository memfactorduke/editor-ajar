# Editor Ajar — Glossary

> Shared vocabulary for the spec, code, tests, and the build agent. When a term is capitalized
> in docs (e.g. *Sequence*), it refers to the definition here / the model type in `AjarCore`.

**Anchor point** — The pivot a clip scales and rotates around (FR-XFORM-002).

**Animatable** — A parameter that holds a base value plus optional Keyframes; evaluated at a
given time to a concrete value. The unit of animation in `AjarCore`.

**Bin** — A folder in the Media Pool for organizing media (FR-MED-006).

**Blend mode** — How a layer combines with what's beneath (normal, multiply, screen, …).

**Chroma key** — Making a color (typically green/blue) transparent to composite a subject over
a new background; "green screen" (FR-COMP-001).

**Clip** — An instance of a media source (or a Compound clip) placed on a Track, with its own
source range, timeline range, transform, effects, speed, and audio params.

**Compositing** — Combining multiple layers into one image, respecting transforms, masks,
blend modes, and alpha — done in linear-light, color-managed space.

**Compound clip** — Several clips collapsed into one nested, reusable clip that edits like a
single clip; opens into its own timeline (FR-CMP-001).

**Curve editor** — Graph view for editing Animatable value curves and Bézier handles
(FR-KEY-004).

**Display link** — The macOS callback synced to the display refresh that drives playback timing.

**Golden frame** — A stored reference image a render is compared against (within tolerance) to
detect visual regressions (ADR-0011).

**Keyframe** — A (time, value) anchor on an Animatable; segments between keyframes interpolate
by a chosen mode (linear/hold/ease/Bézier) (FR-KEY-003).

**LUT** — Look-Up Table (`.cube`) mapping input colors to output colors for grading
(FR-COL-004).

**Mask** — A shape (rect/ellipse/Bézier) limiting where a clip or effect applies; feather-able,
invertible, combinable (FR-COMP-003).

**Media Pool / Browser** — The panel listing imported media with thumbnails and metadata
(FR-MED-005).

**MediaRef** — A stable reference (UUID + URL + content hash + probed metadata) to a source
file; clips point at MediaRefs so relinking survives moves (FR-PROJ-004).

**NLE** — Non-Linear Editor; the category Editor Ajar belongs to.

**Optical flow** — Motion-estimation method for generating in-between frames for smooth
slow-motion (FR-SPD-004).

**Program monitor / Canvas** — The preview of the composited sequence; also the
direct-manipulation surface for transforms, masks, and text.

**Proxy / optimized media** — Lower-cost stand-in media (e.g. ProRes Proxy) used for fast
playback; export uses originals (FR-MED-004).

**RationalTime** — Exact time as value/timescale (like CMTime); used everywhere instead of
floats to prevent drift.

**Render graph** — An immutable DAG describing how to produce a frame; built by `AjarCore`,
executed by `AjarRender`; content-hashed for caching (ADR-0009).

**Ripple / Roll / Slip / Slide** — Trim operations. Ripple moves downstream clips; roll moves a
shared edit point; slip changes a clip's source range without moving it; slide moves a clip
between its neighbors (FR-TL-004).

**Scopes** — Waveform, vectorscope, RGB parade, histogram — instruments for color
(FR-COL-003).

**Sequence** — A timeline: ordered video and audio Tracks plus markers and settings. A Project
has one or more.

**Speed ramp** — Keyframed variable playback speed across a clip (FR-SPD-002).

**Spill suppression** — Removing key-color contamination (e.g. green fringe) from a keyed
subject (FR-COMP-001).

**Three-point edit** — An edit defined by three of {source in, source out, timeline in,
timeline out} (FR-TL-003).

**Track** — A horizontal lane holding non-overlapping TimelineItems; video tracks composite by
stacking order, audio tracks sum into the mix.

**Transition** — A blend between two clips or at a clip edge (cross-dissolve, wipe, …)
(FR-FX-001).

**Transform** — Position, scale, rotation, anchor, crop, opacity, blend mode of a clip
(FR-XFORM-*).

**Working space** — The (linear-light) color space compositing happens in (ADR-0010).
