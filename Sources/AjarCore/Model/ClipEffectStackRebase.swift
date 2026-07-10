// SPDX-License-Identifier: GPL-3.0-or-later

extension AnimatableClipEffectDefinition {
    // Maps every keyframable effect-parameter time through `transform` (issue #198).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func mappingKeyframeTimes(
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipEffectDefinition {
        switch self {
        case .placeholder(let parameters):
            return .placeholder(
                AnimatableClipPlaceholderSettings(
                    amount: try parameters.amount.mappingKeyframeTimes(transform)
                )
            )
        case .gaussianBlur(let parameters):
            return .gaussianBlur(
                AnimatableClipGaussianBlurSettings(
                    radius: try parameters.radius.mappingKeyframeTimes(transform)
                )
            )
        case .boxBlur(let parameters):
            return .boxBlur(
                AnimatableClipBoxBlurSettings(
                    radius: try parameters.radius.mappingKeyframeTimes(transform)
                )
            )
        case .zoomBlur(let parameters):
            return try mappingZoomBlur(parameters, transform)
        case .sharpen(let parameters):
            return .sharpen(
                AnimatableClipSharpenSettings(
                    amount: try parameters.amount.mappingKeyframeTimes(transform),
                    radius: try parameters.radius.mappingKeyframeTimes(transform)
                )
            )
        case .glow(let parameters):
            return .glow(
                AnimatableClipGlowSettings(
                    radius: try parameters.radius.mappingKeyframeTimes(transform),
                    amount: try parameters.amount.mappingKeyframeTimes(transform)
                )
            )
        case .lut(let parameters):
            return .lut(
                AnimatableClipLUTSettings(
                    table: parameters.table,
                    strength: try parameters.strength.mappingKeyframeTimes(transform),
                    placement: parameters.placement
                )
            )
        case .vignette(let parameters):
            return try mappingVignette(parameters, transform)
        case .mirror(let parameters):
            return .mirror(parameters)
        case .mosaic(let parameters):
            return .mosaic(
                AnimatableClipMosaicSettings(
                    cellSize: try parameters.cellSize.mappingKeyframeTimes(transform)
                )
            )
        case .colorAdjust(let parameters):
            return try mappingColorAdjust(parameters, transform)
        case .posterize(let parameters):
            return .posterize(
                AnimatableClipPosterizeSettings(
                    levels: try parameters.levels.mappingKeyframeTimes(transform)
                )
            )
        case .invert(let parameters):
            return .invert(parameters)
        case .curves(let parameters):
            return .curves(
                AnimatableClipCurvesSettings(
                    rgb: parameters.rgb,
                    red: parameters.red,
                    green: parameters.green,
                    blue: parameters.blue,
                    strength: try parameters.strength.mappingKeyframeTimes(transform)
                )
            )
        }
    }

    private func mappingZoomBlur(
        _ parameters: AnimatableClipZoomBlurSettings,
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipEffectDefinition {
        .zoomBlur(
            AnimatableClipZoomBlurSettings(
                amount: try parameters.amount.mappingKeyframeTimes(transform),
                centerX: try parameters.centerX.mappingKeyframeTimes(transform),
                centerY: try parameters.centerY.mappingKeyframeTimes(transform)
            )
        )
    }

    private func mappingVignette(
        _ parameters: AnimatableClipVignetteSettings,
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipEffectDefinition {
        .vignette(
            AnimatableClipVignetteSettings(
                amount: try parameters.amount.mappingKeyframeTimes(transform),
                radius: try parameters.radius.mappingKeyframeTimes(transform),
                softness: try parameters.softness.mappingKeyframeTimes(transform)
            )
        )
    }

    private func mappingColorAdjust(
        _ parameters: AnimatableClipColorAdjustSettings,
        _ transform: (RationalTime) throws -> RationalTime
    ) throws -> AnimatableClipEffectDefinition {
        .colorAdjust(
            AnimatableClipColorAdjustSettings(
                brightness: try parameters.brightness.mappingKeyframeTimes(transform),
                contrast: try parameters.contrast.mappingKeyframeTimes(transform),
                saturation: try parameters.saturation.mappingKeyframeTimes(transform),
                tint: try parameters.tint.mappingKeyframeTimes(transform)
            )
        )
    }
}
