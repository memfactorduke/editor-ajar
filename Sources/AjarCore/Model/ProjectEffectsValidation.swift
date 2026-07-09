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

        let staticErrors = clip.effectsAnimation.baseEffects == clip.effects
            ? []
            : ClipEffectsValidator.errors(for: clip.effects)
        let errors = staticErrors + ClipEffectsValidator.errors(for: clip.effectsAnimation)
        for error in errors {
            state.errors.append(
                .invalidClipEffects(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: clip.id,
                    error: error
                )
            )
        }

        let stackParityMatches = clip.effectStackAnimation.baseStack == clip.effectStack
        // Mirror the dual static/animatable pattern used for ClipEffects: when base and
        // snapshot diverge, validate both; always require parity for the FR-FX-003 stack
        // so hand-edited JSON with mismatched IDs/order/kinds/enabled/base params fails.
        if !stackParityMatches {
            state.errors.append(
                .invalidClipEffectStack(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: clip.id,
                    error: .staticAnimationParityMismatch
                )
            )
        }
        var staticStackErrors: [ClipEffectStackValidationError] = []
        if !stackParityMatches {
            staticStackErrors = ClipEffectStackValidator.errors(for: clip.effectStack)
        }
        let stackErrors =
            staticStackErrors + ClipEffectStackValidator.errors(for: clip.effectStackAnimation)
        for error in stackErrors {
            state.errors.append(
                .invalidClipEffectStack(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: clip.id,
                    error: error
                )
            )
        }
    }
}
