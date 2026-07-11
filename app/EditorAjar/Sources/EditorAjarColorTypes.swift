// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Inspector surface shown when a single clip is selected (FR-COL-001 / FR-XFORM / FR-AUD-001).
enum ClipInspectorTab: String, CaseIterable, Identifiable, Sendable {
    case transform
    case color
    case audio

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .transform:
            return AppString.localized("inspector.tab.transform", "Transform")
        case .color:
            return AppString.localized("inspector.tab.color", "Color")
        case .audio:
            return AppString.localized("inspector.tab.audio", "Audio")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .transform:
            return "Inspector Tab Transform"
        case .color:
            return "Inspector Tab Color"
        case .audio:
            return "Inspector Tab Audio"
        }
    }
}

/// Snapshot for the FR-COL-001 color inspector (static base values — no color keyframe UI in v1).
struct SelectedColorInspectorState: Equatable, Sendable {
    let clipName: String
    let correction: ClipColorCorrection
    let lutNodeID: UUID?
    let lutStrength: RationalValue
    let lutTitle: String?
    let hasLUT: Bool
}

/// Scalar FR-COL-001 controls shown as keyboard-operable sliders.
enum ColorInspectorScalarField: String, CaseIterable, Identifiable, Sendable {
    case exposure
    case contrast
    case saturation
    case temperature
    case tint
    case vibrance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exposure: return "Exposure"
        case .contrast: return "Contrast"
        case .saturation: return "Saturation"
        case .temperature: return "Temperature"
        case .tint: return "Tint"
        case .vibrance: return "Vibrance"
        }
    }

    var localizedTitle: String {
        switch self {
        case .exposure:
            return AppString.localized("color.field.exposure", "Exposure")
        case .contrast:
            return AppString.localized("color.field.contrast", "Contrast")
        case .saturation:
            return AppString.localized("color.field.saturation", "Saturation")
        case .temperature:
            return AppString.localized("color.field.temperature", "Temperature")
        case .tint:
            return AppString.localized("color.field.tint", "Tint")
        case .vibrance:
            return AppString.localized("color.field.vibrance", "Vibrance")
        }
    }

    var accessibilityIdentifier: String {
        "Color \(title)"
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure:
            return -10...10
        case .contrast, .saturation:
            return 0...4
        case .temperature, .tint, .vibrance:
            return -1...1
        }
    }

    var identity: RationalValue {
        switch self {
        case .exposure, .temperature, .tint, .vibrance:
            return .zero
        case .contrast, .saturation:
            return .one
        }
    }

    func value(in correction: ClipColorCorrection) -> RationalValue {
        switch self {
        case .exposure: return correction.exposure
        case .contrast: return correction.contrast
        case .saturation: return correction.saturation
        case .temperature: return correction.temperature
        case .tint: return correction.tint
        case .vibrance: return correction.vibrance
        }
    }
}

/// Per-channel lift/gamma/gain fields (RGB triplets as compact slider rows).
enum ColorInspectorChannelGroup: String, CaseIterable, Identifiable, Sendable {
    case lift
    case gamma
    case gain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lift: return "Lift"
        case .gamma: return "Gamma"
        case .gain: return "Gain"
        }
    }

    var localizedTitle: String {
        switch self {
        case .lift:
            return AppString.localized("color.group.lift", "Lift")
        case .gamma:
            return AppString.localized("color.group.gamma", "Gamma")
        case .gain:
            return AppString.localized("color.group.gain", "Gain")
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .lift:
            return -1...1
        case .gamma:
            return 0.01...4
        case .gain:
            return 0...4
        }
    }

    var identity: ClipColorChannels {
        switch self {
        case .lift:
            return .zero
        case .gamma, .gain:
            return .one
        }
    }

    func channels(in correction: ClipColorCorrection) -> ClipColorChannels {
        switch self {
        case .lift: return correction.lift
        case .gamma: return correction.gamma
        case .gain: return correction.gain
        }
    }
}

enum ColorInspectorChannelComponent: String, CaseIterable, Identifiable, Sendable {
    case red
    case green
    case blue

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .red:
            return AppString.localized("color.channel.red", "R")
        case .green:
            return AppString.localized("color.channel.green", "G")
        case .blue:
            return AppString.localized("color.channel.blue", "B")
        }
    }

    func value(in channels: ClipColorChannels) -> RationalValue {
        switch self {
        case .red: return channels.red
        case .green: return channels.green
        case .blue: return channels.blue
        }
    }
}

/// Builds/replaces primary color-correction values for the inspector.
enum ColorCorrectionEditor {
    static func copying(
        _ correction: ClipColorCorrection,
        lift: ClipColorChannels? = nil,
        gamma: ClipColorChannels? = nil,
        gain: ClipColorChannels? = nil,
        exposure: RationalValue? = nil,
        contrast: RationalValue? = nil,
        saturation: RationalValue? = nil,
        temperature: RationalValue? = nil,
        tint: RationalValue? = nil,
        vibrance: RationalValue? = nil
    ) -> ClipColorCorrection {
        ClipColorCorrection(
            lift: lift ?? correction.lift,
            gamma: gamma ?? correction.gamma,
            gain: gain ?? correction.gain,
            exposure: exposure ?? correction.exposure,
            contrast: contrast ?? correction.contrast,
            saturation: saturation ?? correction.saturation,
            temperature: temperature ?? correction.temperature,
            tint: tint ?? correction.tint,
            vibrance: vibrance ?? correction.vibrance
        )
    }

