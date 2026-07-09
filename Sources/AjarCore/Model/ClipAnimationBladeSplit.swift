// SPDX-License-Identifier: GPL-3.0-or-later

// Blade splits for keyframed clip animations (FR-XFORM-008): every animatable parameter
// splits through `Animatable.bladed(at:)`, so each half keeps its own keyframes plus a
// boundary keyframe evaluated at the cut and the rendered animation is unchanged.

extension AnimatableClipTransform {
    /// Splits every keyframed transform parameter at the absolute timeline `cut`.
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipTransform, right: AnimatableClipTransform) {
        let position = try position.bladed(at: cut)
        let scale = try scale.bladed(at: cut)
        let anchorPoint = try anchorPoint.bladed(at: cut)
        let rotation = try rotation.bladed(at: cut)
        let opacity = try opacity.bladed(at: cut)
        let crop = try crop.bladed(at: cut)
        return (
            left: AnimatableClipTransform(
                position: position.left,
                scale: scale.left,
                anchorPoint: anchorPoint.left,
                rotation: rotation.left,
                opacity: opacity.left,
                crop: crop.left,
                blendMode: blendMode,
                flip: flip
            ),
            right: AnimatableClipTransform(
                position: position.right,
                scale: scale.right,
                anchorPoint: anchorPoint.right,
                rotation: rotation.right,
                opacity: opacity.right,
                crop: crop.right,
                blendMode: blendMode,
                flip: flip
            )
        )
    }
}

extension AnimatableClipEffects {
    /// Splits every keyframed effect parameter at the absolute timeline `cut`.
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipEffects, right: AnimatableClipEffects) {
        let chromaKey = try chromaKey.bladed(at: cut)
        let lumaKey = try lumaKey.bladed(at: cut)
        let colorCorrection = try colorCorrection.bladed(at: cut)
        let masks = try masks.map { mask in try mask.bladed(at: cut) }
        return (
            left: AnimatableClipEffects(
                chromaKey: chromaKey.left,
                lumaKey: lumaKey.left,
                colorCorrection: colorCorrection.left,
                masks: masks.map(\.left)
            ),
            right: AnimatableClipEffects(
                chromaKey: chromaKey.right,
                lumaKey: lumaKey.right,
                colorCorrection: colorCorrection.right,
                masks: masks.map(\.right)
            )
        )
    }
}

extension AnimatableClipEffectStack {
    /// Splits every keyframed stack parameter at the absolute timeline `cut` (FR-FX-003).
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipEffectStack, right: AnimatableClipEffectStack) {
        let splitNodes = try nodes.map { node in try node.bladed(at: cut) }
        return (
            left: AnimatableClipEffectStack(nodes: splitNodes.map(\.left)),
            right: AnimatableClipEffectStack(nodes: splitNodes.map(\.right))
        )
    }
}

extension AnimatableClipEffectNode {
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipEffectNode, right: AnimatableClipEffectNode) {
        let splitDefinition = try definition.bladed(at: cut)
        return (
            left: AnimatableClipEffectNode(
                id: id,
                enabled: enabled,
                definition: splitDefinition.left
            ),
            right: AnimatableClipEffectNode(
                id: id,
                enabled: enabled,
                definition: splitDefinition.right
            )
        )
    }
}

