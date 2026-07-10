# ADR-0019: Export pipeline architecture

- **Status:** Accepted
- **Date:** 2026-07-10
- **Deciders:** Mem
- **Tags:** export, rendering, audio, color, concurrency, stability

## Context

FR-EXP-001/002 require H.264, HEVC (8/10-bit), and ProRes delivery in MP4/MOV with AAC/PCM,
configurable rate/quality/raster/timing, and correct color tags. FR-EXP-005 will later run exports
in a background queue and cancel them. FR-EXP-007 and ADR-0009 require the pixels to come from the
same deterministic render graph as preview, using originals rather than proxies. ADR-0010 requires
linear-light compositing followed by an explicit delivery conversion and matching output tags.

Export crosses several existing responsibilities. `AjarCore` owns exact time and graph
descriptions, `AjarRender` owns GPU execution, and `AjarAudio` owns the deterministic offline mix.
`AjarMedia` owns source probing/decoding, proxy generation, and the FFmpeg import boundary. Putting
the whole writer in any one of those modules would either couple unrelated layers or pull platform
frameworks into the pure core.

A failed export must not look complete. Disk-full, hardware-encoder refusal, writer failure, and
cancellation can occur after a container file has been created, so the boundary needs a transaction
and a typed lifecycle rather than direct writes to the user's destination.

## Decision

### Module and framework boundary

We add a macOS `AjarExport` module. It depends on `AjarCore`, `AjarRender`, and `AjarAudio` and owns
AVFoundation, VideoToolbox, Core Video, and export-only Accelerate/vImage delivery conversion.
`AjarCore` remains pure.

`AjarExport` does not depend on `AjarMedia`. Instead, it accepts an injected source-texture provider
whose contract requires original-media frames. The app or CLI may adapt `AjarMedia` decoding to that
contract. This keeps source selection, import normalization, and proxy policy in `AjarMedia` while
avoiding a new upward dependency from media I/O into rendering and audio orchestration.

The encoder/muxer APIs introduced here are an **offline export boundary only**. Playback never calls
`AjarExport`; it keeps its existing decode → render → present path. FFmpeg remains restricted to the
ADR-0003 import/transcode boundary and is never an export or playback encoder.

### Deterministic video pull

One `ExportSession` captures an immutable project snapshot, sequence, range, and validated settings.
For zero-based frame index `i`, it computes the exact timeline time as:

`range.start + exportFrameRate.duration(ofFrames: i)`

