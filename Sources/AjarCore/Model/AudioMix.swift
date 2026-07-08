// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Document-level limits for stored audio gain and pan automation.
public enum AudioMixLimits {
    /// Linear gain floor used for silence.
    public static let minimumGain = RationalValue.zero

    /// Linear gain ceiling used by the headless model until a later mixer defines metering policy.
    public static let maximumGain = RationalValue(4)

    /// Hard-left pan value.
    public static let minimumPan = RationalValue(-1)

    /// Hard-right pan value.
    public static let maximumPan = RationalValue.one
}

/// Fade/crossfade timing curve stored in the project model.
public enum ClipAudioFadeCurve: String, Codable, Equatable, Sendable {
    /// Straight-line fade.
    case linear

    /// Slow start, fast finish.
    case easeIn

    /// Fast start, slow finish.
    case easeOut

    /// Smooth start and finish.
    case easeInOut

    /// Equal-power crossfade half (`sin(πx/2)`), so a mirrored pair holds
    /// `g_in² + g_out² = 1` for constant perceived loudness on uncorrelated
    /// program (ADR-0015 §4, FR-AUD-002).
    case equalPower

    /// Evaluates the curve's gain multiplier at a clamped `0...1` fraction.
    ///
    /// This is the single source of truth for fade and ADR-0015 §4 crossfade gain math:
    /// a crossfade pair applies `g_in(x) = value(at: x)` on the incoming clip and
    /// `g_out(x) = value(at: 1 - x)` on the outgoing tail (FR-AUD-002).
    public func value(at fraction: Double) -> Double {
        let clampedFraction = max(0, min(1, fraction))
        switch self {
        case .linear:
            return InterpolationMode.linear.timingFraction(for: clampedFraction)
        case .easeIn:
            return InterpolationMode.easeIn.timingFraction(for: clampedFraction)
        case .easeOut:
            return InterpolationMode.easeOut.timingFraction(for: clampedFraction)
        case .easeInOut:
            return InterpolationMode.easeInOut.timingFraction(for: clampedFraction)
        case .equalPower:
            return sin(clampedFraction * Double.pi / 2)
        }
    }
}

/// The edge of a clip that owns an audio fade or crossfade.
public enum ClipAudioFadeEdge: String, Codable, Equatable, Sendable {
    /// Fade at the clip start.
    case fadeIn

    /// Fade at the clip end.
    case fadeOut

    /// Crossfade into this clip from the previous adjacent clip.
    case leadingCrossfade

    /// Crossfade out of this clip into the next adjacent clip.
    case trailingCrossfade
}

/// Per-clip fade settings.
public struct ClipAudioFade: Codable, Equatable, Sendable {
    /// Fade duration in exact timeline time.
    public let duration: RationalTime

    /// Fade curve.
    public let curve: ClipAudioFadeCurve

    /// No fade.
    public static let none = ClipAudioFade(duration: .zero, curve: .linear)

    /// Creates a fade model.
    public init(duration: RationalTime, curve: ClipAudioFadeCurve = .linear) {
        self.duration = duration
        self.curve = curve
    }
}

/// Crossfade metadata connecting one clip edge to an adjacent clip.
public struct ClipAudioCrossfade: Codable, Equatable, Sendable {
    /// Adjacent clip that participates in the crossfade.
    public let partnerClipID: UUID

    /// Crossfade duration in exact timeline time.
    public let duration: RationalTime

    /// Crossfade curve.
    public let curve: ClipAudioFadeCurve

    /// Creates a crossfade model.
    public init(
        partnerClipID: UUID,
        duration: RationalTime,
        curve: ClipAudioFadeCurve = .linear
    ) {
        self.partnerClipID = partnerClipID
        self.duration = duration
        self.curve = curve
    }
}

/// Evaluated keyframable audio values at a single timeline time.
public struct ClipAudioMixValue: Equatable, Sendable {
    /// Linear gain.
    public let gain: RationalValue

