// SPDX-License-Identifier: GPL-3.0-or-later

/// Clip transform parameter that can hold keyframes.
public enum ClipTransformParameter: String, Codable, CaseIterable, Equatable, Sendable {
    /// Position X/Y.
    case position

    /// Scale X/Y.
    case scale

    /// Transform anchor point.
    case anchorPoint

    /// Rotation.
    case rotation

    /// Opacity.
    case opacity

    /// Crop insets.
    case crop
}

/// Type-erased transform keyframe value used by edit commands.
public enum ClipTransformKeyframeValue: Codable, Equatable, Sendable {
    /// Position value.
    case position(CanvasPoint)

    /// Scale value.
    case scale(ClipScale)

    /// Anchor point value.
    case anchorPoint(CanvasPoint)

    /// Rotation value.
    case rotation(ClipRotation)

    /// Opacity value.
    case opacity(RationalValue)

    /// Crop value.
    case crop(ClipCropInsets)

    /// Parameter represented by this value.
    public var parameter: ClipTransformParameter {
        switch self {
        case .position:
            return .position
        case .scale:
            return .scale
        case .anchorPoint:
            return .anchorPoint
        case .rotation:
            return .rotation
        case .opacity:
            return .opacity
        case .crop:
            return .crop
        }
    }

    func applied(to transform: ClipTransform) -> ClipTransform {
        switch self {
        case .position(let value):
            return transform.replacing(position: value)
        case .scale(let value):
            return transform.replacing(scale: value)
        case .anchorPoint(let value):
            return transform.replacing(anchorPoint: value)
        case .rotation(let value):
            return transform.replacing(rotation: value)
        case .opacity(let value):
            return transform.replacing(opacity: value)
        case .crop(let value):
            return transform.replacing(crop: value)
        }
    }
}

/// Type-erased transform keyframe payload used by edit commands.
public struct ClipTransformKeyframe: Codable, Equatable, Sendable {
    /// Keyframe time.
    public let time: RationalTime

    /// Keyframe value.
    public let value: ClipTransformKeyframeValue

    /// Interpolation for the segment that starts at this keyframe.
    public let interpolation: InterpolationMode

    /// Creates a transform keyframe payload.
    public init(
        time: RationalTime,
        value: ClipTransformKeyframeValue,
        interpolation: InterpolationMode
    ) {
        self.time = time
        self.value = value
        self.interpolation = interpolation
    }
}

/// Keyframable transform parameters for FR-XFORM-008.
public struct AnimatableClipTransform: Codable, Equatable, Sendable {
    /// Keyframable position.
    public let position: Animatable<CanvasPoint>

    /// Keyframable scale.
    public let scale: Animatable<ClipScale>

    /// Keyframable anchor point.
    public let anchorPoint: Animatable<CanvasPoint>

    /// Keyframable rotation.
    public let rotation: Animatable<ClipRotation>

    /// Keyframable opacity.
    public let opacity: Animatable<RationalValue>

    /// Keyframable crop.
    public let crop: Animatable<ClipCropInsets>

    /// Constant blend mode.
    public let blendMode: ClipBlendMode

    /// Constant flip state.
    public let flip: ClipFlip

    /// Identity keyframable transform.
    public static let identity = AnimatableClipTransform.constant(.identity)

    /// Creates keyframable transform parameters.
    public init(
        position: Animatable<CanvasPoint> = .constant(.zero),
        scale: Animatable<ClipScale> = .constant(.identity),
        anchorPoint: Animatable<CanvasPoint> = .constant(.zero),
        rotation: Animatable<ClipRotation> = .constant(.zero),
        opacity: Animatable<RationalValue> = .constant(.one),
        crop: Animatable<ClipCropInsets> = .constant(.zero),
        blendMode: ClipBlendMode = .normal,
        flip: ClipFlip = .none
    ) {
        self.position = position
        self.scale = scale
        self.anchorPoint = anchorPoint
        self.rotation = rotation
        self.opacity = opacity
        self.crop = crop
        self.blendMode = blendMode
        self.flip = flip
    }

    /// Creates a keyframable transform with constant values from an evaluated transform.
    public static func constant(_ transform: ClipTransform) -> AnimatableClipTransform {
        AnimatableClipTransform(
            position: .constant(transform.position),
            scale: .constant(transform.scale),
            anchorPoint: .constant(transform.anchorPoint),
            rotation: .constant(transform.rotation),
            opacity: .constant(transform.opacity),
            crop: .constant(transform.crop),
            blendMode: transform.blendMode,
            flip: transform.flip
        )
    }

    /// Evaluates the keyframable transform at an exact timeline time.
    public func value(at time: RationalTime) -> ClipTransform {
        ClipTransform(
            position: position.value(at: time),
            scale: scale.value(at: time),
            anchorPoint: anchorPoint.value(at: time),
            rotation: rotation.value(at: time),
            opacity: opacity.value(at: time),
            blendMode: blendMode,
            crop: crop.value(at: time),
            flip: flip
        )
    }

