// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension ClipEffectLibraryLimits {
    /// Largest supported color-adjust contrast/saturation multiplier.
    public static let maximumColorAdjustMultiplier = RationalValue(4)

    /// Largest supported posterize level count.
    public static let maximumPosterizeLevels = RationalValue(256)
}

// MARK: - Color adjust

/// Static basic color-adjust parameters (FR-FX-002).
public struct ClipColorAdjustParameters: Codable, Equatable, Sendable {
    /// Additive linear-light brightness, valid -1...1.
    public let brightness: RationalValue

    /// Contrast multiplier around middle gray, valid 0...4.
    public let contrast: RationalValue

    /// Linear-light saturation multiplier, valid 0...4.
    public let saturation: RationalValue

    /// Green/magenta balance, valid -1...1.
    public let tint: RationalValue

    private enum CodingKeys: String, CodingKey {
        case brightness
        case contrast
        case saturation
        case tint
    }

    /// Neutral color adjustment.
    public static let identity = ClipColorAdjustParameters()

    /// Creates basic color-adjust parameters.
    public init(
        brightness: RationalValue = .zero,
        contrast: RationalValue = .one,
        saturation: RationalValue = .one,
        tint: RationalValue = .zero
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.tint = tint
    }

    /// Decodes with legacy-safe per-field defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        brightness =
            try container.decodeIfPresent(RationalValue.self, forKey: .brightness) ?? .zero
        contrast = try container.decodeIfPresent(RationalValue.self, forKey: .contrast) ?? .one
        saturation =
            try container.decodeIfPresent(RationalValue.self, forKey: .saturation) ?? .one
        tint = try container.decodeIfPresent(RationalValue.self, forKey: .tint) ?? .zero
    }
}

/// Keyframable basic color-adjust parameters.
public struct AnimatableClipColorAdjustSettings: Codable, Equatable, Sendable {
    /// Keyframable additive brightness.
    public let brightness: Animatable<RationalValue>

    /// Keyframable contrast multiplier.
    public let contrast: Animatable<RationalValue>

    /// Keyframable saturation multiplier.
    public let saturation: Animatable<RationalValue>

    /// Keyframable green/magenta balance.
    public let tint: Animatable<RationalValue>

    private enum CodingKeys: String, CodingKey {
        case brightness
        case contrast
        case saturation
        case tint
    }

    /// Neutral constant color adjustment.
    public static let identity = AnimatableClipColorAdjustSettings()

    /// Creates keyframable basic color-adjust parameters.
    public init(
        brightness: Animatable<RationalValue> = .constant(.zero),
        contrast: Animatable<RationalValue> = .constant(.one),
        saturation: Animatable<RationalValue> = .constant(.one),
        tint: Animatable<RationalValue> = .constant(.zero)
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.tint = tint
    }

    /// Decodes with legacy-safe per-field defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        brightness =
            try container.decodeIfPresent(Animatable<RationalValue>.self, forKey: .brightness)
            ?? .constant(.zero)
        contrast =
            try container.decodeIfPresent(Animatable<RationalValue>.self, forKey: .contrast)
            ?? .constant(.one)
        saturation =
            try container.decodeIfPresent(Animatable<RationalValue>.self, forKey: .saturation)
            ?? .constant(.one)
        tint =
            try container.decodeIfPresent(Animatable<RationalValue>.self, forKey: .tint)
            ?? .constant(.zero)
    }

    /// Creates keyframable parameters with constant values.
    public static func constant(
        _ parameters: ClipColorAdjustParameters
    ) -> AnimatableClipColorAdjustSettings {
        AnimatableClipColorAdjustSettings(
            brightness: .constant(parameters.brightness),
            contrast: .constant(parameters.contrast),
            saturation: .constant(parameters.saturation),
            tint: .constant(parameters.tint)
        )
    }

    /// Evaluates parameters at a sequence time.
    public func value(at time: RationalTime) -> ClipColorAdjustParameters {
        ClipColorAdjustParameters(
            brightness: brightness.value(at: time),
            contrast: contrast.value(at: time),
            saturation: saturation.value(at: time),
            tint: tint.value(at: time)
        )
    }

    /// Static parameters represented by base keyframe values.
    public var baseParameters: ClipColorAdjustParameters {
        ClipColorAdjustParameters(
            brightness: brightness.base,
            contrast: contrast.base,
            saturation: saturation.base,
            tint: tint.base
        )
    }
}

