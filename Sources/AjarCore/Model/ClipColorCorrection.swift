// SPDX-License-Identifier: GPL-3.0-or-later

/// RGB channel controls for primary color correction.
public struct ClipColorChannels: Codable, Equatable, Sendable {
    /// Red channel value.
    public let red: RationalValue

    /// Green channel value.
    public let green: RationalValue

    /// Blue channel value.
    public let blue: RationalValue

    /// Zero-valued channels.
    public static let zero = ClipColorChannels(red: .zero, green: .zero, blue: .zero)

    /// One-valued channels.
    public static let one = ClipColorChannels(red: .one, green: .one, blue: .one)

    /// Creates RGB channel controls.
    public init(red: RationalValue, green: RationalValue, blue: RationalValue) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Scalar FR-COL-001 primary color-correction controls.
public enum ClipColorCorrectionParameter: String, Equatable, Sendable {
    /// Exposure in stops.
    case exposure

    /// Contrast multiplier.
    case contrast

    /// Saturation multiplier.
    case saturation

    /// Warm/cool balance normalized to -1...1.
    case temperature

    /// Green/magenta balance normalized to -1...1.
    case tint

    /// Selective saturation normalized to -1...1.
    case vibrance
}

/// Per-channel FR-COL-001 primary color-correction controls.
public enum ClipColorCorrectionChannelGroup: String, Equatable, Sendable {
    /// Lift offset.
    case lift

    /// Gamma curve.
    case gamma

    /// Gain multiplier.
    case gain
}

/// Primary color-correction controls for FR-COL-001.
public struct ClipColorCorrection: Codable, Equatable, Sendable {
    /// Lift offset per channel, valid -1...1.
    public let lift: ClipColorChannels

    /// Gamma per channel, valid 0.01...4.
    public let gamma: ClipColorChannels

    /// Gain multiplier per channel, valid 0...4.
    public let gain: ClipColorChannels

    /// Exposure in stops, valid -10...10.
    public let exposure: RationalValue

    /// Contrast multiplier, valid 0...4.
    public let contrast: RationalValue

    /// Saturation multiplier, valid 0...4.
    public let saturation: RationalValue

    /// Warm/cool balance, valid -1...1.
    public let temperature: RationalValue

    /// Green/magenta balance, valid -1...1.
    public let tint: RationalValue

    /// Selective saturation, valid -1...1.
    public let vibrance: RationalValue

    /// Neutral color correction that leaves pixels unchanged.
    public static let identity = ClipColorCorrection()

    /// Creates primary color-correction controls.
    public init(
        lift: ClipColorChannels = .zero,
        gamma: ClipColorChannels = .one,
        gain: ClipColorChannels = .one,
        exposure: RationalValue = .zero,
        contrast: RationalValue = .one,
        saturation: RationalValue = .one,
        temperature: RationalValue = .zero,
        tint: RationalValue = .zero,
        vibrance: RationalValue = .zero
    ) {
        self.lift = lift
        self.gamma = gamma
        self.gain = gain
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
        self.vibrance = vibrance
    }
}

/// Keyframable RGB channel controls for primary color correction.
public struct AnimatableClipColorChannels: Codable, Equatable, Sendable {
    /// Red channel value.
    public let red: Animatable<RationalValue>

    /// Green channel value.
    public let green: Animatable<RationalValue>

    /// Blue channel value.
    public let blue: Animatable<RationalValue>

    /// Zero-valued channels.
    public static let zero = AnimatableClipColorChannels.constant(.zero)

    /// One-valued channels.
    public static let one = AnimatableClipColorChannels.constant(.one)

    /// Creates keyframable RGB channel controls.
    public init(
        red: Animatable<RationalValue>,
        green: Animatable<RationalValue>,
        blue: Animatable<RationalValue>
    ) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Creates keyframable channels with constant values.
    public static func constant(_ channels: ClipColorChannels) -> AnimatableClipColorChannels {
        AnimatableClipColorChannels(
            red: .constant(channels.red),
            green: .constant(channels.green),
            blue: .constant(channels.blue)
        )
    }

