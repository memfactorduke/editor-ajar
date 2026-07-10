// SPDX-License-Identifier: GPL-3.0-or-later

/// One benchmark metric emitted by the report-only harness.
public enum BenchmarkMetric: String, CaseIterable, Sendable {
    /// Build graph, decode source, execute render, and wait until the frame is present-ready.
    case singleFrameRenderSeekLatency = "single-frame-render-seek-latency"

    /// Load and decode the `.ajar` project package.
    case projectOpenDecodeLoad = "project-open-decode-load"

    /// In-process CLI startup proxy until app signposts are wired.
    case coldStartProxy = "cold-start-proxy"

    /// Render a transformed four-layer frame as a report-only proxy for timeline playback.
    case multiLayerTransformPlayback = "multi-layer-transform-playback"

    /// Render a 4K30 two-layer frame with chroma key and choke enabled.
    case twoLayerChromaKeyChoke4K30Playback = "two-layer-chroma-key-choke-4k30-playback"

    /// Compute FR-COL-003 scopes for one display-encoded frame.
    case scopeAnalyzerCompute = "scope-analyzer-compute"

    /// Warm a fresh executor's RAM tier from a persisted disk cache entry and serve the frame.
    case diskCacheWarmStartPlayback = "disk-cache-warm-start-playback"

    /// Render one frame of a constant 2x fast-motion clip (FR-SPD-005).
    case retimedConstant2xPlayback = "retimed-constant-2x-playback-fr-spd-005"

    /// Render one frame of a constant 1/2x slow-motion clip (FR-SPD-005).
    case retimedConstantHalfPlayback = "retimed-constant-half-speed-playback-fr-spd-005"

    /// Render one frame inside the 4x segment of a 1x-to-4x time-remap ramp (FR-SPD-005).
    case retimedTimeRemapRampPlayback = "retimed-time-remap-ramp-playback-fr-spd-005"

    /// Render one frame of a reversed clip (FR-SPD-005).
    case retimedReversePlayback = "retimed-reverse-playback-fr-spd-005"

    /// Render one frame of a freeze-frame clip (FR-SPD-005).
    case retimedFreezeFramePlayback = "retimed-freeze-frame-playback-fr-spd-005"

    /// Render one frame-blended fractional position of a 1/2x slow-motion clip (FR-SPD-005).
    case retimedFrameBlendHalfPlayback = "retimed-frame-blend-half-speed-playback-fr-spd-005"

    /// Render one frame of a nested compound whose inner sequences are retimed (FR-SPD-005).
    case retimedNestedCompoundPlayback = "retimed-nested-compound-playback-fr-spd-005"

    /// Build the realtime audio look-ahead plan for a retimed timeline with a WSOLA
    /// pitch-corrected clip (FR-SPD-005).
    case realtimeAudioPlanBuildRetimed = "rt-audio-plan-build-retimed-fr-spd-005"

    /// Build the realtime audio look-ahead plan for a depth-five nested compound timeline
    /// (FR-AUD-007, the issue #146 refill-pressure evidence).
    case realtimeAudioPlanBuildNestedCompound = "rt-audio-plan-build-nested-compound-fr-aud-007"

    /// Build the realtime audio look-ahead plan for a wide sixteen-track timeline (FR-AUD-007).
    case realtimeAudioPlanBuildWideTimeline = "rt-audio-plan-build-wide-timeline-fr-aud-007"

    /// Per-node GPU cost of one 1080p Gaussian blur stack node (FR-FX-002, PERFORMANCE §3).
    case effectNodeGaussianBlur1080p = "effect-node-gaussian-blur-1080p-fr-fx-002"

    /// Per-node GPU cost of one 1080p box blur stack node (FR-FX-002, PERFORMANCE §3).
    case effectNodeBoxBlur1080p = "effect-node-box-blur-1080p-fr-fx-002"

    /// Per-node GPU cost of one 1080p zoom blur stack node (FR-FX-002, PERFORMANCE §3).
    case effectNodeZoomBlur1080p = "effect-node-zoom-blur-1080p-fr-fx-002"

    /// Per-node GPU cost of one 1080p sharpen stack node (FR-FX-002, PERFORMANCE §3).
    case effectNodeSharpen1080p = "effect-node-sharpen-1080p-fr-fx-002"

