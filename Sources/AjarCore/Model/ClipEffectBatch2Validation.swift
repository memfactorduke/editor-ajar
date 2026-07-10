// SPDX-License-Identifier: GPL-3.0-or-later

enum ClipEffectBatch2Validator {
    static func appendVignetteErrors(
        _ parameters: ClipVignetteParameters,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        appendUnitInterval(parameters.amount, to: &errors) { .vignetteAmountOutOfRange($0) }
        appendUnitInterval(parameters.radius, to: &errors) { .vignetteRadiusOutOfRange($0) }
        appendUnitInterval(parameters.softness, to: &errors) { .vignetteSoftnessOutOfRange($0) }
    }

    static func appendMosaicErrors(
        _ parameters: ClipMosaicParameters,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        appendMosaicCellSize(parameters.cellSize, to: &errors)
    }

    static func appendColorAdjustErrors(
        _ parameters: ClipColorAdjustParameters,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        appendSignedUnit(parameters.brightness, to: &errors) {
            .colorAdjustBrightnessOutOfRange($0)
        }
        appendMultiplier(parameters.contrast, to: &errors) {
            .colorAdjustContrastOutOfRange($0)
        }
        appendMultiplier(parameters.saturation, to: &errors) {
            .colorAdjustSaturationOutOfRange($0)
        }
        appendSignedUnit(parameters.tint, to: &errors) { .colorAdjustTintOutOfRange($0) }
    }

    static func appendPosterizeErrors(
        _ parameters: ClipPosterizeParameters,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        appendPosterizeLevels(parameters.levels, to: &errors)
    }

    static func appendAnimatableVignetteErrors(
        _ parameters: AnimatableClipVignetteSettings,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        for keyframe in parameters.amount.keyframes {
            appendUnitInterval(keyframe.value, to: &errors) { .vignetteAmountOutOfRange($0) }
        }
        for keyframe in parameters.radius.keyframes {
            appendUnitInterval(keyframe.value, to: &errors) { .vignetteRadiusOutOfRange($0) }
        }
        for keyframe in parameters.softness.keyframes {
            appendUnitInterval(keyframe.value, to: &errors) { .vignetteSoftnessOutOfRange($0) }
        }
    }

    static func appendAnimatableMosaicErrors(
        _ parameters: AnimatableClipMosaicSettings,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        for keyframe in parameters.cellSize.keyframes {
            appendMosaicCellSize(keyframe.value, to: &errors)
        }
    }

    static func appendAnimatableColorAdjustErrors(
        _ parameters: AnimatableClipColorAdjustSettings,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        for keyframe in parameters.brightness.keyframes {
            appendSignedUnit(keyframe.value, to: &errors) {
                .colorAdjustBrightnessOutOfRange($0)
            }
        }
        for keyframe in parameters.contrast.keyframes {
            appendMultiplier(keyframe.value, to: &errors) {
                .colorAdjustContrastOutOfRange($0)
            }
        }
        for keyframe in parameters.saturation.keyframes {
            appendMultiplier(keyframe.value, to: &errors) {
                .colorAdjustSaturationOutOfRange($0)
            }
        }
        for keyframe in parameters.tint.keyframes {
            appendSignedUnit(keyframe.value, to: &errors) { .colorAdjustTintOutOfRange($0) }
        }
    }

    static func appendAnimatablePosterizeErrors(
        _ parameters: AnimatableClipPosterizeSettings,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        for keyframe in parameters.levels.keyframes {
            appendPosterizeLevels(keyframe.value, to: &errors)
        }
    }

    private static func appendUnitInterval(
        _ value: RationalValue,
        to errors: inout [ClipEffectStackValidationError],
        error: (RationalValue) -> ClipEffectStackValidationError
    ) {
        if value.isNegative || value.isGreaterThanOne {
            errors.append(error(value))
        }
    }

    private static func appendSignedUnit(
        _ value: RationalValue,
        to errors: inout [ClipEffectStackValidationError],
        error: (RationalValue) -> ClipEffectStackValidationError
    ) {
        if value.doubleValue < -1 || value.doubleValue > 1 {
            errors.append(error(value))
        }
    }

    private static func appendMultiplier(
        _ value: RationalValue,
        to errors: inout [ClipEffectStackValidationError],
        error: (RationalValue) -> ClipEffectStackValidationError
    ) {
        let maximum = ClipEffectLibraryLimits.maximumColorAdjustMultiplier.doubleValue
        if value.isNegative || value.doubleValue > maximum {
            errors.append(error(value))
        }
    }

    private static func appendMosaicCellSize(
        _ value: RationalValue,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        let maximum = ClipEffectLibraryLimits.maximumMosaicCellSize.doubleValue
        if value.doubleValue < 1 || value.doubleValue > maximum {
            errors.append(.mosaicCellSizeOutOfRange(value))
        }
    }

    private static func appendPosterizeLevels(
        _ value: RationalValue,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        let maximum = ClipEffectLibraryLimits.maximumPosterizeLevels.doubleValue
        if value.doubleValue < 2 || value.doubleValue > maximum {
            errors.append(.posterizeLevelsOutOfRange(value))
        }
    }
}
