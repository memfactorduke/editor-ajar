// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension ClipEffectLibraryLimits {
    /// Largest supported mosaic cell edge in source pixels.
    public static let maximumMosaicCellSize = RationalValue(256)
}

// MARK: - Vignette

/// Static vignette parameters (FR-FX-002).
///
/// `amount`, `radius`, and `softness` are normalized 0...1 controls. A zero amount is identity.
public struct ClipVignetteParameters: Codable, Equatable, Sendable {
    /// Edge-darkening strength (0...1).
    public let amount: RationalValue

    /// Normalized distance from frame center where the falloff begins (0...1).
    public let radius: RationalValue

    /// Normalized width of the falloff band (0...1).
    public let softness: RationalValue

    private enum CodingKeys: String, CodingKey {
        case amount
        case radius
        case softness
    }

    /// Identity parameters (zero darkening with a conventional falloff shape).
    public static let identity = ClipVignetteParameters()

    /// Creates vignette parameters.
    public init(
        amount: RationalValue = .zero,
        radius: RationalValue = RationalValue.approximating(0.75),
        softness: RationalValue = RationalValue.approximating(0.25)
    ) {
        self.amount = amount
        self.radius = radius
        self.softness = softness
    }

    /// Decodes with legacy-safe per-field defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount = try container.decodeIfPresent(RationalValue.self, forKey: .amount) ?? .zero
        radius =
            try container.decodeIfPresent(RationalValue.self, forKey: .radius)
            ?? RationalValue.approximating(0.75)
        softness =
            try container.decodeIfPresent(RationalValue.self, forKey: .softness)
            ?? RationalValue.approximating(0.25)
    }
}

/// Keyframable vignette parameters.
public struct AnimatableClipVignetteSettings: Codable, Equatable, Sendable {
    /// Keyframable edge-darkening strength.
    public let amount: Animatable<RationalValue>

    /// Keyframable normalized falloff radius.
    public let radius: Animatable<RationalValue>

    /// Keyframable normalized falloff softness.
    public let softness: Animatable<RationalValue>

    private enum CodingKeys: String, CodingKey {
        case amount
        case radius
        case softness
    }

    /// Identity parameters (constant zero amount).
    public static let identity = AnimatableClipVignetteSettings()

    /// Creates keyframable vignette parameters.
    public init(
        amount: Animatable<RationalValue> = .constant(.zero),
        radius: Animatable<RationalValue> = .constant(RationalValue.approximating(0.75)),
        softness: Animatable<RationalValue> = .constant(RationalValue.approximating(0.25))
    ) {
        self.amount = amount
        self.radius = radius
        self.softness = softness
    }

    /// Decodes with legacy-safe per-field defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount =
            try container.decodeIfPresent(Animatable<RationalValue>.self, forKey: .amount)
            ?? .constant(.zero)
        radius =
            try container.decodeIfPresent(Animatable<RationalValue>.self, forKey: .radius)
            ?? .constant(RationalValue.approximating(0.75))
        softness =
            try container.decodeIfPresent(Animatable<RationalValue>.self, forKey: .softness)
            ?? .constant(RationalValue.approximating(0.25))
    }

    /// Creates keyframable parameters with constant values.
    public static func constant(
        _ parameters: ClipVignetteParameters
    ) -> AnimatableClipVignetteSettings {
        AnimatableClipVignetteSettings(
            amount: .constant(parameters.amount),
            radius: .constant(parameters.radius),
            softness: .constant(parameters.softness)
        )
    }

    /// Evaluates parameters at a sequence time.
    public func value(at time: RationalTime) -> ClipVignetteParameters {
        ClipVignetteParameters(
            amount: amount.value(at: time),
            radius: radius.value(at: time),
            softness: softness.value(at: time)
        )
    }

    /// Static parameters represented by base keyframe values.
    public var baseParameters: ClipVignetteParameters {
        ClipVignetteParameters(
            amount: amount.base,
            radius: radius.base,
            softness: softness.base
        )
    }
}

// MARK: - Mirror

/// Discrete mirror geometry. Enums are intentionally not keyframable (ADR-0016 section 2).
public enum ClipMirrorAxis: String, Codable, Equatable, Sendable, CaseIterable {
    /// Fold the horizontal image coordinate so the full source reflects left/right.
    case horizontal