    /// Per-node GPU cost of one 1080p glow stack node (FR-FX-002, PERFORMANCE §3).
    case effectNodeGlow1080p = "effect-node-glow-1080p-fr-fx-002"

    /// Per-node GPU cost for one FR-COL-004 `lut` effect stack node at 1080p30
    /// (PERFORMANCE §3 / ADR-0016 §4). Metric slug includes the kind raw value `lut`.
    case effectNodeLUTGPU = "effect-node-lut-gpu-fr-col-004"

    /// Per-node GPU cost of one 1080p vignette stack node (FR-FX-002, PERFORMANCE §3).
    case effectNodeVignette1080p = "effect-node-vignette-1080p-fr-fx-002"

    /// Per-node GPU cost of one 1080p mirror stack node (FR-FX-002, PERFORMANCE §3).
    case effectNodeMirror1080p = "effect-node-mirror-1080p-fr-fx-002"

    /// Per-node GPU cost of one 1080p mosaic stack node (FR-FX-002, PERFORMANCE §3).
    case effectNodeMosaic1080p = "effect-node-mosaic-1080p-fr-fx-002"

    /// Per-node GPU cost of one 1080p color-adjust stack node (FR-FX-002, PERFORMANCE §3).
    case effectNodeColorAdjust1080p = "effect-node-color-adjust-1080p-fr-fx-002"

    /// Per-node GPU cost of one 1080p posterize stack node (FR-FX-002, PERFORMANCE §3).
    case effectNodePosterize1080p = "effect-node-posterize-1080p-fr-fx-002"

    /// Per-node GPU cost of one 1080p invert stack node (FR-FX-002, PERFORMANCE §3).
    case effectNodeInvert1080p = "effect-node-invert-1080p-fr-fx-002"

    /// Per-kind-family GPU cost for FR-FX-001 crossDissolve at 1080p (PERFORMANCE §3).
    case transitionCrossDissolve1080p = "transition-cross-dissolve-1080p-fr-fx-001"

    /// Per-kind-family GPU cost for FR-FX-001 dip/fade family at 1080p.
    case transitionDipFade1080p = "transition-dip-fade-1080p-fr-fx-001"

    /// Per-kind-family GPU cost for FR-FX-001 push/slide family at 1080p.
    case transitionPushSlide1080p = "transition-push-slide-1080p-fr-fx-001"

    /// Per-kind-family GPU cost for FR-FX-001 wipe family at 1080p.
    case transitionWipe1080p = "transition-wipe-1080p-fr-fx-001"

    /// Per-kind-family GPU cost for FR-FX-001 zoom at 1080p.
    case transitionZoom1080p = "transition-zoom-1080p-fr-fx-001"

    var requirementID: String {
        switch self {
        case .singleFrameRenderSeekLatency:
            "NFR-PERF-005"
        case .projectOpenDecodeLoad:
            "NFR-PERF-002"
        case .coldStartProxy:
            "NFR-PERF-001"
        case .multiLayerTransformPlayback:
            "NFR-PERF-003"
        case .twoLayerChromaKeyChoke4K30Playback:
            "NFR-PERF-004"
        case .scopeAnalyzerCompute:
            "FR-COL-003"
        case .diskCacheWarmStartPlayback:
            "FR-PLAY-005"
        case .retimedConstant2xPlayback, .retimedConstantHalfPlayback,
            .retimedTimeRemapRampPlayback, .retimedReversePlayback,
            .retimedFreezeFramePlayback, .retimedFrameBlendHalfPlayback,
            .retimedNestedCompoundPlayback, .realtimeAudioPlanBuildRetimed:
            "FR-SPD-005"
        case .realtimeAudioPlanBuildNestedCompound, .realtimeAudioPlanBuildWideTimeline:
            "FR-AUD-007"
        case .effectNodeGaussianBlur1080p, .effectNodeBoxBlur1080p,
            .effectNodeZoomBlur1080p, .effectNodeSharpen1080p, .effectNodeGlow1080p,
            .effectNodeVignette1080p, .effectNodeMirror1080p, .effectNodeMosaic1080p,
            .effectNodeColorAdjust1080p, .effectNodePosterize1080p, .effectNodeInvert1080p:
            "FR-FX-002"
        case .effectNodeLUTGPU:
            "FR-COL-004"
        case .transitionCrossDissolve1080p, .transitionDipFade1080p,
            .transitionPushSlide1080p, .transitionWipe1080p, .transitionZoom1080p:
            "FR-FX-001"
        }
    }