    /// Balance pan in the `-1...1` range.
    public let pan: RationalValue

    /// Creates evaluated audio values.
    public init(gain: RationalValue, pan: RationalValue) {
        self.gain = gain
        self.pan = pan
    }
}

/// Per-clip audio automation and fade metadata.
public struct ClipAudioMix: Codable, Equatable, Sendable {
    /// Keyframable linear gain. `1` means unity gain; `0` means silence.
    public let gain: Animatable<RationalValue>

    /// Keyframable balance pan in the `-1...1` range.
    public let pan: Animatable<RationalValue>

    /// Fade from silence at the clip start.
    public let fadeIn: ClipAudioFade

    /// Fade to silence at the clip end.
    public let fadeOut: ClipAudioFade

    /// Crossfade from the previous adjacent clip into this clip.
    public let leadingCrossfade: ClipAudioCrossfade?

    /// Crossfade from this clip into the next adjacent clip.
    public let trailingCrossfade: ClipAudioCrossfade?

    /// How retimed audio treats pitch (FR-SPD-001). `pitchShifted` (varispeed) is the legacy
    /// behavior and the decode default for projects that predate the key.
    public let retimeMode: ClipAudioRetimeMode

    /// Unity gain, centered pan, no fades, and pitch-shifted (varispeed) retiming.
    public static let identity = ClipAudioMix()

    /// Creates a per-clip audio mix.
    public init(
        gain: Animatable<RationalValue> = .constant(.one),
        pan: Animatable<RationalValue> = .constant(.zero),
        fadeIn: ClipAudioFade = .none,
        fadeOut: ClipAudioFade = .none,
        leadingCrossfade: ClipAudioCrossfade? = nil,
        trailingCrossfade: ClipAudioCrossfade? = nil,
        retimeMode: ClipAudioRetimeMode = .pitchShifted
    ) {
        self.gain = gain
        self.pan = pan
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.leadingCrossfade = leadingCrossfade
        self.trailingCrossfade = trailingCrossfade
        self.retimeMode = retimeMode
    }

    private enum CodingKeys: String, CodingKey {
        case gain
        case pan
        case fadeIn
        case fadeOut
        case leadingCrossfade
        case trailingCrossfade
        case retimeMode
    }

