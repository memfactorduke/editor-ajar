# Changelog

All notable changes to Editor Ajar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Frame-blend slow-motion smoothing (FR-SPD-004 v1), closing #170: a per-clip
  `frameSampling` mode (`nearest` default, `frameBlend` opt-in) that blends the two source
  frames adjacent to a fractional source frame position, weighted by the fractional part, in
  LINEAR working light (ADR-0010) via a dedicated pre-composite Metal pass. The blend fraction
  is always measured toward the later source frame on the resolved decode-time axis, so
  reverse playback blends the same frame pairs with the same weights as forward playback;
  freeze frames hold a single decoded frame and explicitly degenerate to nearest, as do
  integer frame positions and the last decodable frame of a span. The mode is additive in the
  project schema (absent key decodes to `nearest`) and folds into the render-graph content
  hash as an optional field, so pre-FR-SPD-004 projects and nearest-mode clips keep
  byte-identical cache identities and the feature is zero-cost when off. Optical-flow
  interpolation stays out of scope (v1.x). New `frame-blend-half-speed` golden fixture with
  calibrated wrong-variant signals (nearest maxDeltaE 41.4, wrong-weight 23.0 vs tolerance 10
  and the ~4.6 cross-machine noise floor).
- `ajar soak`: headless leak/allocations soak harness plus a per-PR CI soak gate
  (NFR-STAB-005, TESTING §8), closing #169. Each iteration runs a deterministic seeded
  (SplitMix64, `--seed`) scripted loop inside autoreleasepool boundaries: `EditReducer`/
  `EditHistory` edits with full undo/redo replay (blade, trim, constant-speed retime,
  time-remap, compound make + decompose, crossfade add + remove), render-graph builds,
  offline audio mixes exercising the compound audio source cache, realtime plan
  publish/consume handoff cycles (`ownedPointer` slot reclamation), and — when a GPU is
  present — offline video renders through the CLI decode path with disk-frame-cache
  persist/lookup/quarantine/reset churn and RAM-tier eviction across three cycled synthetic
  project variants. After a documented warmup, the mach `task_info` footprint trend must stay
  within a configurable growth band (default 64 MiB), with no monotonic quartile growth beyond
  8 MiB and — from 2,000 post-warmup samples up, so short runs cannot flake on jitter — a
  least-squares fitted growth of at most 8 MiB across the window, giving the 1-hour acceptance
  run a documented ~8 MiB/hour slow-linear-leak detection floor (TESTING §8); violations fail
  with typed `SoakError`s carrying the growth curve. CI runs
  `ajar soak --duration-seconds 150` per PR (`timeout-minutes: 10`); the 1-hour run
  (`ajar soak --duration-seconds 3600`) is the pre-release NFR-STAB-005 acceptance run.
- Blade fidelity for retimed and keyframe-animated clips (FR-SPD-002, FR-SPD-003, FR-TL-004,
  FR-XFORM-008), closing #166 and lifting the `bladeUnsupportedForRetimedClip` limitation from
  the ADR-0015 §8 blade work: blading a **reversed** clip now splits the source range
  direction-aware — the left half receives the TAIL of the source range (`[e − L·speed, e)` for
  a blade at timeline offset `L` of source `[s, e)`) so both halves reproduce the unbladed
  timeline-to-source mapping RationalTime-exactly, and the redistributed crossfade pair still
  clamps against the reversed tail handle past `sourceRange.start`; blading a **time-remapped**
  clip splits the FR-SPD-002 curve at the blade offset — a boundary keyframe evaluated at the
  split point re-terminates the left curve and anchors the right curve at its new local time
  zero, with every curve invariant preserved; blading a **keyframe-animated** clip splits every
  animatable transform/effects parameter at the cut — each half keeps its own keyframes plus a
  shared boundary keyframe evaluated at the cut, and the segment crossing the cut has its
  easing subdivided (De Casteljau split of the cubic Bezier timing curve, renormalized to unit
  curves — exact for overshooting easings too, with an interior keyframe baked when the
  overshoot returns to an endpoint progress exactly at the cut and a renormalization
  denominator vanishes) so the rendered animation is unchanged by the blade. Keyframe-time
  validation now
  accepts the closed range `[start, end]` — the exclusive end is never sampled, but an end
  keyframe shapes the approach into the cut, mirroring the
  FR-SPD-002 final-keyframe-at-source-end rule. The now-unreachable
  `bladeUnsupportedForRetimedClip` typed error is removed.
