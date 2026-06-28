// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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

    /// Shows the resolved combined clip matte as grayscale instead of the keyed composite.
    ///
    /// The preview includes chroma key, luma key, and clip masks because the renderer folds those
    /// controls into one matte before compositing.
    public let viewMatte: Bool

    private enum CodingKeys: String, CodingKey {
        case enabled
        case keyColor
        case tolerance
        case edgeSoftness
        case spillSuppression
        case choke
        case viewMatte
    }

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

    /// Decodes chroma-key settings from current and legacy project schemas.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        keyColor = try container.decode(ClipRGBColor.self, forKey: .keyColor)
        tolerance = try container.decode(RationalValue.self, forKey: .tolerance)
        edgeSoftness = try container.decode(RationalValue.self, forKey: .edgeSoftness)
        spillSuppression = try container.decode(RationalValue.self, forKey: .spillSuppression)
        choke = try container.decodeIfPresent(RationalValue.self, forKey: .choke) ?? .zero
        viewMatte = try container.decodeIfPresent(Bool.self, forKey: .viewMatte) ?? false
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

    /// Shows the resolved combined clip matte as grayscale instead of the keyed composite.
    ///
    /// The preview includes chroma key, luma key, and clip masks because the renderer folds those
    /// controls into one matte before compositing.
    public let viewMatte: Bool

    private enum CodingKeys: String, CodingKey {
        case enabled
        case keyColor
        case tolerance
        case edgeSoftness
        case spillSuppression
        case choke
        case viewMatte
    }

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

    /// Decodes keyframable chroma-key settings from current and legacy schemas.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        keyColor = try container.decode(ClipRGBColor.self, forKey: .keyColor)
        tolerance = try container.decode(Animatable<RationalValue>.self, forKey: .tolerance)
        edgeSoftness = try container.decode(Animatable<RationalValue>.self, forKey: .edgeSoftness)
        spillSuppression = try container.decode(
            Animatable<RationalValue>.self,
            forKey: .spillSuppression
        )
        choke = try container.decodeIfPresent(
            Animatable<RationalValue>.self,
            forKey: .choke
        ) ?? .constant(.zero)
        viewMatte = try container.decodeIfPresent(Bool.self, forKey: .viewMatte) ?? false
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

    /// Luma-key settings.
    public let lumaKey: ClipLumaKeySettings

    /// Primary color-correction settings.
    public let colorCorrection: ClipColorCorrection

    /// Ordered masks applied to the clip matte.
    public let masks: [ClipMask]

    private enum CodingKeys: String, CodingKey {
        case chromaKey
        case lumaKey
        case colorCorrection
        case masks
    }

    /// No active effects.
    public static let none = ClipEffects(
        chromaKey: .disabled,
        lumaKey: .disabled,
        colorCorrection: .identity,
        masks: []
    )

    /// Creates clip effects.
    public init(
        chromaKey: ClipChromaKeySettings = .disabled,
        lumaKey: ClipLumaKeySettings = .disabled,
        colorCorrection: ClipColorCorrection = .identity,
        masks: [ClipMask] = []
    ) {
        self.chromaKey = chromaKey
        self.lumaKey = lumaKey
        self.colorCorrection = colorCorrection
        self.masks = masks
    }

    /// Decodes clip effects from current and legacy project schemas.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chromaKey = try container.decodeIfPresent(
            ClipChromaKeySettings.self,
            forKey: .chromaKey
        ) ?? .disabled
        lumaKey = try container.decodeIfPresent(
            ClipLumaKeySettings.self,
            forKey: .lumaKey
        ) ?? .disabled
        colorCorrection = try container.decodeIfPresent(
            ClipColorCorrection.self,
            forKey: .colorCorrection
        ) ?? .identity
        masks = try container.decodeIfPresent([ClipMask].self, forKey: .masks) ?? []
    }

    /// Returns effects with a replacement chroma key while preserving other effect slots.
    public func replacing(chromaKey: ClipChromaKeySettings) -> ClipEffects {
        ClipEffects(
            chromaKey: chromaKey,
            lumaKey: lumaKey,
            colorCorrection: colorCorrection,
            masks: masks
        )
    }

    /// Returns effects with a replacement luma key while preserving other effect slots.
    public func replacing(lumaKey: ClipLumaKeySettings) -> ClipEffects {
        ClipEffects(
            chromaKey: chromaKey,
            lumaKey: lumaKey,
            colorCorrection: colorCorrection,
            masks: masks
        )
    }

    /// Returns effects with replacement color correction while preserving other effect slots.
    public func replacing(colorCorrection: ClipColorCorrection) -> ClipEffects {
        ClipEffects(
            chromaKey: chromaKey,
            lumaKey: lumaKey,
            colorCorrection: colorCorrection,
            masks: masks
        )
    }

    /// Returns effects with a replacement mask list while preserving other effect slots.
    public func replacing(masks: [ClipMask]) -> ClipEffects {
        ClipEffects(
            chromaKey: chromaKey,
            lumaKey: lumaKey,
            colorCorrection: colorCorrection,
            masks: masks
        )
    }
}