    /// Decodes sparse and legacy audio-mix payloads with identity defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gain = try container.decodeIfPresent(
            Animatable<RationalValue>.self,
            forKey: .gain
        ) ?? .constant(.one)
        pan = try container.decodeIfPresent(
            Animatable<RationalValue>.self,
            forKey: .pan
        ) ?? .constant(.zero)
        fadeIn = try container.decodeIfPresent(ClipAudioFade.self, forKey: .fadeIn) ?? .none
        fadeOut = try container.decodeIfPresent(ClipAudioFade.self, forKey: .fadeOut) ?? .none
        leadingCrossfade = try container.decodeIfPresent(
            ClipAudioCrossfade.self,
            forKey: .leadingCrossfade
        )
        trailingCrossfade = try container.decodeIfPresent(
            ClipAudioCrossfade.self,
            forKey: .trailingCrossfade
        )
        // Absent key = pitch-shifted varispeed: the exact legacy behavior (FR-SPD-001).
        retimeMode = try container.decodeIfPresent(
            ClipAudioRetimeMode.self,
            forKey: .retimeMode
        ) ?? .pitchShifted
    }

    /// Encodes the full audio mix payload.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gain, forKey: .gain)
        try container.encode(pan, forKey: .pan)
        try container.encode(fadeIn, forKey: .fadeIn)
        try container.encode(fadeOut, forKey: .fadeOut)
        try container.encodeIfPresent(leadingCrossfade, forKey: .leadingCrossfade)
        try container.encodeIfPresent(trailingCrossfade, forKey: .trailingCrossfade)
        try container.encode(retimeMode, forKey: .retimeMode)
    }

    /// Evaluates keyframable gain and pan at an exact timeline time.
    public func value(at time: RationalTime) -> ClipAudioMixValue {
        ClipAudioMixValue(gain: gain.value(at: time), pan: pan.value(at: time))
    }

    /// Evaluates the fade envelope multiplier for a local clip time.
    public func fadeEnvelope(
        at localTime: RationalTime,
        clipDuration: RationalTime
    ) -> RationalValue {
        guard clipDuration > .zero else {
            return .zero
        }

        let fadeInMultiplier = Self.fadeInMultiplier(
            fade: fadeIn,
            localTime: localTime
        )
        let fadeOutMultiplier = Self.fadeOutMultiplier(
            fade: fadeOut,
            localTime: localTime,
            clipDuration: clipDuration
        )

        return RationalValue.approximating(fadeInMultiplier * fadeOutMultiplier)
    }

    private static func fadeInMultiplier(
        fade: ClipAudioFade,
        localTime: RationalTime
    ) -> Double {
        guard fade.duration > .zero else {
            return 1
        }
        if localTime <= .zero {
            return 0
        }
        if localTime >= fade.duration {
            return 1
        }
        return fade.curve.value(at: fraction(localTime, over: fade.duration))
    }

    private static func fadeOutMultiplier(
        fade: ClipAudioFade,
        localTime: RationalTime,
        clipDuration: RationalTime
    ) -> Double {
        guard fade.duration > .zero else {
            return 1
        }
        guard let remaining = try? clipDuration.subtracting(localTime) else {
            return 0
        }
        if remaining <= .zero {
            return 0
        }
        if remaining >= fade.duration {
            return 1
        }
        return fade.curve.value(at: fraction(remaining, over: fade.duration))
    }

    private static func fraction(_ elapsed: RationalTime, over duration: RationalTime) -> Double {
        guard duration > .zero else {
            return 1
        }

        do {
            let values = try elapsed.valuesAtCommonTimescale(with: duration)
            guard values.right != 0 else {
                return 1
            }
            return max(0, min(1, Double(values.left) / Double(values.right)))
        } catch {
            guard duration.seconds != 0 else {
                return 1
            }
            return max(0, min(1, elapsed.seconds / duration.seconds))
        }
    }
}

/// Typed audio-mix validation errors.
public enum AudioMixValidationError: Equatable, Sendable {
    /// Base gain is outside the supported linear gain range.
    case gainOutOfRange(value: RationalValue, minimum: RationalValue, maximum: RationalValue)

    /// A gain keyframe is outside the supported linear gain range.
    case gainKeyframeOutOfRange(
        time: RationalTime,
        value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue
    )

    /// Base pan is outside the `-1...1` range.
    case panOutOfRange(value: RationalValue, minimum: RationalValue, maximum: RationalValue)

    /// A pan keyframe is outside the `-1...1` range.
    case panKeyframeOutOfRange(
        time: RationalTime,
        value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue
    )

    /// A fade or crossfade duration is negative.
    case fadeDurationNegative(edge: ClipAudioFadeEdge, duration: RationalTime)

    /// A fade or crossfade duration is longer than the clip.
    case fadeDurationExceedsClip(
        edge: ClipAudioFadeEdge,
        duration: RationalTime,
        clipDuration: RationalTime
    )

    /// Crossfade metadata points back at the same clip.
    case crossfadePartnerMatchesClip(edge: ClipAudioFadeEdge, clipID: UUID)
}

enum AudioMixValidator {
    static func errors(
        gain: Animatable<RationalValue>,
        pan: Animatable<RationalValue>
    ) -> [AudioMixValidationError] {
        var errors: [AudioMixValidationError] = []
        appendGainErrors(gain, to: &errors)
        appendPanErrors(pan, to: &errors)
        return errors
    }