- Disk-backed render cache behind the RAM tier (FR-PLAY-005, FR-CMP-006, ADR-0009): a new
  `MetalDiskFrameCache` persists rendered frames keyed by the same identity as the executor's
  RAM cache (content hash + color mode + pixel format + dimensions) in a versioned, checksummed
  on-disk format (`AJFC` v1). The playback path never blocks on disk (ADR-0012): a RAM miss
  returns a typed `RenderFrameCacheDisposition` miss and renders normally while an asynchronous
  disk lookup warms the RAM tier for subsequent frames; population is write-behind via
  `persist(frame:output:)`, called only from offline/background render routes so CPU readback
  never runs on the playback path. Corrupt, truncated, or identity-mismatched entries read as
  misses and are quarantined (deleted), never wrong pixels. Eviction is deterministic
  byte-budgeted LRU (pure `ByteBudgetedLRUIndex` in `AjarCore`, 512 MiB default budget), and
  `MetalRenderExecutor.prefetchCachedFrame` warms frames across process restarts. A new
  `disk-cache-warm-start-playback` benchmark shows warm-disk start beating a cold render.
- Landed the final slice of the FR-AUD-002 audio crossfade work per ADR-0015, closing #102:
  new `setClipAudioCrossfade` / `removeClipAudioCrossfade` edit commands create and delete a
  §5 pair atomically — the outgoing clip gets the owning trailing record, the incoming clip
  the non-rendering mirror, the duration is clamped to the §3 tail handle and clip durations
  (clamping to zero is the typed `crossfadeExceedsSourceHandle` rejection), the §4 curve is
  auto-selected direction-aware (`linear` for same-source contiguous blade-split edges —
  forward pairs continue end-into-start, reversed pairs continue start-into-end —
  `equalPower` otherwise, explicit override wins), and same-edge fades are cleared in the
  same undoable command so `crossfadeConflictsWithFade` is unreachable through the command
  (§6). The §8 edit-command interaction matrix is implemented across the edit commands that
  mutate cut geometry: blade redistributes the records (leading stays on the left half,
  trailing moves to the right half with the partner mirror re-pointed) and rejects blading
  inside an active transition region with the typed `bladeInsideCrossfadeRegion` error;
  ripple trim, roll, slip, slide, in-place trim, and constant-speed retimes preserve pairs
  and clamp their duration to the post-edit handle and clip durations, removing the pair
  when the clamp reaches zero or the partners no longer abut; lift, ripple delete, and
  adjacency-breaking moves remove the affected pairs and clear the neighbors' mirrors with
  no automatic crossfade on new cuts (the trim/move/set-speed rows were added to the ADR §8
  table). Blade now preserves non-retime clip attributes on both halves (base transform,
  effects, gain/pan automation; `fadeIn` stays on the left half, `fadeOut` moves to the
  right half, a bladed freeze frame holds the same frame on both halves); reversed and
  time-remapped clips were initially rejected with a typed error rather than silently
  producing wrong source ranges (the limitation was lifted by #166 above). Every
  matrix behavior is taxonomy-validated and undo-exact, and a new meter-parity test asserts
  `AudioMixerMeterAnalyzer` agrees with the rendered mix across a crossfaded cut including
  the fade-tail region.
- Landed slice 2 of the FR-AUD-002 audio crossfade work per ADR-0015: `OfflineAudioMixer` now
  renders true fade-tail crossfades — for a taxonomy-valid pair the outgoing clip's source
  keeps playing past its timeline out-point for the transition duration, mapped through its
  retime (constant speed extends linearly, reverse continues backward past
  `sourceRange.start`, freeze frames hold their frame, compound sources read the nested
  sequence past the window), summed with the incoming clip under the §4 curve contract
  (`equalPower`: `sin(πx/2)`/`cos(πx/2)`; `linear`: `x`/`1−x`) with exact rational
  positioning. The §3 effective read window is now the audio acquisition unit:
  `CompoundAudioSourceKey` hashes the tail-extended window so adding, removing, or resizing a
  crossfade invalidates the compound source cache, and crossfade tails flow into ducking
  triggers and — via the delegating plan builder — realtime playback with exact offline
  parity; ducking detection samples through the same tail-aware, EOF-clamped source mapping
  the mixer plays, so reverse or past-EOF tails can never duck a target on audio the mix
  does not render. §7 render-time shortfalls are distinguished: a tail past the declared
  media duration silence-pads deterministically (clamped at the declared end regardless of
  provider over-delivery), while provider under-delivery within declared bounds surfaces the
  new typed `AudioRenderError.sourceUnderDelivered` (clip ID plus missing source range)
  instead of silent zeros — checked only for renders whose window actually mixes tail frames,
  so chunked renders of unrelated timeline regions never fail for a clip they do not play. Added golden-audio fixtures `crossfade-correlated-linear` (a blade-split pair
  holds exactly the uncut source — the reverted #101 sequential-fades rendering measures
  maxAbsError 5.0 with a hard 0 at the boundary frame) and
  `crossfade-uncorrelated-equal-power` (constant-power curve application), a
  `crossfadeToNext` golden-audio manifest spec that wires valid pairs, and the ADR-0015
  slice-1 clarification subsection. The §8 edit-command matrix and meter coverage remain
  later slices of #102.
- Landed slice 1 of the FR-AUD-002 audio crossfade work per ADR-0015: the additive
  `equalPower` fade curve (`sin(πx/2)`, round-tripped through the full project codec with a
  nested-legacy decode test), the §5 pair-agreement taxonomy as validation in `AjarCore`
  (`ClipAudioCrossfadeValidator`, surfaced as `invalidClipAudioCrossfade` project validation
  errors and reused by the render-time `OfflineAudioMixer` crossfade check) with typed errors
  `crossfadeMirrorMissing`, `crossfadePairMismatched`, `crossfadeDirectionInvalid`, and
  `crossfadeSeparatedByGap` alongside the existing partner checks, the §6 fade × crossfade
  same-edge exclusion (`crossfadeConflictsWithFade`), the §4 curve restriction
  (`crossfadeCurveUnsupported` for ease curves on crossfade edges), the §2 time-remap
  rejection (`crossfadeUnsupportedWithTimeRemap`), and §3 effective-read-window handle
  validation (`crossfadeExceedsSourceHandle`: constant speed multiplies the tail window,
  reverse extends backward past `sourceRange.start`, freeze frames need no extra media).
  Mixer tail rendering, edit-command crossfade maintenance, and realtime parity are later
  slices of #102.
- Realtime playback of compound audio (FR-AUD-007, FR-CMP-001):
  `RealtimeAudioRenderPlan.preparingCompoundMix` builds the live callback plan off the audio
  thread by flattening nested/compound sources — any depth, cycle-guarded with typed errors —
  through the same offline-mixer contributor selection used by export renders and meters
  (audible-content-gated video-track contribution, #156 solo/mute/enabled semantics), so
  compound clips on audio tracks and sequence-backed compounds on video tracks are audible in
  live playback and match the offline mix sample-for-sample; the render callback keeps
  consuming a fixed-size, pre-rendered owned-pointer plan (no recursion, locks, or allocation),
  and the app's live-audio coordinator now routes through the new builder. Strengthened the
  plan-handoff hazard handshake from seq_cst fences around release/acquire tokens to explicit
  `seq_cst` store/load atomics (a store-then-load-from-a-different-location handshake needs the
  single total order), covered by a new compound plan-swap stress test that runs clean under
  Thread Sanitizer alongside RT-vs-offline parity, video-track/solo/visual-only,
  nested-depth-2, live-driver, and callback-contract safety-report tests.
- Hardened the NFR-QUAL-001 nested-compound render contract: linear-working output is now an
  explicit `RenderOutputDescriptor.colorMode` (`.presented` by default) instead of being
  inferred from the rgba16Float pixel format, so a future HDR-presented half-float output can
  never silently skip the display-transfer present pass; the content-hash frame cache keys on
  the mode so presented and linear-working frames of identical dimensions/format never
  collide, with pinning tests for both behaviors. Added a mid-tone compound golden fixture
  (`compound-clip-mid-tone`, bgra [32,64,128,255]) because the existing pure-red compound
  fixture sits on a transfer-function fixed point and measures deltaE 0.000 under a
  linear-passthrough regression; the new fixture discriminates the two wrong implementations
  at measured maxDeltaE 24.795 (dropped `sourceIsLinearWorking` double-decode) and 23.864
  (per-level present with skipped decode) against a tolerance of 10, calibrated at least 2x
  above the ~4.6 cross-machine decode noise floor.
- Completed FR-SPD-001 clip-speed follow-ups: `setClipSpeed` now propagates the retime through
  FR-TL-009 linked A/V groups (linked partners take the same constant rate and resize
  identically, keeping A/V sync sample-exact; a linked partner carrying an FR-SPD-002 time-remap
  curve rejects the whole edit with the existing typed `conflictingRetime` validation error
  instead of silently desyncing) and ripples every affected track by the duration delta using
  the ripple-trim convention (slow-downs push later items right, speed-ups pull them left with
  no gap), replacing the previous `itemsOverlap` rejection when a slow-down grew into the next
  item. Added the `clip-speed-2x-tail` golden frame fixture sampling near the retimed clip's
  tail over a steepened synthetic ramp so a speed-ignored regression measures maxDeltaE 70.9
  (inverted speed 93.6) against tolerance 10 — the existing `clip-speed-2x` midpoint sample
  measured only ~8 under its 25 tolerance. The FR-SPD-001 pitch-corrected (pitch-preserving)
  audio option is split into a follow-up issue with a deterministic WSOLA proposal.
- Completed the FR-CMP-001 make-compound follow-ups: collapsing now transplants FR-AUD-004
  sidechain ducking rules whose referenced audio tracks are all fully collapsed into the nested
  sequence (rules referencing no collapsed track stay outer; rules spanning the collapse
  boundary reject the edit with a typed `compoundSelectionSeversAudioDucking` error instead of
  silently severing the sidechain, and undo restores the exact original ducking configuration),
  FR-CMP-004 decompose symmetrically restores fully-expanded nested rules onto the parent
  (deduplicated, command-level inverse; boundary-spanning nested rules reject with a typed
  `compoundDecomposeSeversAudioDucking` error), and fixed nested audio playback so the `.video`
  compound clip a collapse leaves on a video track contributes its nested-sequence audio to
  offline mixes and mixer meters — previously that audio rendered as silence — where a video
  track only joins the contributor/solo set when its compound actually resolves to audio
  content, so soloing a visual-only compound never mutes real audio tracks; covered by
  full-chain, round-trip, mute/solo, meter-agreement, and golden-audio tests plus a
  golden-audio manifest `kind: "video"` track option to exercise video-track compounds.
- Added FR-SPD-002 speed ramping via keyframed time-remap curves: a validated, monotonic
  non-decreasing `timeRemap` keyframe list on clips with exact rational piecewise-linear
  evaluation (a two-keyframe curve reduces exactly to constant speed), typed rejection when
  combined with `reverse`/`freezeFrame`/non-unit `speed` or when the curve leaves the clip's
  source bounds or timeline domain (half-open: only the final keyframe may touch the exclusive
  source end, so active offsets never read past the last media quantum), render/audio/compound
  mapping through the curve, cache-key invalidation on keyframe edits, legacy-safe codec
  coverage, and discriminating golden frame/audio ramp and within-clip freeze fixtures
  calibrated ~2x above the measured cross-machine decode noise floor.
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