// MARK: - Posterize

/// Static posterize parameters (FR-FX-002). `levels` is valid from 2 through 256.
public struct ClipPosterizeParameters: Codable, Equatable, Sendable {
    /// Number of discrete levels per RGB channel. 256 is the stack identity.
    public let levels: RationalValue

    private enum CodingKeys: String, CodingKey {
        case levels
    }

    /// Identity parameters for normalized 8-bit delivery values.
    public static let identity = ClipPosterizeParameters()

    /// Creates posterize parameters.
    public init(levels: RationalValue = RationalValue(256)) {
        self.levels = levels
    }

    /// Decodes with a legacy-safe level default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        levels =
            try container.decodeIfPresent(RationalValue.self, forKey: .levels)
            ?? RationalValue(256)
    }
}

/// Keyframable posterize parameters.
public struct AnimatableClipPosterizeSettings: Codable, Equatable, Sendable {
    /// Keyframable discrete-level count; render evaluation rounds to the nearest integer.
    public let levels: Animatable<RationalValue>

    private enum CodingKeys: String, CodingKey {
        case levels
    }

    /// Identity parameters (constant 256 levels).
    public static let identity = AnimatableClipPosterizeSettings()

    /// Creates keyframable posterize parameters.
    public init(levels: Animatable<RationalValue> = .constant(RationalValue(256))) {
        self.levels = levels
    }

    /// Decodes with a legacy-safe level default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        levels =
            try container.decodeIfPresent(Animatable<RationalValue>.self, forKey: .levels)
            ?? .constant(RationalValue(256))
    }

    /// Creates keyframable parameters with a constant value.
    public static func constant(
        _ parameters: ClipPosterizeParameters
    ) -> AnimatableClipPosterizeSettings {
        AnimatableClipPosterizeSettings(levels: .constant(parameters.levels))
    }

    /// Evaluates parameters at a sequence time.
    public func value(at time: RationalTime) -> ClipPosterizeParameters {
        ClipPosterizeParameters(levels: levels.value(at: time))
    }

    /// Static parameters represented by the base keyframe value.
    public var baseParameters: ClipPosterizeParameters {
        ClipPosterizeParameters(levels: levels.base)
    }
}

// MARK: - Invert

/// Parameter payload for the parameterless RGB invert kind (FR-FX-002).
public struct ClipInvertParameters: Codable, Equatable, Sendable {
    /// Default invert payload.
    public static let identity = ClipInvertParameters()

    /// Creates an invert payload.
    public init() {}
}

/// Animatable-form payload for invert; there are no scalar parameters to keyframe.
public struct AnimatableClipInvertSettings: Codable, Equatable, Sendable {
    /// Default invert settings.
    public static let identity = AnimatableClipInvertSettings()

    /// Creates invert settings.
    public init() {}

    /// Creates the animatable form from static parameters.
    public static func constant(
        _ parameters: ClipInvertParameters
    ) -> AnimatableClipInvertSettings {
        _ = parameters
        return AnimatableClipInvertSettings()
    }

    /// Evaluates the parameterless setting.
    public func value(at time: RationalTime) -> ClipInvertParameters {
        _ = time
        return ClipInvertParameters()
    }

    /// Static parameters represented by this setting.
    public var baseParameters: ClipInvertParameters {
        ClipInvertParameters()
    }
}