/// Keyframable visual effects attached to a clip.
public struct AnimatableClipEffects: Codable, Equatable, Sendable {
    /// Keyframable chroma-key controls.
    public let chromaKey: AnimatableClipChromaKeySettings

    /// Keyframable luma-key controls.
    public let lumaKey: AnimatableClipLumaKeySettings

    /// Keyframable primary color-correction controls.
    public let colorCorrection: AnimatableClipColorCorrection

    /// Keyframable masks.
    public let masks: [AnimatableClipMask]

    private enum CodingKeys: String, CodingKey {
        case chromaKey
        case lumaKey
        case colorCorrection
        case masks
    }

    /// No active effects.
    public static let none = AnimatableClipEffects(
        chromaKey: .disabled,
        lumaKey: .disabled,
        colorCorrection: .identity,
        masks: []
    )

    /// Creates keyframable effects.
    public init(
        chromaKey: AnimatableClipChromaKeySettings = .disabled,
        lumaKey: AnimatableClipLumaKeySettings = .disabled,
        colorCorrection: AnimatableClipColorCorrection = .identity,
        masks: [AnimatableClipMask] = []
    ) {
        self.chromaKey = chromaKey
        self.lumaKey = lumaKey
        self.colorCorrection = colorCorrection
        self.masks = masks
    }