    /// Fold the vertical image coordinate so the full source reflects top/bottom.
    case vertical

    /// Fold both axes so the source is reflected into four quadrants.
    case quad
}

/// Static mirror parameters (FR-FX-002).
public struct ClipMirrorParameters: Codable, Equatable, Sendable {
    /// Mirror geometry.
    public let axis: ClipMirrorAxis

    private enum CodingKeys: String, CodingKey {
        case axis
    }

    /// Default mirror parameters.
    public static let identity = ClipMirrorParameters()

    /// Creates mirror parameters.
    public init(axis: ClipMirrorAxis = .horizontal) {
        self.axis = axis
    }

    /// Decodes with a legacy-safe axis default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        axis = try container.decodeIfPresent(ClipMirrorAxis.self, forKey: .axis) ?? .horizontal
    }
}

/// Animatable mirror settings; the discrete axis remains constant by design.
public struct AnimatableClipMirrorSettings: Codable, Equatable, Sendable {
    /// Constant mirror geometry.
    public let axis: ClipMirrorAxis

    private enum CodingKeys: String, CodingKey {
        case axis
    }

    /// Default mirror settings.
    public static let identity = AnimatableClipMirrorSettings()

    /// Creates mirror settings.
    public init(axis: ClipMirrorAxis = .horizontal) {
        self.axis = axis
    }

    /// Decodes with a legacy-safe axis default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        axis = try container.decodeIfPresent(ClipMirrorAxis.self, forKey: .axis) ?? .horizontal
    }

    /// Creates the animatable form from static parameters.
    public static func constant(
        _ parameters: ClipMirrorParameters
    ) -> AnimatableClipMirrorSettings {
        AnimatableClipMirrorSettings(axis: parameters.axis)
    }

    /// Evaluates the constant discrete setting.
    public func value(at time: RationalTime) -> ClipMirrorParameters {
        _ = time
        return ClipMirrorParameters(axis: axis)
    }

    /// Static parameters represented by this setting.
    public var baseParameters: ClipMirrorParameters {
        ClipMirrorParameters(axis: axis)
    }
}

// MARK: - Mosaic / pixelate

/// Static mosaic parameters (FR-FX-002). `cellSize` is 1...256 source pixels.
public struct ClipMosaicParameters: Codable, Equatable, Sendable {
    /// Square cell edge in source pixels. One is identity.
    public let cellSize: RationalValue

    private enum CodingKeys: String, CodingKey {
        case cellSize
    }

    /// Identity parameters (one source pixel per cell).
    public static let identity = ClipMosaicParameters()

    /// Creates mosaic parameters.
    public init(cellSize: RationalValue = .one) {
        self.cellSize = cellSize
    }

    /// Decodes with a legacy-safe cell-size default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cellSize = try container.decodeIfPresent(RationalValue.self, forKey: .cellSize) ?? .one
    }
}

/// Keyframable mosaic parameters.
public struct AnimatableClipMosaicSettings: Codable, Equatable, Sendable {
    /// Keyframable square cell edge in source pixels.
    public let cellSize: Animatable<RationalValue>

    private enum CodingKeys: String, CodingKey {
        case cellSize
    }

    /// Identity parameters (constant one-pixel cells).
    public static let identity = AnimatableClipMosaicSettings()

    /// Creates keyframable mosaic parameters.
    public init(cellSize: Animatable<RationalValue> = .constant(.one)) {
        self.cellSize = cellSize
    }

    /// Decodes with a legacy-safe cell-size default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cellSize =
            try container.decodeIfPresent(Animatable<RationalValue>.self, forKey: .cellSize)
            ?? .constant(.one)
    }

    /// Creates keyframable parameters with a constant value.
    public static func constant(
        _ parameters: ClipMosaicParameters
    ) -> AnimatableClipMosaicSettings {
        AnimatableClipMosaicSettings(cellSize: .constant(parameters.cellSize))
    }

    /// Evaluates parameters at a sequence time.
    public func value(at time: RationalTime) -> ClipMosaicParameters {
        ClipMosaicParameters(cellSize: cellSize.value(at: time))
    }

    /// Static parameters represented by the base keyframe value.
    public var baseParameters: ClipMosaicParameters {
        ClipMosaicParameters(cellSize: cellSize.base)
    }
}
