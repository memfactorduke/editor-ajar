// SPDX-License-Identifier: GPL-3.0-or-later

extension ProjectValidator {
    static func validateClipTransform(
        _ item: TimelineItem,
        context: TrackContext,
        state: inout ValidationState
    ) {
        guard case .clip(let clip) = item else {
            return
        }

        for error in ClipTransformValidator.errors(for: clip.transform, frame: state.frame) {
            state.errors.append(
                .invalidClipTransform(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: clip.id,
                    error: error
                )
            )
        }
        validateTransformKeyframes(clip, context: context, state: &state)
    }

    static func validateTransformKeyframes(
        _ clip: Clip,
        context: TrackContext,
        state: inout ValidationState
    ) {
        for keyframe in clip.transformAnimation.keyframes {
            validateKeyframeTime(
                keyframe.time,
                parameter: keyframe.value.parameter,
                clip: clip,
                context: context,
                state: &state
            )
            validateKeyframeTransform(keyframe, clip: clip, context: context, state: &state)
        }
    }

    static func validateKeyframeTransform(
        _ keyframe: ClipTransformKeyframe,
        clip: Clip,
        context: TrackContext,
        state: inout ValidationState
    ) {
        let transform = keyframe.value.applied(to: clip.transform)
        for error in ClipTransformValidator.errors(for: transform, frame: state.frame) {
            state.errors.append(
                .invalidClipTransformKeyframe(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: clip.id,
                    parameter: keyframe.value.parameter,
                    time: keyframe.time,
                    error: error
                )
            )
        }
    }

    static func validateKeyframeTime(
        _ time: RationalTime,
        parameter: ClipTransformParameter,
        clip: Clip,
        context: TrackContext,
        state: inout ValidationState
    ) {
        do {
            if !(try clip.timelineRange.contains(time)) {
                state.errors.append(
                    .transformKeyframeTimeOutsideClip(
                        sequenceID: context.sequenceID,
                        trackID: context.trackID,
                        clipID: clip.id,
                        parameter: parameter,
                        time: time,
                        clipRange: clip.timelineRange
                    )
                )
            }
        } catch let error as RationalTimeError {
            state.errors.append(
                .invalidTimeRange(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    itemIndex: 0,
                    error: error
                )
            )
        } catch {
            return
        }
    }
}
