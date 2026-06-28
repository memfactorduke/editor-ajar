// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Errors produced by exact rational value construction.
public enum RationalValueError: Error, Equatable, Sendable {
    /// A rational value was created with a zero or negative denominator.
    case invalidDenominator(Int64)
}

/// An exact, normalized rational number for non-time model values.
public struct RationalValue: Codable, Hashable, Sendable {
    /// The signed numerator of the normalized value.
    public let numerator: Int64

    /// The positive denominator of the normalized value.
    public let denominator: Int64

    /// Exact zero.
    public static let zero = RationalValue(normalizedNumerator: 0, denominator: 1)

    /// Exact one.
    public static let one = RationalValue(normalizedNumerator: 1, denominator: 1)

    /// Creates an integer rational value.
    public init(_ integer: Int64) {
        self.init(normalizedNumerator: integer, denominator: 1)
    }

    /// Creates a normalized rational value from `numerator / denominator`.
    public init(numerator: Int64, denominator: Int64) throws {
        guard denominator > 0 else {
            throw RationalValueError.invalidDenominator(denominator)
        }

        let divisor = Self.greatestCommonDivisor(numerator.magnitude, UInt64(denominator))
        let signedDivisor = Int64(divisor)
        self.init(
            normalizedNumerator: numerator / signedDivisor,
            denominator: denominator / signedDivisor
        )
    }

    /// Whether this value is less than zero.
    public var isNegative: Bool {
        numerator < 0
    }

    /// Whether this value is greater than one.
    public var isGreaterThanOne: Bool {
        numerator > denominator
    }

    private init(normalizedNumerator: Int64, denominator: Int64) {
        self.numerator = normalizedNumerator
        self.denominator = denominator
    }

    private enum CodingKeys: String, CodingKey {
        case numerator
        case denominator
    }

    /// Decodes and normalizes a rational value.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            numerator: container.decode(Int64.self, forKey: .numerator),
            denominator: container.decode(Int64.self, forKey: .denominator)
        )
    }

    /// Encodes the normalized rational value.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(numerator, forKey: .numerator)
        try container.encode(denominator, forKey: .denominator)
    }

    private static func greatestCommonDivisor(_ left: UInt64, _ right: UInt64) -> UInt64 {
        var currentLeft = left
        var currentRight = right

        while currentRight != 0 {
            let remainder = currentLeft % currentRight
            currentLeft = currentRight
            currentRight = remainder
        }

        return currentLeft == 0 ? 1 : currentLeft
    }
}

/// A point in sequence canvas units.
public struct CanvasPoint: Codable, Equatable, Sendable {
    /// Horizontal coordinate.
    public let x: RationalValue

    /// Vertical coordinate.
    public let y: RationalValue

    /// Origin point.
    public static let zero = CanvasPoint(x: .zero, y: .zero)

    /// Creates a canvas point.
    public init(x: RationalValue, y: RationalValue) {
        self.x = x
        self.y = y
    }
}

/// Per-axis clip scale.
public struct ClipScale: Codable, Equatable, Sendable {
    /// Horizontal scale factor.
    public let x: RationalValue

    /// Vertical scale factor.
    public let y: RationalValue

    /// Identity scale.
    public static let identity = ClipScale(x: .one, y: .one)

    /// Creates per-axis scale.
    public init(x: RationalValue, y: RationalValue) {
        self.x = x
        self.y = y
    }
}

/// Clip rotation stored as degrees plus whole-revolution count.
public struct ClipRotation: Codable, Equatable, Sendable {
    /// Rotation in degrees.
    public let degrees: RationalValue

    /// Whole revolutions, kept separately for unbounded user-facing rotation.
    public let revolutions: Int64

    /// Identity rotation.
    public static let zero = ClipRotation(degrees: .zero, revolutions: 0)

    /// Creates a rotation value.
    public init(degrees: RationalValue, revolutions: Int64 = 0) {
        self.degrees = degrees
        self.revolutions = revolutions
    }
}

/// Blend modes modelled by the headless clip transform.
public enum ClipBlendMode: String, Codable, CaseIterable, Equatable, Sendable {
    /// Source replaces destination according to opacity.
    case normal

    /// Multiplies source and destination color.
    case multiply

    /// Screens source over destination.
    case screen

    /// Overlay blend.
    case overlay

    /// Additive blend.
    case add

    /// Darken blend.
    case darken

    /// Lighten blend.
    case lighten

    /// Color-dodge blend.
    case colorDodge

    /// Color-burn blend.
    case colorBurn

    /// Hard-light blend.
    case hardLight

    /// Soft-light blend.
    case softLight

    /// Difference blend.
    case difference

    /// Exclusion blend.
    case exclusion

    /// Subtract source color from destination color.
    case subtract

    /// Uses source hue with destination saturation and luminosity.
    case hue

    /// Uses source saturation with destination hue and luminosity.
    case saturation

    /// Uses source hue and saturation with destination luminosity.
    case color

    /// Uses source luminosity with destination hue and saturation.
    case luminosity

    /// Decodes unknown future blend modes as `.normal` so newer projects remain loadable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ClipBlendMode(rawValue: rawValue) ?? .normal
    }

    /// Encodes the stable project-schema raw value.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Crop inset edge names used in validation errors.