    /// Evaluates channels at a sequence time.
    public func value(at time: RationalTime) -> ClipColorChannels {
        ClipColorChannels(
            red: red.value(at: time),
            green: green.value(at: time),
            blue: blue.value(at: time)
        )
    }

    /// Static channels represented by base keyframe values.
    public var baseChannels: ClipColorChannels {
        ClipColorChannels(red: red.base, green: green.base, blue: blue.base)
    }
}

/// Keyframable primary color-correction controls for FR-COL-001.
public struct AnimatableClipColorCorrection: Codable, Equatable, Sendable {
    /// Lift offset per channel.
    public let lift: AnimatableClipColorChannels

    /// Gamma per channel.
    public let gamma: AnimatableClipColorChannels

    /// Gain multiplier per channel.
    public let gain: AnimatableClipColorChannels

    /// Exposure in stops.
    public let exposure: Animatable<RationalValue>

    /// Contrast multiplier.
    public let contrast: Animatable<RationalValue>

    /// Saturation multiplier.
    public let saturation: Animatable<RationalValue>

    /// Warm/cool balance.
    public let temperature: Animatable<RationalValue>

    /// Green/magenta balance.
    public let tint: Animatable<RationalValue>

    /// Selective saturation.
    public let vibrance: Animatable<RationalValue>

    /// Neutral keyframable color correction.
    public static let identity = AnimatableClipColorCorrection.constant(.identity)

    /// Creates keyframable primary color-correction controls.
    public init(
        lift: AnimatableClipColorChannels = .zero,
        gamma: AnimatableClipColorChannels = .one,
        gain: AnimatableClipColorChannels = .one,
        exposure: Animatable<RationalValue> = .constant(.zero),
        contrast: Animatable<RationalValue> = .constant(.one),
        saturation: Animatable<RationalValue> = .constant(.one),
        temperature: Animatable<RationalValue> = .constant(.zero),
        tint: Animatable<RationalValue> = .constant(.zero),
        vibrance: Animatable<RationalValue> = .constant(.zero)
    ) {
        self.lift = lift
        self.gamma = gamma
        self.gain = gain
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
        self.vibrance = vibrance
    }

    /// Creates keyframable controls with constant values.
    public static func constant(
        _ correction: ClipColorCorrection
    ) -> AnimatableClipColorCorrection {
        AnimatableClipColorCorrection(
            lift: .constant(correction.lift),
            gamma: .constant(correction.gamma),
            gain: .constant(correction.gain),
            exposure: .constant(correction.exposure),
            contrast: .constant(correction.contrast),
            saturation: .constant(correction.saturation),
            temperature: .constant(correction.temperature),
            tint: .constant(correction.tint),
            vibrance: .constant(correction.vibrance)
        )
    }

    /// Evaluates keyframable controls at a sequence time.
    public func value(at time: RationalTime) -> ClipColorCorrection {
        ClipColorCorrection(
            lift: lift.value(at: time),
            gamma: gamma.value(at: time),
            gain: gain.value(at: time),
            exposure: exposure.value(at: time),
            contrast: contrast.value(at: time),
            saturation: saturation.value(at: time),
            temperature: temperature.value(at: time),
            tint: tint.value(at: time),
            vibrance: vibrance.value(at: time)
        )
    }

    /// Static controls represented by base keyframe values.
    public var baseCorrection: ClipColorCorrection {
        ClipColorCorrection(
            lift: lift.baseChannels,
            gamma: gamma.baseChannels,
            gain: gain.baseChannels,
            exposure: exposure.base,
            contrast: contrast.base,
            saturation: saturation.base,
            temperature: temperature.base,
            tint: tint.base,
            vibrance: vibrance.base
        )
    }
}
