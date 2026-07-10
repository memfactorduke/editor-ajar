// SPDX-License-Identifier: GPL-3.0-or-later

// Absolute keyframe-time rebasing when a clip's timeline placement shifts (issue #198).
// Keyframes store ABSOLUTE sequence times and evaluate at sequence time; a body move of
// `timelineRange` must translate every keyframe by the same delta so the clip-relative
// animation shape is preserved. Blade already splits at absolute cuts via `bladed(at:)`
// and is intentionally left alone. The live edit path always goes through
// `mappingKeyframeTimes` (via `EditReducer.relocating` / `remappingAnimationTimes`).

extension AnimatableClipTransform {
    /// Maps every keyframed transform parameter time through `transform`.
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipTransform {
        AnimatableClipTransform(
            position: try position.mappingKeyframeTimes(transform),
            scale: try scale.mappingKeyframeTimes(transform),
            anchorPoint: try anchorPoint.mappingKeyframeTimes(transform),
            rotation: try rotation.mappingKeyframeTimes(transform),
            opacity: try opacity.mappingKeyframeTimes(transform),
            crop: try crop.mappingKeyframeTimes(transform),
            blendMode: blendMode,
            flip: flip
        )
    }
}

extension AnimatableClipEffects {
    /// Maps every keyframed legacy effects parameter time through `transform`.
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipEffects {
        AnimatableClipEffects(
            chromaKey: try chromaKey.mappingKeyframeTimes(transform),
            lumaKey: try lumaKey.mappingKeyframeTimes(transform),
            colorCorrection: try colorCorrection.mappingKeyframeTimes(transform),
            masks: try masks.map { mask in try mask.mappingKeyframeTimes(transform) }
        )
    }
}

extension AnimatableClipEffectStack {
    /// Maps every keyframed stack parameter time through `transform`.
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipEffectStack {
        AnimatableClipEffectStack(
            nodes: try nodes.map { node in try node.mappingKeyframeTimes(transform) }
        )
    }
}

extension AnimatableClipEffectNode {
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipEffectNode {
        AnimatableClipEffectNode(
            id: id,
            enabled: enabled,
            definition: try definition.mappingKeyframeTimes(transform)
        )
    }
}

extension AnimatableClipChromaKeySettings {
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipChromaKeySettings {
        AnimatableClipChromaKeySettings(
            enabled: enabled,
            keyColor: keyColor,
            tolerance: try tolerance.mappingKeyframeTimes(transform),
            edgeSoftness: try edgeSoftness.mappingKeyframeTimes(transform),
            spillSuppression: try spillSuppression.mappingKeyframeTimes(transform),
            choke: try choke.mappingKeyframeTimes(transform),
            viewMatte: viewMatte
        )
    }
}

extension AnimatableClipLumaKeySettings {
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipLumaKeySettings {
        AnimatableClipLumaKeySettings(
            enabled: enabled,
            lowThreshold: try lowThreshold.mappingKeyframeTimes(transform),
            highThreshold: try highThreshold.mappingKeyframeTimes(transform),
            softness: try softness.mappingKeyframeTimes(transform),
            invert: invert
        )
    }
}

extension AnimatableClipColorChannels {
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipColorChannels {
        AnimatableClipColorChannels(
            red: try red.mappingKeyframeTimes(transform),
            green: try green.mappingKeyframeTimes(transform),
            blue: try blue.mappingKeyframeTimes(transform)
        )
    }
}

extension AnimatableClipColorCorrection {
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipColorCorrection {
        AnimatableClipColorCorrection(
            lift: try lift.mappingKeyframeTimes(transform),
            gamma: try gamma.mappingKeyframeTimes(transform),
            gain: try gain.mappingKeyframeTimes(transform),
            exposure: try exposure.mappingKeyframeTimes(transform),
            contrast: try contrast.mappingKeyframeTimes(transform),
            saturation: try saturation.mappingKeyframeTimes(transform),
            temperature: try temperature.mappingKeyframeTimes(transform),
            tint: try tint.mappingKeyframeTimes(transform),
            vibrance: try vibrance.mappingKeyframeTimes(transform)
        )
    }
}

extension AnimatableClipMask {
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipMask {
        AnimatableClipMask(
            id: id,
            shape: try shape.mappingKeyframeTimes(transform),
            featherRadius: try featherRadius.mappingKeyframeTimes(transform),
            invert: invert,
            combine: combine
        )
    }
}

extension AnimatableClipMaskShape {
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipMaskShape {
        switch self {
        case .rectangle(let rectangle):
            return .rectangle(try rectangle.mappingKeyframeTimes(transform))
        case .ellipse(let ellipse):
            return .ellipse(try ellipse.mappingKeyframeTimes(transform))
        case .polygon(let polygon):
            return .polygon(try polygon.mappingKeyframeTimes(transform))
        }
    }
}

extension AnimatableClipRectangleMask {
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipRectangleMask {
        AnimatableClipRectangleMask(
            x: try x.mappingKeyframeTimes(transform),
            y: try y.mappingKeyframeTimes(transform),
            width: try width.mappingKeyframeTimes(transform),
            height: try height.mappingKeyframeTimes(transform)
        )
    }
}

extension AnimatableClipEllipseMask {
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipEllipseMask {
        AnimatableClipEllipseMask(
            centerX: try centerX.mappingKeyframeTimes(transform),
            centerY: try centerY.mappingKeyframeTimes(transform),
            radiusX: try radiusX.mappingKeyframeTimes(transform),
            radiusY: try radiusY.mappingKeyframeTimes(transform)
        )
    }
}

extension AnimatableClipPolygonMask {
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipPolygonMask {
        AnimatableClipPolygonMask(
            points: try points.map { point in try point.mappingKeyframeTimes(transform) }
        )
    }
}

extension ClipAudioMix {
    /// Maps gain/pan automation keyframe times through `transform`. Fade/crossfade edge
    /// metadata is duration-based (not absolute sequence times) and is left unchanged.
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> ClipAudioMix {
        ClipAudioMix(
            gain: try gain.mappingKeyframeTimes(transform),
            pan: try pan.mappingKeyframeTimes(transform),
            fadeIn: fadeIn,
            fadeOut: fadeOut,
            leadingCrossfade: leadingCrossfade,
            trailingCrossfade: trailingCrossfade,
            retimeMode: retimeMode
        )
    }
}

extension TitleSource {
    /// Maps `revealFraction` keyframe times through `transform`.
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> TitleSource {
        withRevealFraction(try revealFraction.mappingKeyframeTimes(transform))
    }
}