public enum ClipCropEdge: String, Equatable, Sendable {
    /// Left crop inset.
    case left

    /// Top crop inset.
    case top

    /// Right crop inset.
    case right

    /// Bottom crop inset.
    case bottom
}

/// Crop insets in whole sequence canvas units.
public struct ClipCropInsets: Codable, Equatable, Sendable {
    /// Left crop inset.
    public let left: Int64

    /// Top crop inset.
    public let top: Int64

    /// Right crop inset.
    public let right: Int64

    /// Bottom crop inset.
    public let bottom: Int64

    /// No crop.
    public static let zero = ClipCropInsets(left: 0, top: 0, right: 0, bottom: 0)

    /// Creates crop insets.
    public init(left: Int64, top: Int64, right: Int64, bottom: Int64) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// Horizontal and vertical flip state.
public struct ClipFlip: Codable, Equatable, Sendable {
    /// Flip horizontally.
    public let horizontal: Bool

    /// Flip vertically.
    public let vertical: Bool

    /// No flip.
    public static let none = ClipFlip(horizontal: false, vertical: false)

    /// Creates flip state.
    public init(horizontal: Bool, vertical: Bool) {
        self.horizontal = horizontal
        self.vertical = vertical
    }
}

/// Per-clip transform parameters for FR-XFORM-001...005.
public struct ClipTransform: Codable, Equatable, Sendable {
    /// Translation in sequence canvas units.
    public let position: CanvasPoint

    /// Per-axis scale.
    public let scale: ClipScale

    /// Anchor point in sequence canvas units.
    public let anchorPoint: CanvasPoint

    /// Rotation in degrees plus whole revolutions.
    public let rotation: ClipRotation

    /// Opacity, where `0` is transparent and `1` is fully opaque.
    public let opacity: RationalValue

    /// Blend mode.
    public let blendMode: ClipBlendMode

    /// Crop insets.
    public let crop: ClipCropInsets

    /// Flip state.
    public let flip: ClipFlip

    /// Identity transform.
    public static let identity = ClipTransform(
        position: .zero,
        scale: .identity,
        anchorPoint: .zero,
        rotation: .zero,
        opacity: .one,
        blendMode: .normal,
        crop: .zero,
        flip: .none
    )

    /// Creates a clip transform.
    public init(
        position: CanvasPoint = .zero,
        scale: ClipScale = .identity,
        anchorPoint: CanvasPoint = .zero,
        rotation: ClipRotation = .zero,
        opacity: RationalValue = .one,
        blendMode: ClipBlendMode = .normal,
        crop: ClipCropInsets = .zero,
        flip: ClipFlip = .none
    ) {
        self.position = position
        self.scale = scale
        self.anchorPoint = anchorPoint
        self.rotation = rotation
        self.opacity = opacity
        self.blendMode = blendMode
        self.crop = crop
        self.flip = flip
    }
}

/// Typed transform validation failures.
public enum ClipTransformValidationError: Equatable, Sendable {
    /// Opacity must be between zero and one, inclusive.
    case opacityOutOfRange(RationalValue)

    /// Crop insets cannot be negative.
    case negativeCropInset(edge: ClipCropEdge, value: Int64)

    /// Combined crop insets cannot exceed the project frame.
    case cropExceedsFrame(crop: ClipCropInsets, frame: PixelDimensions)
}

enum ClipTransformValidator {
    static func errors(
        for transform: ClipTransform,
        frame: PixelDimensions
    ) -> [ClipTransformValidationError] {
        var errors: [ClipTransformValidationError] = []

        if transform.opacity.isNegative || transform.opacity.isGreaterThanOne {
            errors.append(.opacityOutOfRange(transform.opacity))
        }

        appendNegativeCropErrors(transform.crop, to: &errors)
        appendCropBoundsErrors(transform.crop, frame: frame, to: &errors)

        return errors
    }

    private static func appendNegativeCropErrors(
        _ crop: ClipCropInsets,
        to errors: inout [ClipTransformValidationError]
    ) {
        if crop.left < 0 {
            errors.append(.negativeCropInset(edge: .left, value: crop.left))
        }
        if crop.top < 0 {
            errors.append(.negativeCropInset(edge: .top, value: crop.top))
        }
        if crop.right < 0 {
            errors.append(.negativeCropInset(edge: .right, value: crop.right))
        }
        if crop.bottom < 0 {
            errors.append(.negativeCropInset(edge: .bottom, value: crop.bottom))
        }
    }

    private static func appendCropBoundsErrors(
        _ crop: ClipCropInsets,
        frame: PixelDimensions,
        to errors: inout [ClipTransformValidationError]
    ) {
        guard crop.left >= 0, crop.top >= 0, crop.right >= 0, crop.bottom >= 0 else {
            return
        }

        let horizontal = crop.left.addingReportingOverflow(crop.right)
        let vertical = crop.top.addingReportingOverflow(crop.bottom)
        let frameWidth = Int64(frame.width)
        let frameHeight = Int64(frame.height)
        if horizontal.overflow || vertical.overflow
            || horizontal.partialValue > frameWidth
            || vertical.partialValue > frameHeight {
            errors.append(.cropExceedsFrame(crop: crop, frame: frame))
        }
    }
}