extension AnimatableClipEffectDefinition {
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipEffectDefinition, right: AnimatableClipEffectDefinition) {
        switch self {
        case .placeholder(let parameters):
            let amount = try parameters.amount.bladed(at: cut)
            return (
                left: .placeholder(AnimatableClipPlaceholderSettings(amount: amount.left)),
                right: .placeholder(AnimatableClipPlaceholderSettings(amount: amount.right))
            )
        case .gaussianBlur(let parameters):
            let radius = try parameters.radius.bladed(at: cut)
            return (
                left: .gaussianBlur(AnimatableClipGaussianBlurSettings(radius: radius.left)),
                right: .gaussianBlur(AnimatableClipGaussianBlurSettings(radius: radius.right))
            )
        case .boxBlur(let parameters):
            let radius = try parameters.radius.bladed(at: cut)
            return (
                left: .boxBlur(AnimatableClipBoxBlurSettings(radius: radius.left)),
                right: .boxBlur(AnimatableClipBoxBlurSettings(radius: radius.right))
            )
        case .zoomBlur(let parameters):
            let amount = try parameters.amount.bladed(at: cut)
            let centerX = try parameters.centerX.bladed(at: cut)
            let centerY = try parameters.centerY.bladed(at: cut)
            return (
                left: .zoomBlur(
                    AnimatableClipZoomBlurSettings(
                        amount: amount.left,
                        centerX: centerX.left,
                        centerY: centerY.left
                    )
                ),
                right: .zoomBlur(
                    AnimatableClipZoomBlurSettings(
                        amount: amount.right,
                        centerX: centerX.right,
                        centerY: centerY.right
                    )
                )
            )
        case .sharpen(let parameters):
            let amount = try parameters.amount.bladed(at: cut)
            let radius = try parameters.radius.bladed(at: cut)
            return (
                left: .sharpen(
                    AnimatableClipSharpenSettings(amount: amount.left, radius: radius.left)
                ),
                right: .sharpen(
                    AnimatableClipSharpenSettings(amount: amount.right, radius: radius.right)
                )
            )
        case .glow(let parameters):
            let radius = try parameters.radius.bladed(at: cut)
            let amount = try parameters.amount.bladed(at: cut)
            return (
                left: .glow(AnimatableClipGlowSettings(radius: radius.left, amount: amount.left)),
                right: .glow(
                    AnimatableClipGlowSettings(radius: radius.right, amount: amount.right)
                )
            )
        }
    }
}

extension AnimatableClipChromaKeySettings {
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipChromaKeySettings, right: AnimatableClipChromaKeySettings) {
        let tolerance = try tolerance.bladed(at: cut)
        let edgeSoftness = try edgeSoftness.bladed(at: cut)
        let spillSuppression = try spillSuppression.bladed(at: cut)
        let choke = try choke.bladed(at: cut)
        return (
            left: AnimatableClipChromaKeySettings(
                enabled: enabled,
                keyColor: keyColor,
                tolerance: tolerance.left,
                edgeSoftness: edgeSoftness.left,
                spillSuppression: spillSuppression.left,
                choke: choke.left,
                viewMatte: viewMatte
            ),
            right: AnimatableClipChromaKeySettings(
                enabled: enabled,
                keyColor: keyColor,
                tolerance: tolerance.right,
                edgeSoftness: edgeSoftness.right,
                spillSuppression: spillSuppression.right,
                choke: choke.right,
                viewMatte: viewMatte
            )
        )
    }
}

extension AnimatableClipLumaKeySettings {
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipLumaKeySettings, right: AnimatableClipLumaKeySettings) {
        let lowThreshold = try lowThreshold.bladed(at: cut)
        let highThreshold = try highThreshold.bladed(at: cut)
        let softness = try softness.bladed(at: cut)
        return (
            left: AnimatableClipLumaKeySettings(
                enabled: enabled,
                lowThreshold: lowThreshold.left,
                highThreshold: highThreshold.left,
                softness: softness.left,
                invert: invert
            ),
            right: AnimatableClipLumaKeySettings(
                enabled: enabled,
                lowThreshold: lowThreshold.right,
                highThreshold: highThreshold.right,
                softness: softness.right,
                invert: invert
            )
        )
    }
}

extension AnimatableClipColorChannels {
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipColorChannels, right: AnimatableClipColorChannels) {
        let red = try red.bladed(at: cut)
        let green = try green.bladed(at: cut)
        let blue = try blue.bladed(at: cut)
        return (
            left: AnimatableClipColorChannels(red: red.left, green: green.left, blue: blue.left),
            right: AnimatableClipColorChannels(red: red.right, green: green.right, blue: blue.right)
        )
    }
}