    /// Base transform used when no keyframes exist on a parameter.
    public var baseTransform: ClipTransform {
        ClipTransform(
            position: position.base,
            scale: scale.base,
            anchorPoint: anchorPoint.base,
            rotation: rotation.base,
            opacity: opacity.base,
            blendMode: blendMode,
            crop: crop.base,
            flip: flip
        )
    }

    var keyframes: [ClipTransformKeyframe] {
        position.keyframes.map { keyframe in
            ClipTransformKeyframe(
                time: keyframe.time,
                value: .position(keyframe.value),
                interpolation: keyframe.interpolation
            )
        } + scale.keyframes.map { keyframe in
            ClipTransformKeyframe(
                time: keyframe.time,
                value: .scale(keyframe.value),
                interpolation: keyframe.interpolation
            )
        } + anchorPoint.keyframes.map { keyframe in
            ClipTransformKeyframe(
                time: keyframe.time,
                value: .anchorPoint(keyframe.value),
                interpolation: keyframe.interpolation
            )
        } + rotation.keyframes.map { keyframe in
            ClipTransformKeyframe(
                time: keyframe.time,
                value: .rotation(keyframe.value),
                interpolation: keyframe.interpolation
            )
        } + opacity.keyframes.map { keyframe in
            ClipTransformKeyframe(
                time: keyframe.time,
                value: .opacity(keyframe.value),
                interpolation: keyframe.interpolation
            )
        } + crop.keyframes.map { keyframe in
            ClipTransformKeyframe(
                time: keyframe.time,
                value: .crop(keyframe.value),
                interpolation: keyframe.interpolation
            )
        }
    }

    func replacing(
        position: Animatable<CanvasPoint>? = nil,
        scale: Animatable<ClipScale>? = nil,
        anchorPoint: Animatable<CanvasPoint>? = nil,
        rotation: Animatable<ClipRotation>? = nil,
        opacity: Animatable<RationalValue>? = nil,
        crop: Animatable<ClipCropInsets>? = nil
    ) -> AnimatableClipTransform {
        AnimatableClipTransform(
            position: position ?? self.position,
            scale: scale ?? self.scale,
            anchorPoint: anchorPoint ?? self.anchorPoint,
            rotation: rotation ?? self.rotation,
            opacity: opacity ?? self.opacity,
            crop: crop ?? self.crop,
            blendMode: blendMode,
            flip: flip
        )
    }
}

extension ClipTransform {
    func replacing(
        position: CanvasPoint? = nil,
        scale: ClipScale? = nil,
        anchorPoint: CanvasPoint? = nil,
        rotation: ClipRotation? = nil,
        opacity: RationalValue? = nil,
        crop: ClipCropInsets? = nil
    ) -> ClipTransform {
        ClipTransform(
            position: position ?? self.position,
            scale: scale ?? self.scale,
            anchorPoint: anchorPoint ?? self.anchorPoint,
            rotation: rotation ?? self.rotation,
            opacity: opacity ?? self.opacity,
            blendMode: blendMode,
            crop: crop ?? self.crop,
            flip: flip
        )
    }
}

extension CanvasPoint: Interpolatable {
    /// Returns an interpolated canvas point.
    public func lerp(to target: CanvasPoint, fraction: Double) -> CanvasPoint {
        CanvasPoint(
            x: x.lerp(to: target.x, fraction: fraction),
            y: y.lerp(to: target.y, fraction: fraction)
        )
    }
}

extension ClipScale: Interpolatable {
    /// Returns an interpolated per-axis scale.
    public func lerp(to target: ClipScale, fraction: Double) -> ClipScale {
        ClipScale(
            x: x.lerp(to: target.x, fraction: fraction),
            y: y.lerp(to: target.y, fraction: fraction)
        )
    }
}

extension ClipRotation: Interpolatable {
    /// Returns an interpolated rotation in total degrees.
    public func lerp(to target: ClipRotation, fraction: Double) -> ClipRotation {
        let startDegrees = degrees.doubleValue + (Double(revolutions) * 360)
        let targetDegrees = target.degrees.doubleValue + (Double(target.revolutions) * 360)
        return ClipRotation(
            degrees: RationalValue.approximating(
                startDegrees + ((targetDegrees - startDegrees) * fraction)
            )
        )
    }
}

extension ClipCropInsets: Interpolatable {
    /// Returns interpolated crop insets rounded to whole canvas units.
    public func lerp(to target: ClipCropInsets, fraction: Double) -> ClipCropInsets {
        ClipCropInsets(
            left: interpolatedInt64(left, target.left, fraction: fraction),
            top: interpolatedInt64(top, target.top, fraction: fraction),
            right: interpolatedInt64(right, target.right, fraction: fraction),
            bottom: interpolatedInt64(bottom, target.bottom, fraction: fraction)
        )
    }
}

private func interpolatedInt64(_ start: Int64, _ end: Int64, fraction: Double) -> Int64 {
    let value = Double(start) + ((Double(end) - Double(start)) * fraction)
    guard value.isFinite else {
        return start
    }
    guard value >= Double(Int64.min), value <= Double(Int64.max) else {
        return value < 0 ? Int64.min : Int64.max
    }
    return Int64(value.rounded())
}
