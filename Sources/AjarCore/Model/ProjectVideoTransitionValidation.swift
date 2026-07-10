// SPDX-License-Identifier: GPL-3.0-or-later

extension ProjectValidator {
    /// Validates the ADR-0016 §5 video transition pair taxonomy and source-handle rule
    /// per video track (FR-FX-001).
    static func validateTrackVideoTransitions(
        _ track: Track,
        context: TrackContext,
        state: inout ValidationState
    ) {
        guard context.trackKind == .video else {
            return
        }

        let transitionErrors = ClipVideoTransitionValidator.errors(
            in: track.items,
            mediaDurationsByID: state.mediaDurationsByID
        )
        for error in transitionErrors {
            state.errors.append(
                .invalidClipVideoTransition(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: error.clipID,
                    error: error
                )
            )
        }
    }
}