    /// Decodes keyframable effects from current and legacy project schemas.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chromaKey = try container.decodeIfPresent(
            AnimatableClipChromaKeySettings.self,
            forKey: .chromaKey
        ) ?? .disabled
        lumaKey = try container.decodeIfPresent(
            AnimatableClipLumaKeySettings.self,
            forKey: .lumaKey
        ) ?? .disabled
        colorCorrection = try container.decodeIfPresent(
            AnimatableClipColorCorrection.self,
            forKey: .colorCorrection
        ) ?? .identity
        masks = try container.decodeIfPresent([AnimatableClipMask].self, forKey: .masks) ?? []
    }

    /// Creates keyframable effects with constant values.
    public static func constant(_ effects: ClipEffects) -> AnimatableClipEffects {
        AnimatableClipEffects(
            chromaKey: .constant(effects.chromaKey),
            lumaKey: .constant(effects.lumaKey),
            colorCorrection: .constant(effects.colorCorrection),
            masks: effects.masks.map(AnimatableClipMask.constant)
        )
    }

    /// Returns keyframable effects with replacement static values for any changed effect slots.
    public func replacingChangedEffects(
        from oldEffects: ClipEffects,
        to newEffects: ClipEffects
    ) -> AnimatableClipEffects {
        var effects = self
        if oldEffects.chromaKey != newEffects.chromaKey {
            effects = effects.replacing(chromaKey: newEffects.chromaKey)
        }
        if oldEffects.lumaKey != newEffects.lumaKey {
            effects = effects.replacing(lumaKey: newEffects.lumaKey)
        }
        if oldEffects.colorCorrection != newEffects.colorCorrection {
            effects = effects.replacing(colorCorrection: newEffects.colorCorrection)
        }
        if oldEffects.masks != newEffects.masks {
            effects = effects.replacing(masks: newEffects.masks)
        }
        return effects
    }

    /// Returns effects with replacement chroma-key animation while preserving other slots.
    public func replacing(chromaKey: ClipChromaKeySettings) -> AnimatableClipEffects {
        AnimatableClipEffects(
            chromaKey: .constant(chromaKey),
            lumaKey: lumaKey,
            colorCorrection: colorCorrection,
            masks: masks
        )
    }

    /// Returns effects with replacement luma-key animation while preserving other slots.
    public func replacing(lumaKey: ClipLumaKeySettings) -> AnimatableClipEffects {
        AnimatableClipEffects(
            chromaKey: chromaKey,
            lumaKey: .constant(lumaKey),
            colorCorrection: colorCorrection,
            masks: masks
        )
    }

    /// Returns effects with replacement color-correction animation while preserving other slots.
    public func replacing(colorCorrection: ClipColorCorrection) -> AnimatableClipEffects {
        AnimatableClipEffects(
            chromaKey: chromaKey,
            lumaKey: lumaKey,
            colorCorrection: .constant(colorCorrection),
            masks: masks
        )
    }

    /// Returns effects with replacement mask animations while preserving other slots.
    public func replacing(masks: [ClipMask]) -> AnimatableClipEffects {
        AnimatableClipEffects(
            chromaKey: chromaKey,
            lumaKey: lumaKey,
            colorCorrection: colorCorrection,
            masks: masks.map(AnimatableClipMask.constant)
        )
    }

    /// Evaluates all keyframable effects at a sequence time.
    public func value(at time: RationalTime) -> ClipEffects {
        ClipEffects(
            chromaKey: chromaKey.value(at: time),
            lumaKey: lumaKey.value(at: time),
            colorCorrection: colorCorrection.value(at: time),
            masks: masks.map { mask in mask.value(at: time) }
        )
    }

    /// Static effects represented by base keyframe values.
    public var baseEffects: ClipEffects {
        ClipEffects(
            chromaKey: chromaKey.baseSettings,
            lumaKey: lumaKey.baseSettings,
            colorCorrection: colorCorrection.baseCorrection,
            masks: masks.map { mask in mask.value(at: .zero) }
        )
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

    /// A scalar luma-key parameter is outside its supported range.
    case lumaKeyParameterOutOfRange(
        parameter: ClipLumaKeyParameter,
        value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue
    )

    /// Luma-key low threshold must not exceed the high threshold.
    case lumaKeyThresholdOrderInvalid(
        lowThreshold: RationalValue,
        highThreshold: RationalValue
    )

    /// A scalar color-correction parameter is outside its supported range.
    case colorCorrectionParameterOutOfRange(
        parameter: ClipColorCorrectionParameter,
        value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue
    )

    /// A color-correction channel is outside its supported range.
    case colorCorrectionChannelOutOfRange(
        group: ClipColorCorrectionChannelGroup,
        channel: ClipColorChannel,
        value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue
    )

    /// A clip has more masks than the M5 render path supports.
    case clipMaskCountOutOfRange(count: Int, maximum: Int)

    /// Mask feather radius must be non-negative.
    case clipMaskFeatherRadiusNegative(maskID: UUID, RationalValue)

    /// Rectangle mask width and height must be positive.
    case clipMaskRectangleSizeInvalid(maskID: UUID)

    /// Ellipse mask radii must be positive.
    case clipMaskEllipseRadiusInvalid(maskID: UUID)

    /// Polygon masks must have a supported point count.
    case clipMaskPolygonPointCountInvalid(maskID: UUID, count: Int, maximum: Int)
}