    static func resetting(
        _ field: ColorInspectorScalarField,
        in correction: ClipColorCorrection
    ) -> ClipColorCorrection {
        switch field {
        case .exposure:
            return copying(correction, exposure: field.identity)
        case .contrast:
            return copying(correction, contrast: field.identity)
        case .saturation:
            return copying(correction, saturation: field.identity)
        case .temperature:
            return copying(correction, temperature: field.identity)
        case .tint:
            return copying(correction, tint: field.identity)
        case .vibrance:
            return copying(correction, vibrance: field.identity)
        }
    }

    static func resetting(
        _ group: ColorInspectorChannelGroup,
        in correction: ClipColorCorrection
    ) -> ClipColorCorrection {
        switch group {
        case .lift:
            return copying(correction, lift: group.identity)
        case .gamma:
            return copying(correction, gamma: group.identity)
        case .gain:
            return copying(correction, gain: group.identity)
        }
    }

    static func setting(
        _ field: ColorInspectorScalarField,
        to value: RationalValue,
        in correction: ClipColorCorrection
    ) -> ClipColorCorrection {
        switch field {
        case .exposure:
            return copying(correction, exposure: value)
        case .contrast:
            return copying(correction, contrast: value)
        case .saturation:
            return copying(correction, saturation: value)
        case .temperature:
            return copying(correction, temperature: value)
        case .tint:
            return copying(correction, tint: value)
        case .vibrance:
            return copying(correction, vibrance: value)
        }
    }

    static func setting(
        group: ColorInspectorChannelGroup,
        component: ColorInspectorChannelComponent,
        to value: RationalValue,
        in correction: ClipColorCorrection
    ) -> ClipColorCorrection {
        let current = group.channels(in: correction)
        let channels: ClipColorChannels
        switch component {
        case .red:
            channels = ClipColorChannels(red: value, green: current.green, blue: current.blue)
        case .green:
            channels = ClipColorChannels(red: current.red, green: value, blue: current.blue)
        case .blue:
            channels = ClipColorChannels(red: current.red, green: current.green, blue: value)
        }
        switch group {
        case .lift:
            return copying(correction, lift: channels)
        case .gamma:
            return copying(correction, gamma: channels)
        case .gain:
            return copying(correction, gain: channels)
        }
    }
}

enum ColorFieldValueMapper {
    static func string(from value: RationalValue) -> String {
        let number = value.doubleValue
        if abs(number.rounded() - number) < 0.000_001 {
            return "\(Int64(number.rounded()))"
        }
        return String(format: "%.2f", number)
    }

    static func rational(from rawValue: String) -> RationalValue? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else {
            return nil
        }
        return RationalValue.approximating(value)
    }

    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Typed LUT import refusals (FR-COL-004). Non-blocking; never crash the session.
enum EditorAjarLUTImportError: Error, Equatable, Sendable {
    case noProject
    case projectReadOnly
    case noVideoClipSelected
    /// Source path missing / unreadable — same posture as offline media (typed, non-blocking).
    case sourceUnavailable
    case parseFailed(String)
    case applyFailed(String)
}

/// FR-COL-003 scope display kinds.
enum ScopeDisplayKind: String, CaseIterable, Identifiable, Sendable {
    case waveform
    case vectorscope
    case parade
    case histogram

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .waveform:
            return AppString.localized("scopes.kind.waveform", "Waveform")
        case .vectorscope:
            return AppString.localized("scopes.kind.vectorscope", "Vectorscope")
        case .parade:
            return AppString.localized("scopes.kind.parade", "RGB Parade")
        case .histogram:
            return AppString.localized("scopes.kind.histogram", "Histogram")
        }
    }

    var accessibilityIdentifier: String {
        "Scope Kind \(rawValue.capitalized)"
    }
}

/// Model-level FR-COL-003 analysis budget — scopes stay off the playback hot path.
///
/// - **Paused:** on texture-identity change (scrub settle / first frame), still capped at
///   ``maxAnalysesPerSecondWhilePlaying`` so rapid scrubbing cannot run unbounded GPU scope passes.
/// - **Playing:** at most ``maxAnalysesPerSecondWhilePlaying`` analyses per second.
///
/// Analysis schedules a separate Metal command buffer and never waits on GPU completion on the
/// render present path (`MetalScopeAnalyzer` contract).
enum ScopeAnalysisThrottle {
    /// Playback / scrub budget: 10 analyses/sec keeps scopes useful without competing with present.
    static let maxAnalysesPerSecondWhilePlaying = 10

    /// Minimum interval between analyses (playing and paused scrub-path).
    static var minimumPlayingInterval: TimeInterval {
        1.0 / Double(maxAnalysesPerSecondWhilePlaying)
    }

    /// Whether a new analysis may start for the current transport/texture state.
    static func shouldAnalyze(
        isPlaying: Bool,
        textureIdentityChanged: Bool,
        lastAnalysisTime: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        if !isPlaying {
            // On-demand when the displayed texture changes (or first analysis), but enforce the
            // same minimum interval so scrub settles cannot unbounded-analyze on the interactive path.
            guard textureIdentityChanged || lastAnalysisTime == nil else {
                return false
            }
            return hasMinimumIntervalElapsed(since: lastAnalysisTime, now: now)
        }
        return hasMinimumIntervalElapsed(since: lastAnalysisTime, now: now)
    }

    /// Shared rate gate for playing and paused paths.
    ///
    /// Compares against `last + interval` (not `now - last`) so the exact boundary
    /// `now == last + interval` is not lost to floating-point cancellation — which would
    /// incorrectly reject a legal N-per-second analysis at the rate limit edge.
    private static func hasMinimumIntervalElapsed(
        since lastAnalysisTime: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard let lastAnalysisTime else {
            return true
        }
        return now >= lastAnalysisTime + minimumPlayingInterval
    }
}
