// SPDX-License-Identifier: GPL-3.0-or-later

extension ProjectValidator {
    static func validateTrackCompositing(
        _ track: Track,
        context: TrackContext,
        state: inout ValidationState
    ) {
        if isOutsideUnitInterval(track.opacity.base) {
            state.errors.append(
                .invalidTrackOpacity(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    value: track.opacity.base
                )
            )
        }

        for keyframe in track.opacity.keyframes where isOutsideUnitInterval(keyframe.value) {
            state.errors.append(
                .invalidTrackOpacityKeyframe(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    time: keyframe.time,
                    value: keyframe.value
                )
            )
        }
    }

    static func isOutsideUnitInterval(_ value: RationalValue) -> Bool {
        value.isNegative || value.isGreaterThanOne
    }
}
