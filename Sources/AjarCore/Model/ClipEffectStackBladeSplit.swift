// SPDX-License-Identifier: GPL-3.0-or-later

extension AnimatableClipEffectDefinition {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func bladed(
        at cut: RationalTime
    ) throws -> (left: AnimatableClipEffectDefinition, right: AnimatableClipEffectDefinition) {
        switch self {
        case .placeholder(let parameters):
            let amount = try parameters.amount.bladed(at: cut)
            return (
                .placeholder(AnimatableClipPlaceholderSettings(amount: amount.left)),
                .placeholder(AnimatableClipPlaceholderSettings(amount: amount.right))
            )
        case .gaussianBlur(let parameters):
            let radius = try parameters.radius.bladed(at: cut)
            return (
                .gaussianBlur(AnimatableClipGaussianBlurSettings(radius: radius.left)),
                .gaussianBlur(AnimatableClipGaussianBlurSettings(radius: radius.right))
            )
        case .boxBlur(let parameters):
            let radius = try parameters.radius.bladed(at: cut)
            return (
                .boxBlur(AnimatableClipBoxBlurSettings(radius: radius.left)),
                .boxBlur(AnimatableClipBoxBlurSettings(radius: radius.right))
            )
        case .zoomBlur(let parameters):
            return try bladedZoomBlur(parameters, at: cut)
        case .sharpen(let parameters):
            let amount = try parameters.amount.bladed(at: cut)
            let radius = try parameters.radius.bladed(at: cut)
            return (
                .sharpen(AnimatableClipSharpenSettings(amount: amount.left, radius: radius.left)),
                .sharpen(AnimatableClipSharpenSettings(amount: amount.right, radius: radius.right))
            )
        case .glow(let parameters):
            let radius = try parameters.radius.bladed(at: cut)
            let amount = try parameters.amount.bladed(at: cut)
            return (
                .glow(AnimatableClipGlowSettings(radius: radius.left, amount: amount.left)),
                .glow(AnimatableClipGlowSettings(radius: radius.right, amount: amount.right))
            )
        case .lut(let parameters):
            // Table + placement constant; only strength keyframes blade (FR-COL-004).
            let strength = try parameters.strength.bladed(at: cut)
            return (
                .lut(
                    AnimatableClipLUTSettings(
                        table: parameters.table,
                        strength: strength.left,
                        placement: parameters.placement
                    )
                ),
                .lut(
                    AnimatableClipLUTSettings(
                        table: parameters.table,
                        strength: strength.right,
                        placement: parameters.placement
                    )
                )
            )
        case .vignette(let parameters):
            return try bladedVignette(parameters, at: cut)
        case .mirror(let parameters):
            return (.mirror(parameters), .mirror(parameters))
        case .mosaic(let parameters):
            let cellSize = try parameters.cellSize.bladed(at: cut)
            return (
                .mosaic(AnimatableClipMosaicSettings(cellSize: cellSize.left)),
                .mosaic(AnimatableClipMosaicSettings(cellSize: cellSize.right))
            )
        case .colorAdjust(let parameters):
            return try bladedColorAdjust(parameters, at: cut)
        case .posterize(let parameters):
            let levels = try parameters.levels.bladed(at: cut)
            return (
                .posterize(AnimatableClipPosterizeSettings(levels: levels.left)),
                .posterize(AnimatableClipPosterizeSettings(levels: levels.right))
            )
        case .invert(let parameters):
            return (.invert(parameters), .invert(parameters))
        }
    }

    private func bladedZoomBlur(
        _ parameters: AnimatableClipZoomBlurSettings,
        at cut: RationalTime
    ) throws -> (left: AnimatableClipEffectDefinition, right: AnimatableClipEffectDefinition) {
        let amount = try parameters.amount.bladed(at: cut)
        let centerX = try parameters.centerX.bladed(at: cut)
        let centerY = try parameters.centerY.bladed(at: cut)
        return (
            .zoomBlur(
                AnimatableClipZoomBlurSettings(
                    amount: amount.left,
                    centerX: centerX.left,
                    centerY: centerY.left
                )
            ),
            .zoomBlur(
                AnimatableClipZoomBlurSettings(
                    amount: amount.right,
                    centerX: centerX.right,
                    centerY: centerY.right
                )
            )
        )
    }

    private func bladedVignette(
        _ parameters: AnimatableClipVignetteSettings,
        at cut: RationalTime
    ) throws -> (left: AnimatableClipEffectDefinition, right: AnimatableClipEffectDefinition) {
        let amount = try parameters.amount.bladed(at: cut)
        let radius = try parameters.radius.bladed(at: cut)
        let softness = try parameters.softness.bladed(at: cut)
        return (
            .vignette(
                AnimatableClipVignetteSettings(
                    amount: amount.left,
                    radius: radius.left,
                    softness: softness.left
                )
            ),
            .vignette(
                AnimatableClipVignetteSettings(
                    amount: amount.right,
                    radius: radius.right,
                    softness: softness.right
                )
            )
        )
    }

    private func bladedColorAdjust(
        _ parameters: AnimatableClipColorAdjustSettings,
        at cut: RationalTime
    ) throws -> (left: AnimatableClipEffectDefinition, right: AnimatableClipEffectDefinition) {
        let brightness = try parameters.brightness.bladed(at: cut)
        let contrast = try parameters.contrast.bladed(at: cut)
        let saturation = try parameters.saturation.bladed(at: cut)
        let tint = try parameters.tint.bladed(at: cut)
        return (
            .colorAdjust(
                AnimatableClipColorAdjustSettings(
                    brightness: brightness.left,
                    contrast: contrast.left,
                    saturation: saturation.left,
                    tint: tint.left
                )
            ),
            .colorAdjust(
                AnimatableClipColorAdjustSettings(
                    brightness: brightness.right,
                    contrast: contrast.right,
                    saturation: saturation.right,
                    tint: tint.right
                )
            )
        )
    }
}