    /// The docs/PERFORMANCE.md budget carried by this metric, or `nil` for metrics defined
    /// before budgets were attached. Carrying the budget in the definition makes flipping the
    /// report-only CI job into a regression gate mechanical (PERFORMANCE Section 4).
    var budget: BenchmarkBudget? {
        switch self {
        case .retimedConstant2xPlayback, .retimedConstantHalfPlayback,
            .retimedTimeRemapRampPlayback, .retimedReversePlayback,
            .retimedFreezeFramePlayback, .retimedFrameBlendHalfPlayback,
            .retimedNestedCompoundPlayback:
            .playbackFrameAt30fps
        case .realtimeAudioPlanBuildRetimed, .realtimeAudioPlanBuildNestedCompound,
            .realtimeAudioPlanBuildWideTimeline:
            .realtimeAudioLookAheadRefill
        case .effectNodeGaussianBlur1080p:
            // Two-pass separable Gaussian at 1080p. Budget leaves headroom on M1 Pro so a
            // 4-layer + 2-fx timeline stays inside the ~33 ms 30 fps frame (PERFORMANCE §3).
            // Representative cost class: ~1–2 ms on M-series; 4 ms target with 5% noise band.
            .effectNodeGPU(targetMilliseconds: 4)
        case .effectNodeBoxBlur1080p:
            // Separable box blur (up to 33 taps/pass) — slightly heavier than Gaussian 9-tap.
            .effectNodeGPU(targetMilliseconds: 4)
        case .effectNodeZoomBlur1080p:
            // Single-pass 12-tap radial sample; cheaper than separable blur on 1080p.
            .effectNodeGPU(targetMilliseconds: 3)
        case .effectNodeSharpen1080p:
            // 5-tap neighborhood; very light at 1080p.
            .effectNodeGPU(targetMilliseconds: 2)
        case .effectNodeGlow1080p:
            // Gaussian two-pass + combine; heaviest of the FR-FX-002 batch-1 set.
            .effectNodeGPU(targetMilliseconds: 6)
        case .effectNodeLUTGPU:
            // Differential cost of one 33³ LUT node at 1080p30 (see BenchmarkBudget.effectNodeLUT).
            .effectNodeLUT
        case .effectNodeVignette1080p:
            // One sample plus aspect-corrected falloff and premultiply-safe RGB scaling.
            .effectNodeGPU(targetMilliseconds: 2)
        case .effectNodeMirror1080p:
            // One sample with only a coordinate fold; same conservative class as sharpen.
            .effectNodeGPU(targetMilliseconds: 2)
        case .effectNodeMosaic1080p:
            // One nearest sample after source-pixel cell-center quantization.
            .effectNodeGPU(targetMilliseconds: 2)
        case .effectNodeColorAdjust1080p:
            // One sample plus straight-linear RGB grading and repremultiplication.
            .effectNodeGPU(targetMilliseconds: 2)
        case .effectNodePosterize1080p:
            // One sample plus three-channel quantization in straight linear RGB.
            .effectNodeGPU(targetMilliseconds: 2)
        case .effectNodeInvert1080p:
            // One sample plus straight-linear RGB inversion and repremultiplication.
            .effectNodeGPU(targetMilliseconds: 2)
        case .transitionCrossDissolve1080p, .transitionDipFade1080p,
            .transitionPushSlide1080p, .transitionWipe1080p, .transitionZoom1080p:
            // Two-input full-frame transition at 1080p; headroom under 30 fps frame budget.
            .effectNodeGPU(targetMilliseconds: 3)
        default:
            nil
        }
    }
}

/// Budget metadata attached to a benchmark metric definition (docs/PERFORMANCE.md Section 4).
public struct BenchmarkBudget: Equatable, Sendable {
    /// Target median value in milliseconds on the reference machine.
    public let targetMilliseconds: Double

