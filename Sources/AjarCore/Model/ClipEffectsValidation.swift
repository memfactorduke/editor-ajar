// SPDX-License-Identifier: GPL-3.0-or-later

enum ClipEffectsValidator {
    static func errors(for effects: ClipEffects) -> [ClipEffectsValidationError] {
        var errors: [ClipEffectsValidationError] = []

        appendColorErrors(effects.chromaKey.keyColor, to: &errors)
        appendUnitIntervalError(
            effects.chromaKey.tolerance,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeyToleranceOutOfRange
        )
        appendUnitIntervalError(
            effects.chromaKey.edgeSoftness,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeyEdgeSoftnessOutOfRange
        )
        appendUnitIntervalError(
            effects.chromaKey.spillSuppression,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeySpillSuppressionOutOfRange
        )
        appendUnitIntervalError(
            effects.chromaKey.choke,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeyChokeOutOfRange
        )
        appendColorCorrectionErrors(effects.colorCorrection, to: &errors)
        errors.append(contentsOf: ClipMaskValidator.errors(for: effects.masks))

        return errors
    }

    static func errors(for effects: AnimatableClipEffects) -> [ClipEffectsValidationError] {
        var errors = errors(for: effects.baseEffects)

        appendUnitIntervalErrors(
            effects.chromaKey.tolerance,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeyToleranceOutOfRange
        )
        appendUnitIntervalErrors(
            effects.chromaKey.edgeSoftness,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeyEdgeSoftnessOutOfRange
        )
        appendUnitIntervalErrors(
            effects.chromaKey.spillSuppression,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeySpillSuppressionOutOfRange
        )
        appendUnitIntervalErrors(
            effects.chromaKey.choke,
            to: &errors,
            error: ClipEffectsValidationError.chromaKeyChokeOutOfRange
        )
        appendColorCorrectionKeyframeErrors(effects.colorCorrection, to: &errors)
        errors.append(contentsOf: ClipMaskValidator.errors(for: effects.masks))

        return errors
    }

    private static func appendColorErrors(
        _ color: ClipRGBColor,
        to errors: inout [ClipEffectsValidationError]
    ) {
        appendUnitIntervalError(color.red, to: &errors) { value in
            .colorChannelOutOfRange(channel: .red, value: value)
        }
        appendUnitIntervalError(color.green, to: &errors) { value in
            .colorChannelOutOfRange(channel: .green, value: value)
        }
        appendUnitIntervalError(color.blue, to: &errors) { value in
            .colorChannelOutOfRange(channel: .blue, value: value)
        }
    }

    private static func appendUnitIntervalError(
        _ value: RationalValue,
        to errors: inout [ClipEffectsValidationError],
        error: (RationalValue) -> ClipEffectsValidationError
    ) {
        if value.isNegative || value.isGreaterThanOne {
            errors.append(error(value))
        }
    }

    private static func appendUnitIntervalErrors(
        _ parameter: Animatable<RationalValue>,
        to errors: inout [ClipEffectsValidationError],
        error: (RationalValue) -> ClipEffectsValidationError
    ) {
        for keyframe in parameter.keyframes {
            appendUnitIntervalError(keyframe.value, to: &errors, error: error)
        }
    }
}
