// SPDX-License-Identifier: GPL-3.0-or-later

extension ProjectValidator {
    static func validateClipSpeed(
        _ item: TimelineItem,
        context: TrackContext,
        state: inout ValidationState
    ) {
        guard case .clip(let clip) = item else {
            return
        }

        if let error = Clip.validateSpeed(clip.speed) {
            state.errors.append(
                .invalidClipSpeed(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: clip.id,
                    error: error
                )
            )
        }

        if let error = clip.validateTimeRemap() {
            state.errors.append(
                .invalidClipTimeRemap(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: clip.id,
                    error: error
                )
            )
        }

        if let error = clip.validateAudioRetime() {
            state.errors.append(
                .invalidClipAudioRetime(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: clip.id,
                    error: error
                )
            )
        }
    }
}
