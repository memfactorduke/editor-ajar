// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    static func copying(
        _ clip: Clip,
        source: ClipSource? = nil,
        sourceRange: TimeRange? = nil,
        timelineRange: TimeRange? = nil,
        name: String? = nil,
        linkGroupID: UUID?? = nil,
        transform: ClipTransform? = nil,
        transformAnimation: AnimatableClipTransform? = nil,
        effects: ClipEffects? = nil,
        effectsAnimation: AnimatableClipEffects? = nil,
        effectStack: ClipEffectStack? = nil,
        effectStackAnimation: AnimatableClipEffectStack? = nil,
        audioMix: ClipAudioMix? = nil,
        speed: RationalValue? = nil,
        reverse: Bool? = nil,
        freezeFrame: Bool? = nil,
        timeRemap: ClipTimeRemap?? = nil,
        frameSampling: ClipFrameSamplingMode? = nil
    ) -> Clip {
        let replacementTransform = transform ?? clip.transform
        let replacementAnimation = transformAnimation
            ?? (transform == nil ? clip.transformAnimation : .constant(replacementTransform))
        let replacementEffects = effects ?? clip.effects
        let replacementEffectsAnimation = effectsAnimation
            ?? (effects == nil
                ? clip.effectsAnimation
                : clip.effectsAnimation.replacingChangedEffects(
                    from: clip.effects,
                    to: replacementEffects
                ))
        let replacementEffectStack = effectStack ?? clip.effectStack
        let replacementEffectStackAnimation = effectStackAnimation
            ?? (effectStack == nil
                ? clip.effectStackAnimation
                : clip.effectStackAnimation.replacingChangedNodes(
                    from: clip.effectStack,
                    to: replacementEffectStack
                ))
        return Clip(
            id: clip.id,
            source: source ?? clip.source,
            sourceRange: sourceRange ?? clip.sourceRange,
            timelineRange: timelineRange ?? clip.timelineRange,
            kind: clip.kind,
            name: name ?? clip.name,
            linkGroupID: linkGroupID ?? clip.linkGroupID,
            transform: replacementTransform,
            transformAnimation: replacementAnimation,
            effects: replacementEffects,
            effectsAnimation: replacementEffectsAnimation,
            effectStack: replacementEffectStack,
            effectStackAnimation: replacementEffectStackAnimation,
            audioMix: audioMix ?? clip.audioMix,
            speed: speed ?? clip.speed,
            reverse: reverse ?? clip.reverse,
            freezeFrame: freezeFrame ?? clip.freezeFrame,
            timeRemap: timeRemap ?? clip.timeRemap,
            frameSampling: frameSampling ?? clip.frameSampling
        )
    }
}
