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

    /// Matte choke/shrink amount, 0...1.
    public let choke: RationalValue

    /// Shows the resolved matte as grayscale instead of the keyed composite.
    public let viewMatte: Bool

    /// Disabled keyer with stable default values.
    public static let disabled = ClipChromaKeySettings(
        enabled: false,
        keyColor: .green,
        tolerance: .zero,
        edgeSoftness: .zero,
        spillSuppression: .zero,
        choke: .zero,
        viewMatte: false
    )

    /// Creates chroma-key settings.
    public init(
        enabled: Bool,
        keyColor: ClipRGBColor = .green,
        tolerance: RationalValue,
        edgeSoftness: RationalValue,
        spillSuppression: RationalValue,
        choke: RationalValue = .zero,
        viewMatte: Bool = false
    ) {
        self.enabled = enabled
        self.keyColor = keyColor
        self.tolerance = tolerance
        self.edgeSoftness = edgeSoftness
        self.spillSuppression = spillSuppression
        self.choke = choke
        self.viewMatte = viewMatte
    }
}

/// Keyframable chroma-key controls that evaluate to static render settings.
public struct AnimatableClipChromaKeySettings: Codable, Equatable, Sendable {
    /// Whether the keyer participates in rendering.
    public let enabled: Bool

    /// Sampled color to remove.
    public let keyColor: ClipRGBColor

    /// Key color acceptance range.
    public let tolerance: Animatable<RationalValue>

    /// Matte edge softening amount.
    public let edgeSoftness: Animatable<RationalValue>

    /// De-spill amount.
    public let spillSuppression: Animatable<RationalValue>

    /// Matte choke/shrink amount.
    public let choke: Animatable<RationalValue>

    /// Shows the matte as grayscale instead of the keyed composite.
    public let viewMatte: Bool

    /// Disabled keyer with stable default values.
    public static let disabled = AnimatableClipChromaKeySettings.constant(.disabled)

    /// Creates keyframable chroma-key settings.
    public init(
        enabled: Bool,
        keyColor: ClipRGBColor = .green,
        tolerance: Animatable<RationalValue>,
        edgeSoftness: Animatable<RationalValue>,
        spillSuppression: Animatable<RationalValue>,
        choke: Animatable<RationalValue> = .constant(.zero),
        viewMatte: Bool = false
    ) {
        self.enabled = enabled
        self.keyColor = keyColor
        self.tolerance = tolerance
        self.edgeSoftness = edgeSoftness
        self.spillSuppression = spillSuppression
        self.choke = choke
        self.viewMatte = viewMatte
    }

    /// Creates keyframable settings with constant values.
    public static func constant(
        _ settings: ClipChromaKeySettings
    ) -> AnimatableClipChromaKeySettings {
        AnimatableClipChromaKeySettings(
            enabled: settings.enabled,
            keyColor: settings.keyColor,
            tolerance: .constant(settings.tolerance),
            edgeSoftness: .constant(settings.edgeSoftness),
            spillSuppression: .constant(settings.spillSuppression),
            choke: .constant(settings.choke),
            viewMatte: settings.viewMatte
        )
    }

    /// Evaluates keyframable controls at a sequence time.
    public func value(at time: RationalTime) -> ClipChromaKeySettings {
        ClipChromaKeySettings(
            enabled: enabled,
            keyColor: keyColor,
            tolerance: tolerance.value(at: time),
            edgeSoftness: edgeSoftness.value(at: time),
            spillSuppression: spillSuppression.value(at: time),
            choke: choke.value(at: time),
            viewMatte: viewMatte
        )
    }

    /// Static settings represented by base keyframe values.
    public var baseSettings: ClipChromaKeySettings {
        ClipChromaKeySettings(
            enabled: enabled,
            keyColor: keyColor,
            tolerance: tolerance.base,
            edgeSoftness: edgeSoftness.base,
            spillSuppression: spillSuppression.base,
            choke: choke.base,
            viewMatte: viewMatte
        )
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

/// Keyframable visual effects attached to a clip.
public struct AnimatableClipEffects: Codable, Equatable, Sendable {
    /// Keyframable chroma-key controls.
    public let chromaKey: AnimatableClipChromaKeySettings

    /// No active effects.
    public static let none = AnimatableClipEffects(chromaKey: .disabled)

    /// Creates keyframable effects.
    public init(chromaKey: AnimatableClipChromaKeySettings = .disabled) {
        self.chromaKey = chromaKey
    }

    /// Creates keyframable effects with constant values.
    public static func constant(_ effects: ClipEffects) -> AnimatableClipEffects {
        AnimatableClipEffects(chromaKey: .constant(effects.chromaKey))
    }

    /// Evaluates all keyframable effects at a sequence time.
    public func value(at time: RationalTime) -> ClipEffects {
        ClipEffects(chromaKey: chromaKey.value(at: time))
    }

    /// Static effects represented by base keyframe values.
    public var baseEffects: ClipEffects {
        ClipEffects(chromaKey: chromaKey.baseSettings)
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

    /// Chroma-key choke must stay in the normalized 0...1 range.
    case chromaKeyChokeOutOfRange(RationalValue)
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
        appendUnitIntervalError(
            effects.chromaKey.choke,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeyChokeOutOfRange
        )

        return errors
    }

    static func errors(for effects: AnimatableClipEffects) -> [ClipEffectsValidationError] {
        var errors = errors(for: effects.baseEffects)

        appendUnitIntervalErrors(
            effects.chromaKey.tolerance,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeyToleranceOutOfRange
        )
        appendUnitIntervalErrors(
            effects.chromaKey.edgeSoftness,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeyEdgeSoftnessOutOfRange
        )
        appendUnitIntervalErrors(
            effects.chromaKey.spillSuppression,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeySpillSuppressionOutOfRange
        )
        appendUnitIntervalErrors(
            effects.chromaKey.choke,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeyChokeOutOfRange
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

    private static func appendUnitIntervalErrors(
        _ parameter: Animatable<RationalValue>,
        to errors: inout [ClipEffectsValidationError],
        error: (RationalValue) -> ClipEffectsValidationError
    ) {
        for keyframe in parameter.keyframes {
            appendUnitIntervalError(keyframe.value, to: &errors, error: error)
        }
    }
}
