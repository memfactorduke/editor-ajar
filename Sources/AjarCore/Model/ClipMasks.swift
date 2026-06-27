// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Mask limits shared by validation and the fixed-size GPU uniform payload.
public enum ClipMaskLimits {
    /// Maximum masks supported per clip in the M5 render path.
    public static let maximumMasksPerClip = 4

    /// Maximum polygon points supported by the M5 GPU mask path.
    public static let maximumPolygonPointCount = 8
}

/// How one mask combines with the masks before it in the ordered mask list.
public enum ClipMaskCombineOperation: String, Codable, Equatable, Sendable {
    /// Union with the previous matte.
    case add

    /// Remove this matte from the previous matte.
    case subtract

    /// Keep only the overlap with the previous matte.
    case intersect
}

/// Axis-aligned rectangular mask in clip-local source pixel coordinates.
public struct ClipRectangleMask: Codable, Equatable, Sendable {
    /// Left edge in source pixels.
    public let x: RationalValue

    /// Top edge in source pixels.
    public let y: RationalValue

    /// Width in source pixels. Must be positive.
    public let width: RationalValue

    /// Height in source pixels. Must be positive.
    public let height: RationalValue

    /// Creates a rectangle mask.
    public init(
        x: RationalValue,
        y: RationalValue,
        width: RationalValue,
        height: RationalValue
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Ellipse mask in clip-local source pixel coordinates.
public struct ClipEllipseMask: Codable, Equatable, Sendable {
    /// Center X in source pixels.
    public let centerX: RationalValue

    /// Center Y in source pixels.
    public let centerY: RationalValue

    /// Horizontal radius in source pixels. Must be positive.
    public let radiusX: RationalValue

    /// Vertical radius in source pixels. Must be positive.
    public let radiusY: RationalValue

    /// Creates an ellipse mask.
    public init(
        centerX: RationalValue,
        centerY: RationalValue,
        radiusX: RationalValue,
        radiusY: RationalValue
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.radiusX = radiusX
        self.radiusY = radiusY
    }
}

/// Polygon/Bézier-point-list mask represented as a closed polygon for M5 rasterization.
public struct ClipPolygonMask: Codable, Equatable, Sendable {
    /// Ordered source-space points. M5 rasterization connects them as straight segments.
    public let points: [CanvasPoint]

    /// Creates a polygon mask.
    public init(points: [CanvasPoint]) {
        self.points = points
    }
}

/// Static mask shape evaluated for one render time.
public enum ClipMaskShape: Codable, Equatable, Sendable {
    /// Rectangle shape.
    case rectangle(ClipRectangleMask)

    /// Ellipse shape.
    case ellipse(ClipEllipseMask)

    /// Free-form polygon/Bézier point list.
    case polygon(ClipPolygonMask)
}

/// One static clip mask in source-space coordinates.
public struct ClipMask: Codable, Equatable, Sendable {
    /// Stable mask ID for edit commands.
    public let id: UUID

    /// Shape to rasterize.
    public let shape: ClipMaskShape

    /// Feather radius in source pixels. Zero is a hard edge.
    public let featherRadius: RationalValue

    /// Whether to invert this mask's matte before combining.
    public let invert: Bool

    /// How this mask combines with previous masks.
    public let combine: ClipMaskCombineOperation

    /// Creates a clip mask.
    public init(
        id: UUID,
        shape: ClipMaskShape,
        featherRadius: RationalValue = .zero,
        invert: Bool = false,
        combine: ClipMaskCombineOperation = .add
    ) {
        self.id = id
        self.shape = shape
        self.featherRadius = featherRadius
        self.invert = invert
        self.combine = combine
    }
}

/// Keyframable rectangular mask.
public struct AnimatableClipRectangleMask: Codable, Equatable, Sendable {
    /// Left edge.
    public let x: Animatable<RationalValue>

    /// Top edge.
    public let y: Animatable<RationalValue>

    /// Width.
    public let width: Animatable<RationalValue>

    /// Height.
    public let height: Animatable<RationalValue>

    /// Creates a keyframable rectangle mask.
    public init(
        x: Animatable<RationalValue>,
        y: Animatable<RationalValue>,
        width: Animatable<RationalValue>,
        height: Animatable<RationalValue>
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Creates a constant keyframable rectangle.
    public static func constant(_ rectangle: ClipRectangleMask) -> AnimatableClipRectangleMask {
        AnimatableClipRectangleMask(
            x: .constant(rectangle.x),
            y: .constant(rectangle.y),
            width: .constant(rectangle.width),
            height: .constant(rectangle.height)
        )
    }

    /// Evaluates at one timeline time.
    public func value(at time: RationalTime) -> ClipRectangleMask {
        ClipRectangleMask(
            x: x.value(at: time),
            y: y.value(at: time),
            width: width.value(at: time),
            height: height.value(at: time)
        )
    }
}

/// Keyframable ellipse mask.
public struct AnimatableClipEllipseMask: Codable, Equatable, Sendable {
    /// Center X.
    public let centerX: Animatable<RationalValue>

    /// Center Y.
    public let centerY: Animatable<RationalValue>

    /// Horizontal radius.
    public let radiusX: Animatable<RationalValue>

    /// Vertical radius.
    public let radiusY: Animatable<RationalValue>

    /// Creates a keyframable ellipse mask.
    public init(
        centerX: Animatable<RationalValue>,
        centerY: Animatable<RationalValue>,
        radiusX: Animatable<RationalValue>,
        radiusY: Animatable<RationalValue>
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.radiusX = radiusX
        self.radiusY = radiusY
    }

    /// Creates a constant keyframable ellipse.
    public static func constant(_ ellipse: ClipEllipseMask) -> AnimatableClipEllipseMask {
        AnimatableClipEllipseMask(
            centerX: .constant(ellipse.centerX),
            centerY: .constant(ellipse.centerY),
            radiusX: .constant(ellipse.radiusX),
            radiusY: .constant(ellipse.radiusY)
        )
    }

    /// Evaluates at one timeline time.
    public func value(at time: RationalTime) -> ClipEllipseMask {
        ClipEllipseMask(
            centerX: centerX.value(at: time),
            centerY: centerY.value(at: time),
            radiusX: radiusX.value(at: time),
            radiusY: radiusY.value(at: time)
        )
    }
}

/// Keyframable polygon/Bézier-point-list mask.
public struct AnimatableClipPolygonMask: Codable, Equatable, Sendable {
    /// Keyframable ordered source-space points.
    public let points: [Animatable<CanvasPoint>]

    /// Creates a keyframable polygon mask.
    public init(points: [Animatable<CanvasPoint>]) {
        self.points = points
    }

    /// Creates a constant keyframable polygon.
    public static func constant(_ polygon: ClipPolygonMask) -> AnimatableClipPolygonMask {
        AnimatableClipPolygonMask(points: polygon.points.map(Animatable.constant))
    }

    /// Evaluates at one timeline time.
    public func value(at time: RationalTime) -> ClipPolygonMask {
        ClipPolygonMask(points: points.map { point in point.value(at: time) })
    }
}

/// Keyframable mask shape.
public enum AnimatableClipMaskShape: Codable, Equatable, Sendable {
    /// Keyframable rectangle.
    case rectangle(AnimatableClipRectangleMask)

    /// Keyframable ellipse.
    case ellipse(AnimatableClipEllipseMask)

    /// Keyframable polygon/Bézier point list.
    case polygon(AnimatableClipPolygonMask)

    /// Creates a constant keyframable shape.
    public static func constant(_ shape: ClipMaskShape) -> AnimatableClipMaskShape {
        switch shape {
        case .rectangle(let rectangle):
            return .rectangle(.constant(rectangle))
        case .ellipse(let ellipse):
            return .ellipse(.constant(ellipse))
        case .polygon(let polygon):
            return .polygon(.constant(polygon))
        }
    }

    /// Evaluates at one timeline time.
    public func value(at time: RationalTime) -> ClipMaskShape {
        switch self {
        case .rectangle(let rectangle):
            return .rectangle(rectangle.value(at: time))
        case .ellipse(let ellipse):
            return .ellipse(ellipse.value(at: time))
        case .polygon(let polygon):
            return .polygon(polygon.value(at: time))
        }
    }
}

/// One keyframable clip mask.
public struct AnimatableClipMask: Codable, Equatable, Sendable {
    /// Stable mask ID.
    public let id: UUID

    /// Keyframable shape.
    public let shape: AnimatableClipMaskShape

    /// Keyframable feather radius.
    public let featherRadius: Animatable<RationalValue>

    /// Constant invert flag.
    public let invert: Bool

    /// Constant combine operation.
    public let combine: ClipMaskCombineOperation

    /// Creates a keyframable clip mask.
    public init(
        id: UUID,
        shape: AnimatableClipMaskShape,
        featherRadius: Animatable<RationalValue> = .constant(.zero),
        invert: Bool = false,
        combine: ClipMaskCombineOperation = .add
    ) {
        self.id = id
        self.shape = shape
        self.featherRadius = featherRadius
        self.invert = invert
        self.combine = combine
    }

    /// Creates a constant keyframable mask.
    public static func constant(_ mask: ClipMask) -> AnimatableClipMask {
        AnimatableClipMask(
            id: mask.id,
            shape: .constant(mask.shape),
            featherRadius: .constant(mask.featherRadius),
            invert: mask.invert,
            combine: mask.combine
        )
    }

    /// Evaluates at one timeline time.
    public func value(at time: RationalTime) -> ClipMask {
        ClipMask(
            id: id,
            shape: shape.value(at: time),
            featherRadius: featherRadius.value(at: time),
            invert: invert,
            combine: combine
        )
    }
}

enum ClipMaskValidator {
    static func errors(for masks: [ClipMask]) -> [ClipEffectsValidationError] {
        var errors: [ClipEffectsValidationError] = []
        appendMaskCountError(masks.count, to: &errors)
        for mask in masks {
            appendMaskErrors(mask, to: &errors)
        }
        return errors
    }

    static func errors(for masks: [AnimatableClipMask]) -> [ClipEffectsValidationError] {
        var errors: [ClipEffectsValidationError] = []
        appendMaskCountError(masks.count, to: &errors)
        for mask in masks {
            appendMaskErrors(mask.value(at: .zero), to: &errors)
            appendFeatherErrors(mask.featherRadius, maskID: mask.id, to: &errors)
            appendShapeKeyframeErrors(mask.shape, maskID: mask.id, to: &errors)
        }
        return errors
    }

    private static func appendMaskCountError(
        _ count: Int,
        to errors: inout [ClipEffectsValidationError]
    ) {
        if count > ClipMaskLimits.maximumMasksPerClip {
            errors.append(
                .clipMaskCountOutOfRange(
                    count: count,
                    maximum: ClipMaskLimits.maximumMasksPerClip
                )
            )
        }
    }

    private static func appendMaskErrors(
        _ mask: ClipMask,
        to errors: inout [ClipEffectsValidationError]
    ) {
        if mask.featherRadius.isNegative {
            errors.append(.clipMaskFeatherRadiusNegative(maskID: mask.id, mask.featherRadius))
        }
        appendShapeErrors(mask.shape, maskID: mask.id, to: &errors)
    }

    private static func appendShapeErrors(
        _ shape: ClipMaskShape,
        maskID: UUID,
        to errors: inout [ClipEffectsValidationError]
    ) {
        switch shape {
        case .rectangle(let rectangle):
            if !isPositive(rectangle.width) || !isPositive(rectangle.height) {
                errors.append(.clipMaskRectangleSizeInvalid(maskID: maskID))
            }
        case .ellipse(let ellipse):
            if !isPositive(ellipse.radiusX) || !isPositive(ellipse.radiusY) {
                errors.append(.clipMaskEllipseRadiusInvalid(maskID: maskID))
            }
        case .polygon(let polygon):
            appendPolygonPointCountError(polygon.points.count, maskID: maskID, to: &errors)
        }
    }

    private static func appendFeatherErrors(
        _ featherRadius: Animatable<RationalValue>,
        maskID: UUID,
        to errors: inout [ClipEffectsValidationError]
    ) {
        for keyframe in featherRadius.keyframes where keyframe.value.isNegative {
            errors.append(.clipMaskFeatherRadiusNegative(maskID: maskID, keyframe.value))
        }
    }

    private static func appendShapeKeyframeErrors(
        _ shape: AnimatableClipMaskShape,
        maskID: UUID,
        to errors: inout [ClipEffectsValidationError]
    ) {
        switch shape {
        case .rectangle(let rectangle):
            appendPositiveErrors(rectangle.width, maskID: maskID, to: &errors) {
                .clipMaskRectangleSizeInvalid(maskID: $0)
            }
            appendPositiveErrors(rectangle.height, maskID: maskID, to: &errors) {
                .clipMaskRectangleSizeInvalid(maskID: $0)
            }
        case .ellipse(let ellipse):
            appendPositiveErrors(ellipse.radiusX, maskID: maskID, to: &errors) {
                .clipMaskEllipseRadiusInvalid(maskID: $0)
            }
            appendPositiveErrors(ellipse.radiusY, maskID: maskID, to: &errors) {
                .clipMaskEllipseRadiusInvalid(maskID: $0)
            }
        case .polygon(let polygon):
            appendPolygonPointCountError(polygon.points.count, maskID: maskID, to: &errors)
        }
    }

    private static func appendPositiveErrors(
        _ value: Animatable<RationalValue>,
        maskID: UUID,
        to errors: inout [ClipEffectsValidationError],
        error: (UUID) -> ClipEffectsValidationError
    ) {
        for keyframe in value.keyframes where !isPositive(keyframe.value) {
            errors.append(error(maskID))
        }
    }

    private static func appendPolygonPointCountError(
        _ count: Int,
        maskID: UUID,
        to errors: inout [ClipEffectsValidationError]
    ) {
        if count < 3 || count > ClipMaskLimits.maximumPolygonPointCount {
            errors.append(
                .clipMaskPolygonPointCountInvalid(
                    maskID: maskID,
                    count: count,
                    maximum: ClipMaskLimits.maximumPolygonPointCount
                )
            )
        }
    }

    private static func isPositive(_ value: RationalValue) -> Bool {
        value.numerator > 0
    }
}
