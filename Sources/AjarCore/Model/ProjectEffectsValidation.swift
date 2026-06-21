// SPDX-License-Identifier: GPL-3.0-or-later

extension ProjectValidator {
    static func validateClipEffects(
        _ item: TimelineItem,
        context: TrackContext,
        state: inout ValidationState
    ) {
        guard case .clip(let clip) = item else {
            return
        }

        for error in ClipEffectsValidator.errors(for: clip.effects) {
            state.errors.append(
                .invalidClipEffects(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: clip.id,
                    error: error
                )
            )
        }
    }
}
