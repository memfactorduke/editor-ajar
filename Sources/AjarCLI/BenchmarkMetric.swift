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