The frame count is `range.duration` converted at the export frame rate with rounding upward. The
session builds and executes exactly one immutable render graph at each time, awaits GPU completion,
CPU-readbacks the presented half-float result, then uses a single Accelerate/**vImage** conversion
layer to scale the captured project canvas to the delivery raster and pack writer-owned pixel
buffers (`32BGRA` for H.264/HEVC 8-bit, `64ARGB` big-endian 16-bit samples for ProRes, and
`420YpCbCr10BiPlanarVideoRange` for HEVC 10-bit). Core Image is not used: GPU CI rendering is not
bit-stable across devices and cannot target ordinary-memory `64ARGB` on all hardware. Appends use
the matching rational presentation timestamp, and only then does the session advance to the next
index. Graph frames are never requested concurrently or from wall-clock time. VideoToolbox may
perform its normal internal codec reordering, but input graph evaluation and delivery conversion
stay sequential and CPU-deterministic.

The source provider prepares each graph from original media. Proxy selection is outside the export
module and does not satisfy this contract (FR-EXP-007).

### Proxy exclusion audit hook (FR-EXP-007 / FR-MED-004)

`ExportSession` records per-frame `ExportFrameSourceSelection` rows while writing. Production
`RenderGraphExportFrameProvider` builds graphs with `proxyFileExists {_ in false}` and exposes
executed source-node tiers via `ExportGraphSourceAuditing`; the session prefers those observed
tiers (falling back to `ExportSourceSelectionPolicy.alwaysOriginal` for stub providers). Golden-
export and unit tests assert every recorded tier is `.original`.

This is intentionally an **audit / assertion surface**, not a second media stack: source decode
remains injected via `ExportRenderSourceProvider`. Playback may select proxy files (FR-MED-004 /
#217), but export graphs stay structurally original-only even when `preferProxyPlayback` is on.
The session does not import `AjarMedia` and does not open proxy URLs itself.

### Codecs, containers, and pixel formats

`AVAssetWriter` muxes MP4 and MOV. H.264 and HEVC output settings require
`kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder`; there is no silent software
fallback. HEVC 8-bit selects Main, and HEVC 10-bit selects Main 10 and receives 10-bit bi-planar
video-range `x420` pixel buffers. ProRes 422, 422 HQ, and 4444 use their native profiles in MOV and
receive AVAssetWriter's documented 16-bit-per-component ARGB input (`kCVPixelFormatType_64ARGB`),
converted by vImage from the graph's half-float result without an eight-bit intermediate; 4444
keeps alpha. MP4 rejects ProRes. Typed
settings carry codec, container, average bit rate, normalized quality, frame rate, resolution, and
delivery color, and reject unsupported combinations before a writer starts.

AAC and interleaved 32-bit floating-point linear PCM are supported. PCM is MOV-only. Floating-point
PCM preserves the offline mixer's above-unity headroom rather than applying an implicit integer
quantizer or limiter; AAC performs its codec-defined conversion.

### Color conversion and tags

The executor renders `.presented` output, not `.linearWorking`. The render graph therefore performs
effects and compositing in its half-float linear working space, then applies the project's explicit
delivery primaries and transfer function once. v1 export accepts tagged Rec.709 and Display-P3 SDR
delivery spaces; full HDR mastering remains v1.x per ADR-0010.

After that single present pass, **delivery pixel packing is CPU-side vImage** (not a second GPU
color transform): half-float RGBA → host ARGB16U, optional high-quality scale, then format-specific
packing (BGRA8, big-endian ARGB16, or BT.709 video-range 10-bit bi-planar Y′CbCr). That path is the
determinism boundary for FR-EXP-007 encoder input; encoded bitstream bytes may still vary by
VideoToolbox hardware/OS.

The settings' delivery space must equal the captured graph output space. `AjarExport` writes the
matching primaries, transfer function, and YCbCr matrix in `AVVideoColorPropertiesKey` for
H.264/HEVC and on every encoder pixel buffer. High-bit-depth ProRes omits the output-settings color
dictionary as required by AVAssetWriter and propagates the pixel-buffer tags instead. A mismatched
graph/output tag is a typed error rather than mislabeled media.

### Export golden and determinism gate (FR-EXP-007)

The `ajar golden-export` harness (and `AjarExportTests` determinism cases) export a small fixture
through the real `ExportSession`, decode the container, and compare **decoded** BGRA frames to the
live render-path delivery expectation with codec-banded tolerances:

- **ProRes 422:** near-lossless band (must run on CI).
- **H.264 / HEVC:** lossy band; capability-gated skip via
  `ExportError.isHardwareEncoderUnavailable` (VT statuses -12902…-12906 wrapping pattern).
- **Still PNG:** bit-exact vs delivery BGRA (FR-EXP-004 path).

Determinism hashes **decoded** pixel buffers (and PCM when present), never container bytes —
encoder timestamps may differ across runs. See `ExportGoldenComparison.swift` for the exact bands.

### Offline audio and interleaving

When audio is enabled, the session calls `OfflineAudioMixer` once for the captured project,
sequence, and range at the project sample rate. Audio frame zero represents `range.start` but is
appended at output presentation time zero. The returned interleaved Float32 master mix is packaged
in bounded sample-buffer chunks and interleaved with sequential video appends according to writer
backpressure. This is the non-real-time mixer; the live audio callback is never used or blocked.

### Lifecycle, cancellation, and atomic publication

`ExportSession` is one-shot and exposes `ready → preparing → writing → finishing → completed`, with
`cancelling`, `cancelled`, and `failed` terminal paths for the future FR-EXP-005 queue. Cancellation
is checked before and after audio preparation, between frames/sample chunks, after GPU awaits,
during writer backpressure, and before atomic publication. A later queue owns scheduling, progress,
pause policy, and session cancellation; this ADR defines the engine lifecycle it drives.

The writer always targets a hidden unique temporary file in the destination directory. Only a fully
finished container is renamed/replaced onto the requested URL. Cancellation or any error cancels the
writer and removes only that temporary file; an existing destination is preserved. Disk-full,
encoder refusal, invalid settings/range/color, render/mix failures, append/finalize failures, and
cleanup failure are surfaced as typed `ExportError` values. A failure to remove a partial is itself
reported rather than concealed.

Before finalization, the writer session is explicitly ended at the request's exact rational
duration. This trims a rounded-up final video frame or audio packet at the container timeline
boundary instead of allowing the last sample's inferred end to change the requested duration.

## Consequences

- Playback performance and behavior are unchanged; export work is isolated and serializable behind
  a queue-owned session.
- The same graph and offline mixer feed preview/test/export, so effects, titles, retiming, nesting,
  and audio automation do not acquire a second AV composition implementation.
- H.264/HEVC fail clearly on machines or sandboxes without a compatible free hardware encoder.
- Exact frame times, immutable snapshots, and vImage delivery packing make repeated encoder *input*
  pulls deterministic, while encoded bytes may still vary across VideoToolbox hardware/OS versions.
- Same-directory transactional output prevents a cancelled or failed movie from replacing a good
  destination. Cleanup failure remains visible because no API can truthfully guarantee deletion
  after the file system itself refuses it.
- Source decode remains injected. The app/CLI adapter and the FR-EXP-005 queue are follow-up work,
  not reasons to couple this engine to `AjarMedia` or UI targets now.
- The current offline mixer returns the complete range synchronously. Cancellation is observed
  immediately before/after that call, but interrupting a very long mix mid-call requires a future
  chunk-aware `AjarAudio` API.

## Alternatives considered

- **Put export in `AjarMedia`.** Rejected: it would make the media import/decode layer orchestrate
  render graphs, audio mixing, queue lifecycle, and atomic destination transactions.
- **Put settings/session logic in `AjarCore`.** Rejected: writer and pixel-buffer types are Apple
  platform APIs; duplicating platform-neutral descriptors in Core is unnecessary for this slice and
  risks the strict purity invariant.
- **Use `AVVideoComposition` as the renderer.** Rejected by ADR-0009: it cannot reproduce the custom
  Metal effects/key/mask/color graph with the same cache identity and precision.
- **Parallel frame pulls.** Rejected for the first engine: they increase decoder/GPU memory pressure
  and complicate deterministic cancellation/order. The hardware encoder may parallelize internally.
- **Write directly to the destination.** Rejected: AVAssetWriter creates a partial container before
  finalization, making cancellation, disk-full, and encoder failure look like usable output.
- **Allow software H.264/HEVC fallback.** Rejected: FR-EXP-001 and NFR-PERF-008 explicitly require
  the hardware path; silent fallback would violate both behavior and performance expectations.

## References

- SPEC §6.13 (FR-EXP-001/002/005/007), §5 (NFR-PERF-008, NFR-STAB).
- [ADR-0003](0003-media-engine.md), [ADR-0005](0005-core-ui-separation.md),
  [ADR-0009](0009-render-graph-and-caching.md), [ADR-0010](0010-color-management.md),
  [ADR-0012](0012-concurrency-and-threading.md).
- [ARCHITECTURE §2, §4, §6–7](../ARCHITECTURE.md).