extension AnimatableClipColorCorrection {
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipColorCorrection, right: AnimatableClipColorCorrection) {
        let lift = try lift.bladed(at: cut)
        let gamma = try gamma.bladed(at: cut)
        let gain = try gain.bladed(at: cut)
        let exposure = try exposure.bladed(at: cut)
        let contrast = try contrast.bladed(at: cut)
        let saturation = try saturation.bladed(at: cut)
        let temperature = try temperature.bladed(at: cut)
        let tint = try tint.bladed(at: cut)
        let vibrance = try vibrance.bladed(at: cut)
        return (
            left: AnimatableClipColorCorrection(
                lift: lift.left,
                gamma: gamma.left,
                gain: gain.left,
                exposure: exposure.left,
                contrast: contrast.left,
                saturation: saturation.left,
                temperature: temperature.left,
                tint: tint.left,
                vibrance: vibrance.left
            ),
            right: AnimatableClipColorCorrection(
                lift: lift.right,
                gamma: gamma.right,
                gain: gain.right,
                exposure: exposure.right,
                contrast: contrast.right,
                saturation: saturation.right,
                temperature: temperature.right,
                tint: tint.right,
                vibrance: vibrance.right
            )
        )
    }
}

extension AnimatableClipMask {
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipMask, right: AnimatableClipMask) {
        let shape = try shape.bladed(at: cut)
        let featherRadius = try featherRadius.bladed(at: cut)
        return (
            left: AnimatableClipMask(
                id: id,
                shape: shape.left,
                featherRadius: featherRadius.left,
                invert: invert,
                combine: combine
            ),
            right: AnimatableClipMask(
                id: id,
                shape: shape.right,
                featherRadius: featherRadius.right,
                invert: invert,
                combine: combine
            )
        )
    }
}

extension AnimatableClipMaskShape {
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipMaskShape, right: AnimatableClipMaskShape) {
        switch self {
        case .rectangle(let rectangle):
            let halves = try rectangle.bladed(at: cut)
            return (.rectangle(halves.left), .rectangle(halves.right))
        case .ellipse(let ellipse):
            let halves = try ellipse.bladed(at: cut)
            return (.ellipse(halves.left), .ellipse(halves.right))
        case .polygon(let polygon):
            let halves = try polygon.bladed(at: cut)
            return (.polygon(halves.left), .polygon(halves.right))
        }
    }
}

extension AnimatableClipRectangleMask {
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipRectangleMask, right: AnimatableClipRectangleMask) {
        let x = try x.bladed(at: cut)
        let y = try y.bladed(at: cut)
        let width = try width.bladed(at: cut)
        let height = try height.bladed(at: cut)
        return (
            left: AnimatableClipRectangleMask(
                x: x.left,
                y: y.left,
                width: width.left,
                height: height.left
            ),
            right: AnimatableClipRectangleMask(
                x: x.right,
                y: y.right,
                width: width.right,
                height: height.right
            )
        )
    }
}

extension AnimatableClipEllipseMask {
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipEllipseMask, right: AnimatableClipEllipseMask) {
        let centerX = try centerX.bladed(at: cut)
        let centerY = try centerY.bladed(at: cut)
        let radiusX = try radiusX.bladed(at: cut)
        let radiusY = try radiusY.bladed(at: cut)
        return (
            left: AnimatableClipEllipseMask(
                centerX: centerX.left,
                centerY: centerY.left,
                radiusX: radiusX.left,
                radiusY: radiusY.left
            ),
            right: AnimatableClipEllipseMask(
                centerX: centerX.right,
                centerY: centerY.right,
                radiusX: radiusX.right,
                radiusY: radiusY.right
            )
        )
    }
}

extension AnimatableClipPolygonMask {
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipPolygonMask, right: AnimatableClipPolygonMask) {
        let points = try points.map { point in try point.bladed(at: cut) }
        return (
            left: AnimatableClipPolygonMask(points: points.map(\.left)),
            right: AnimatableClipPolygonMask(points: points.map(\.right))
        )
    }
}
