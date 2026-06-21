// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct TransformKeyframeEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let parameter: ClipTransformParameter
        let keyframe: ClipTransformKeyframe
    }

    struct MoveTransformKeyframeEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let parameter: ClipTransformParameter
        let fromTime: RationalTime
        let keyframe: ClipTransformKeyframe
    }

    struct DeleteTransformKeyframeEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let parameter: ClipTransformParameter
        let time: RationalTime
    }

    static func addClipTransformKeyframe(
        _ edit: TransformKeyframeEdit,
        in project: Project
    ) throws -> Project {
        try replacingTransformAnimation(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            try validateKeyframe(
                edit.keyframe,
                parameter: edit.parameter,
                clip: clip,
                frame: project.settings.resolution
            )
            return try addingKeyframe(
                edit.keyframe,
                parameter: edit.parameter,
                to: clip.transformAnimation,
                clipID: edit.clipID
            )
        }
    }

    static func moveClipTransformKeyframe(
        _ edit: MoveTransformKeyframeEdit,
        in project: Project
    ) throws -> Project {
        try replacingTransformAnimation(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            try validateKeyframe(
                edit.keyframe,
                parameter: edit.parameter,
                clip: clip,
                frame: project.settings.resolution
            )
            return try movingKeyframe(
                from: edit.fromTime,
                to: edit.keyframe,
                parameter: edit.parameter,
                in: clip.transformAnimation,
                clipID: edit.clipID
            )
        }
    }

    static func deleteClipTransformKeyframe(
        _ edit: DeleteTransformKeyframeEdit,
        in project: Project
    ) throws -> Project {
        try replacingTransformAnimation(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            try deletingKeyframe(
                at: edit.time,
                parameter: edit.parameter,
                from: clip.transformAnimation,
                clipID: edit.clipID
            )
        }
    }

    static func replacingTransformAnimation(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        in project: Project,
        update: (Clip) throws -> AnimatableClipTransform
    ) throws -> Project {
        try replacingTrack(trackID, sequenceID: sequenceID, in: project) { track in
            var items = track.items
            guard
                let index = clipIndex(clipID, in: items),
                case .clip(let clip) = items[index]
            else {
                throw EditReducerError.clipNotFound(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID
                )
            }

            items[index] = .clip(copying(clip, transformAnimation: try update(clip)))
            return copying(track, items: items)
        }
    }

    static func validateKeyframe(
        _ keyframe: ClipTransformKeyframe,
        parameter: ClipTransformParameter,
        clip: Clip,
        frame: PixelDimensions
    ) throws {
        try validateKeyframeParameter(keyframe, parameter: parameter, clipID: clip.id)
        try validateKeyframeTime(keyframe.time, parameter: parameter, clip: clip)
        try validateKeyframeTransform(
            keyframe.value.applied(to: clip.transform),
            keyframe: keyframe,
            parameter: parameter,
            clipID: clip.id,
            frame: frame
        )
    }

    static func validateKeyframeTransform(
        _ transform: ClipTransform,
        keyframe: ClipTransformKeyframe,
        parameter: ClipTransformParameter,
        clipID: UUID,
        frame: PixelDimensions
    ) throws {
        guard let error = ClipTransformValidator.errors(for: transform, frame: frame).first else {
            return
        }

        throw EditReducerError.invalidEdit(
            .invalidClipTransformKeyframe(
                clipID: clipID,
                parameter: parameter,
                time: keyframe.time,
                error: error
            )
        )
    }

    static func validateKeyframeParameter(
        _ keyframe: ClipTransformKeyframe,
        parameter: ClipTransformParameter,
        clipID: UUID
    ) throws {
        guard keyframe.value.parameter == parameter else {
            throw EditReducerError.invalidEdit(
                .transformKeyframeValueMismatch(
                    clipID: clipID,
                    parameter: parameter,
                    value: keyframe.value
                )
            )
        }
    }

    static func validateKeyframeTime(
        _ time: RationalTime,
        parameter: ClipTransformParameter,
        clip: Clip
    ) throws {
        let contains: Bool
        do {
            contains = try clip.timelineRange.contains(time)
        } catch let error as RationalTimeError {
            throw EditReducerError.timeArithmeticFailed(error)
        }
        guard contains else {
            throw EditReducerError.invalidEdit(
                .transformKeyframeTimeOutsideClip(
                    clipID: clip.id,
                    parameter: parameter,
                    time: time,
                    clipRange: clip.timelineRange
                )
            )
        }
    }

    static func addingKeyframe(
        _ keyframe: ClipTransformKeyframe,
        parameter: ClipTransformParameter,
        to animation: AnimatableClipTransform,
        clipID: UUID
    ) throws -> AnimatableClipTransform {
        switch parameter {
        case .position:
            return animation.replacing(
                position: try addingTypedKeyframe(
                    positionKeyframe(keyframe, clipID: clipID, parameter: parameter),
                    to: animation.position,
                    clipID: clipID,
                    parameter: parameter
                )
            )
        case .scale:
            return animation.replacing(
                scale: try addingTypedKeyframe(
                    scaleKeyframe(keyframe, clipID: clipID, parameter: parameter),
                    to: animation.scale,
                    clipID: clipID,
                    parameter: parameter
                )
            )
        case .anchorPoint:
            return animation.replacing(
                anchorPoint: try addingTypedKeyframe(
                    anchorPointKeyframe(keyframe, clipID: clipID, parameter: parameter),
                    to: animation.anchorPoint,
                    clipID: clipID,
                    parameter: parameter
                )
            )
        case .rotation:
            return animation.replacing(
                rotation: try addingTypedKeyframe(
                    rotationKeyframe(keyframe, clipID: clipID, parameter: parameter),
                    to: animation.rotation,
                    clipID: clipID,
                    parameter: parameter
                )
            )
        case .opacity:
            return animation.replacing(
                opacity: try addingTypedKeyframe(
                    opacityKeyframe(keyframe, clipID: clipID, parameter: parameter),
                    to: animation.opacity,
                    clipID: clipID,
                    parameter: parameter
                )
            )
        case .crop:
            return animation.replacing(
                crop: try addingTypedKeyframe(
                    cropKeyframe(keyframe, clipID: clipID, parameter: parameter),
                    to: animation.crop,
                    clipID: clipID,
                    parameter: parameter
                )
            )
        }
    }

    static func movingKeyframe(
        from time: RationalTime,
        to keyframe: ClipTransformKeyframe,
        parameter: ClipTransformParameter,
        in animation: AnimatableClipTransform,
        clipID: UUID
    ) throws -> AnimatableClipTransform {
        let withoutOriginal = try deletingKeyframe(
            at: time,
            parameter: parameter,
            from: animation,
            clipID: clipID
        )
        return try addingKeyframe(
            keyframe,
            parameter: parameter,
            to: withoutOriginal,
            clipID: clipID
        )
    }

    static func deletingKeyframe(
        at time: RationalTime,
        parameter: ClipTransformParameter,
        from animation: AnimatableClipTransform,
        clipID: UUID
    ) throws -> AnimatableClipTransform {
        switch parameter {
        case .position:
            return animation.replacing(
                position: try deletingTypedKeyframe(
                    at: time,
                    from: animation.position,
                    clipID: clipID,
                    parameter: parameter
                )
            )
        case .scale:
            return animation.replacing(
                scale: try deletingTypedKeyframe(
                    at: time,
                    from: animation.scale,
                    clipID: clipID,
                    parameter: parameter
                )
            )
        case .anchorPoint:
            return animation.replacing(
                anchorPoint: try deletingTypedKeyframe(
                    at: time,
                    from: animation.anchorPoint,
                    clipID: clipID,
                    parameter: parameter
                )
            )
        case .rotation:
            return animation.replacing(
                rotation: try deletingTypedKeyframe(
                    at: time,
                    from: animation.rotation,
                    clipID: clipID,
                    parameter: parameter
                )
            )
        case .opacity:
            return animation.replacing(
                opacity: try deletingTypedKeyframe(
                    at: time,
                    from: animation.opacity,
                    clipID: clipID,
                    parameter: parameter
                )
            )
        case .crop:
            return animation.replacing(
                crop: try deletingTypedKeyframe(
                    at: time,
                    from: animation.crop,
                    clipID: clipID,
                    parameter: parameter
                )
            )
        }
    }

    static func addingTypedKeyframe<Value>(
        _ keyframe: Keyframe<Value>,
        to animation: Animatable<Value>,
        clipID: UUID,
        parameter: ClipTransformParameter
    ) throws -> Animatable<Value>
        where Value: Codable & Equatable & Sendable & Interpolatable {
        guard !animation.keyframes.contains(where: { $0.time == keyframe.time }) else {
            throw EditReducerError.invalidEdit(
                .duplicateTransformKeyframeTime(
                    clipID: clipID,
                    parameter: parameter,
                    time: keyframe.time
                )
            )
        }

        return try Animatable(
            base: animation.base,
            keyframes: (animation.keyframes + [keyframe]).sorted { $0.time < $1.time }
        )
    }

    static func deletingTypedKeyframe<Value>(
        at time: RationalTime,
        from animation: Animatable<Value>,
        clipID: UUID,
        parameter: ClipTransformParameter
    ) throws -> Animatable<Value>
        where Value: Codable & Equatable & Sendable & Interpolatable {
        guard let index = animation.keyframes.firstIndex(where: { $0.time == time }) else {
            throw EditReducerError.invalidEdit(
                .transformKeyframeNotFound(clipID: clipID, parameter: parameter, time: time)
            )
        }

        var keyframes = animation.keyframes
        keyframes.remove(at: index)
        return try Animatable(base: animation.base, keyframes: keyframes)
    }

    static func positionKeyframe(
        _ keyframe: ClipTransformKeyframe,
        clipID: UUID,
        parameter: ClipTransformParameter
    ) throws -> Keyframe<CanvasPoint> {
        guard case .position(let value) = keyframe.value else {
            throw valueMismatch(clipID: clipID, parameter: parameter, value: keyframe.value)
        }
        return Keyframe(time: keyframe.time, value: value, interpolation: keyframe.interpolation)
    }

    static func scaleKeyframe(
        _ keyframe: ClipTransformKeyframe,
        clipID: UUID,
        parameter: ClipTransformParameter
    ) throws -> Keyframe<ClipScale> {
        guard case .scale(let value) = keyframe.value else {
            throw valueMismatch(clipID: clipID, parameter: parameter, value: keyframe.value)
        }
        return Keyframe(time: keyframe.time, value: value, interpolation: keyframe.interpolation)
    }

    static func anchorPointKeyframe(
        _ keyframe: ClipTransformKeyframe,
        clipID: UUID,
        parameter: ClipTransformParameter
    ) throws -> Keyframe<CanvasPoint> {
        guard case .anchorPoint(let value) = keyframe.value else {
            throw valueMismatch(clipID: clipID, parameter: parameter, value: keyframe.value)
        }
        return Keyframe(time: keyframe.time, value: value, interpolation: keyframe.interpolation)
    }

    static func rotationKeyframe(
        _ keyframe: ClipTransformKeyframe,
        clipID: UUID,
        parameter: ClipTransformParameter
    ) throws -> Keyframe<ClipRotation> {
        guard case .rotation(let value) = keyframe.value else {
            throw valueMismatch(clipID: clipID, parameter: parameter, value: keyframe.value)
        }
        return Keyframe(time: keyframe.time, value: value, interpolation: keyframe.interpolation)
    }

    static func opacityKeyframe(
        _ keyframe: ClipTransformKeyframe,
        clipID: UUID,
        parameter: ClipTransformParameter
    ) throws -> Keyframe<RationalValue> {
        guard case .opacity(let value) = keyframe.value else {
            throw valueMismatch(clipID: clipID, parameter: parameter, value: keyframe.value)
        }
        return Keyframe(time: keyframe.time, value: value, interpolation: keyframe.interpolation)
    }

    static func cropKeyframe(
        _ keyframe: ClipTransformKeyframe,
        clipID: UUID,
        parameter: ClipTransformParameter
    ) throws -> Keyframe<ClipCropInsets> {
        guard case .crop(let value) = keyframe.value else {
            throw valueMismatch(clipID: clipID, parameter: parameter, value: keyframe.value)
        }
        return Keyframe(time: keyframe.time, value: value, interpolation: keyframe.interpolation)
    }

    static func valueMismatch(
        clipID: UUID,
        parameter: ClipTransformParameter,
        value: ClipTransformKeyframeValue
    ) -> EditReducerError {
        .invalidEdit(
            .transformKeyframeValueMismatch(
                clipID: clipID,
                parameter: parameter,
                value: value
            )
        )
    }
}
