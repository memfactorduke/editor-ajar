// SPDX-License-Identifier: GPL-3.0-or-later

/// RGB color values stored in normalized 0...1 clip-effect space.
public struct ClipRGBColor: Codable, Equatable, Sendable {
    /// Red channel.
    public let red: RationalValue

    /// Green channel.
    public let green: RationalValue

    /// Blue channel.
    public let blue: RationalValue

    /// Pure green key color.
    public static let green = ClipRGBColor(red: .zero, green: .one, blue: .zero)

    /// Creates a normalized RGB color.
    public init(red: RationalValue, green: RationalValue, blue: RationalValue) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Color channels used in typed clip-effect validation errors.
public enum ClipColorChannel: String, Equatable, Sendable {
    /// Red channel.
    case red

    /// Green channel.
    case green

    /// Blue channel.
    case blue
}

/// Chroma-key controls for FR-COMP-001/002.
public struct ClipChromaKeySettings: Codable, Equatable, Sendable {
    /// Whether the keyer participates in rendering.
    public let enabled: Bool

    /// Sampled color to remove.
    public let keyColor: ClipRGBColor

    /// Distance from key color accepted as transparent, 0...1.
    public let tolerance: RationalValue

    /// Matte edge softening amount, 0...1.
    public let edgeSoftness: RationalValue

    /// Spill suppression amount, 0...1.
    public let spillSuppression: RationalValue

    /// Disabled keyer with stable default values.
    public static let disabled = ClipChromaKeySettings(
        enabled: false,
        keyColor: .green,
        tolerance: .zero,
        edgeSoftness: .zero,
        spillSuppression: .zero
    )

    /// Creates chroma-key settings.
    public init(
        enabled: Bool,
        keyColor: ClipRGBColor = .green,
        tolerance: RationalValue,
        edgeSoftness: RationalValue,
        spillSuppression: RationalValue
    ) {
        self.enabled = enabled
        self.keyColor = keyColor
        self.tolerance = tolerance
        self.edgeSoftness = edgeSoftness
        self.spillSuppression = spillSuppression
    }
}

/// Visual effects attached to a clip.
public struct ClipEffects: Codable, Equatable, Sendable {
    /// Chroma-key settings.
    public let chromaKey: ClipChromaKeySettings

    /// No active effects.
    public static let none = ClipEffects(chromaKey: .disabled)

    /// Creates clip effects.
    public init(chromaKey: ClipChromaKeySettings = .disabled) {
        self.chromaKey = chromaKey
    }

    /// Returns effects with a replacement chroma key while preserving other effect slots.
    public func replacing(chromaKey: ClipChromaKeySettings) -> ClipEffects {
        ClipEffects(chromaKey: chromaKey)
    }
}

/// Typed validation failures for clip effects.
public enum ClipEffectsValidationError: Equatable, Sendable {
    /// A color channel must stay in the normalized 0...1 range.
    case colorChannelOutOfRange(channel: ClipColorChannel, value: RationalValue)

    /// Chroma-key tolerance must stay in the normalized 0...1 range.
    case chromaKeyToleranceOutOfRange(RationalValue)

    /// Chroma-key edge softness must stay in the normalized 0...1 range.
    case chromaKeyEdgeSoftnessOutOfRange(RationalValue)

    /// Chroma-key spill suppression must stay in the normalized 0...1 range.
    case chromaKeySpillSuppressionOutOfRange(RationalValue)
}

enum ClipEffectsValidator {
    static func errors(for effects: ClipEffects) -> [ClipEffectsValidationError] {
        var errors: [ClipEffectsValidationError] = []

        appendColorErrors(effects.chromaKey.keyColor, to: &errors)
        appendUnitIntervalError(
            effects.chromaKey.tolerance,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeyToleranceOutOfRange
        )
        appendUnitIntervalError(
            effects.chromaKey.edgeSoftness,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeyEdgeSoftnessOutOfRange
        )
        appendUnitIntervalError(
            effects.chromaKey.spillSuppression,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeySpillSuppressionOutOfRange
        )

        return errors
    }

    private static func appendColorErrors(
        _ color: ClipRGBColor,
        to errors: inout [ClipEffectsValidationError]
    ) {
        appendUnitIntervalError(color.red, to: &errors) { value in
            .colorChannelOutOfRange(channel: .red, value: value)
        }
        appendUnitIntervalError(color.green, to: &errors) { value in
            .colorChannelOutOfRange(channel: .green, value: value)
        }
        appendUnitIntervalError(color.blue, to: &errors) { value in
            .colorChannelOutOfRange(channel: .blue, value: value)
        }
    }

    private static func appendUnitIntervalError(
        _ value: RationalValue,
        to errors: inout [ClipEffectsValidationError],
        error: (RationalValue) -> ClipEffectsValidationError
    ) {
        if value.isNegative || value.isGreaterThanOne {
            errors.append(error(value))
        }
    }
}