    /// Regression noise band in percent (the PERFORMANCE Section 4 default is five percent).
    public let noiseBandPercent: Double

    /// Creates budget metadata for one metric.
    public init(targetMilliseconds: Double, noiseBandPercent: Double) {
        self.targetMilliseconds = targetMilliseconds
        self.noiseBandPercent = noiseBandPercent
    }

    /// The largest value that still passes: the target widened by the noise band.
    public var allowedMilliseconds: Double {
        targetMilliseconds * (1.0 + noiseBandPercent / 100.0)
    }

    /// FR-SPD-005 playback budget: real-time at the timeline target rate. The retime fixtures
    /// run 30 fps timelines, so one frame must be render-complete within 1000/30 ms
    /// (PERFORMANCE Section 3, NFR-PERF-003).
    static let playbackFrameAt30fps = BenchmarkBudget(
        targetMilliseconds: 1_000.0 / 30.0,
        noiseBandPercent: 5
    )

    /// Realtime audio look-ahead refill budget. `EditorAjarLiveAudioCoordinator` publishes a
    /// two-second window and triggers a refill once one second of published audio remains, so
    /// the replacement plan must finish building within that one-second margin (FR-AUD-007).
    static let realtimeAudioLookAheadRefill = BenchmarkBudget(
        targetMilliseconds: 1_000,
        noiseBandPercent: 5
    )

    /// Per-node GPU cost budget for one FR-FX library effect at 1080p on the reference machine
    /// class (PERFORMANCE §3 / ADR-0016 §4). Noise band matches the suite default (5%).
    static func effectNodeGPU(targetMilliseconds: Double) -> BenchmarkBudget {
        BenchmarkBudget(targetMilliseconds: targetMilliseconds, noiseBandPercent: 5)
    }

    /// Per-node GPU budget for the FR-COL-004 `lut` stack kind (PERFORMANCE §3).
    ///
    /// Differential cost: median 1080p with one 33³ LUT minus no-LUT baseline (graphs
    /// prebuilt, texture cache warm). 1.5 ms M1 Pro ceiling with 5% noise.
    static let effectNodeLUT = BenchmarkBudget(
        targetMilliseconds: 1.5,
        noiseBandPercent: 5
    )
}

extension BenchmarkMetric {
    /// Whether this metric synthesizes its own GPU fixture and needs no `.ajar` package.
    var isSelfContainedEffectNodeMetric: Bool {
        switch self {
        case .effectNodeGaussianBlur1080p, .effectNodeBoxBlur1080p,
            .effectNodeZoomBlur1080p, .effectNodeSharpen1080p, .effectNodeGlow1080p,
            .effectNodeLUTGPU,
            .effectNodeVignette1080p, .effectNodeMirror1080p, .effectNodeMosaic1080p,
            .effectNodeColorAdjust1080p, .effectNodePosterize1080p, .effectNodeInvert1080p,
            .transitionCrossDissolve1080p, .transitionDipFade1080p,
            .transitionPushSlide1080p, .transitionWipe1080p, .transitionZoom1080p:
            true
        default:
            false
        }
    }
}

/// Structured JSON benchmark result.
public struct BenchmarkResult: Codable, Equatable, Sendable {
    /// Stable metric slug.
    public let metric: String

    /// Median measured value.
    public let value: Double

    /// Unit for `value`.
    public let unit: String

    /// SPEC requirement this metric covers.
    public let requirementID: String

    /// Budget target in milliseconds, when the metric definition carries one.
    public let budgetMilliseconds: Double?

    /// Regression noise band in percent, when the metric definition carries a budget.
    public let noiseBandPercent: Double?

    /// Whether `value` is within the budget widened by the noise band. `nil` without a budget.
    public let withinBudget: Bool?

    /// Creates a benchmark result row.
    public init(
        metric: String,
        value: Double,
        unit: String,
        requirementID: String,
        budgetMilliseconds: Double? = nil,
        noiseBandPercent: Double? = nil,
        withinBudget: Bool? = nil
    ) {
        self.metric = metric
        self.value = value
        self.unit = unit
        self.requirementID = requirementID
        self.budgetMilliseconds = budgetMilliseconds
        self.noiseBandPercent = noiseBandPercent
        self.withinBudget = withinBudget
    }
}