    static func errors(
        for mix: ClipAudioMix,
        clipID: UUID,
        clipDuration: RationalTime
    ) -> [AudioMixValidationError] {
        var errors = errors(gain: mix.gain, pan: mix.pan)
        appendFadeErrors(
            duration: mix.fadeIn.duration,
            edge: .fadeIn,
            clipDuration: clipDuration,
            to: &errors
        )
        appendFadeErrors(
            duration: mix.fadeOut.duration,
            edge: .fadeOut,
            clipDuration: clipDuration,
            to: &errors
        )
        appendCrossfadeErrors(
            mix.leadingCrossfade,
            edge: .leadingCrossfade,
            clipID: clipID,
            clipDuration: clipDuration,
            to: &errors
        )
        appendCrossfadeErrors(
            mix.trailingCrossfade,
            edge: .trailingCrossfade,
            clipID: clipID,
            clipDuration: clipDuration,
            to: &errors
        )
        return errors
    }

    private static func appendGainErrors(
        _ gain: Animatable<RationalValue>,
        to errors: inout [AudioMixValidationError]
    ) {
        if isGainOutOfRange(gain.base) {
            errors.append(
                .gainOutOfRange(
                    value: gain.base,
                    minimum: AudioMixLimits.minimumGain,
                    maximum: AudioMixLimits.maximumGain
                )
            )
        }

        for keyframe in gain.keyframes where isGainOutOfRange(keyframe.value) {
            errors.append(
                .gainKeyframeOutOfRange(
                    time: keyframe.time,
                    value: keyframe.value,
                    minimum: AudioMixLimits.minimumGain,
                    maximum: AudioMixLimits.maximumGain
                )
            )
        }
    }

    private static func appendPanErrors(
        _ pan: Animatable<RationalValue>,
        to errors: inout [AudioMixValidationError]
    ) {
        if isPanOutOfRange(pan.base) {
            errors.append(
                .panOutOfRange(
                    value: pan.base,
                    minimum: AudioMixLimits.minimumPan,
                    maximum: AudioMixLimits.maximumPan
                )
            )
        }

        for keyframe in pan.keyframes where isPanOutOfRange(keyframe.value) {
            errors.append(
                .panKeyframeOutOfRange(
                    time: keyframe.time,
                    value: keyframe.value,
                    minimum: AudioMixLimits.minimumPan,
                    maximum: AudioMixLimits.maximumPan
                )
            )
        }
    }

    private static func appendFadeErrors(
        duration: RationalTime,
        edge: ClipAudioFadeEdge,
        clipDuration: RationalTime,
        to errors: inout [AudioMixValidationError]
    ) {
        if duration < .zero {
            errors.append(.fadeDurationNegative(edge: edge, duration: duration))
        }
        if duration > clipDuration {
            errors.append(
                .fadeDurationExceedsClip(
                    edge: edge,
                    duration: duration,
                    clipDuration: clipDuration
                )
            )
        }
    }

    private static func appendCrossfadeErrors(
        _ crossfade: ClipAudioCrossfade?,
        edge: ClipAudioFadeEdge,
        clipID: UUID,
        clipDuration: RationalTime,
        to errors: inout [AudioMixValidationError]
    ) {
        guard let crossfade else {
            return
        }

        appendFadeErrors(
            duration: crossfade.duration,
            edge: edge,
            clipDuration: clipDuration,
            to: &errors
        )
        if crossfade.partnerClipID == clipID {
            errors.append(.crossfadePartnerMatchesClip(edge: edge, clipID: clipID))
        }
    }

    private static func isGainOutOfRange(_ value: RationalValue) -> Bool {
        value.doubleValue < AudioMixLimits.minimumGain.doubleValue
            || value.doubleValue > AudioMixLimits.maximumGain.doubleValue
    }

    private static func isPanOutOfRange(_ value: RationalValue) -> Bool {
        value.doubleValue < AudioMixLimits.minimumPan.doubleValue
            || value.doubleValue > AudioMixLimits.maximumPan.doubleValue
    }
}
