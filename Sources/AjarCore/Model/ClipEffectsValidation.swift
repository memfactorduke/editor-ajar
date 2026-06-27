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
        appendLumaKeyErrors(effects.lumaKey, to: &errors)
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
        appendLumaKeyKeyframeErrors(effects.lumaKey, to: &errors)
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

    private static func appendLumaKeyErrors(
        _ settings: ClipLumaKeySettings,
        to errors: inout [ClipEffectsValidationError]
    ) {
        appendLumaKeyUnitIntervalError(
            settings.lowThreshold,
            parameter: .lowThreshold,
            to: &errors
        )
        appendLumaKeyUnitIntervalError(
            settings.highThreshold,
            parameter: .highThreshold,
            to: &errors
        )
        appendLumaKeyUnitIntervalError(settings.softness, parameter: .softness, to: &errors)
        appendLumaKeyThresholdOrderError(
            lowThreshold: settings.lowThreshold,
            highThreshold: settings.highThreshold,
            to: &errors
        )
    }

    private static func appendLumaKeyKeyframeErrors(
        _ settings: AnimatableClipLumaKeySettings,
        to errors: inout [ClipEffectsValidationError]
    ) {
        appendLumaKeyUnitIntervalErrors(
            settings.lowThreshold,
            parameter: .lowThreshold,
            to: &errors
        )
        appendLumaKeyUnitIntervalErrors(
            settings.highThreshold,
            parameter: .highThreshold,
            to: &errors
        )
        appendLumaKeyUnitIntervalErrors(settings.softness, parameter: .softness, to: &errors)
        for time in lumaKeyKeyframeTimes(settings) {
            let value = settings.value(at: time)
            appendLumaKeyThresholdOrderError(
                lowThreshold: value.lowThreshold,
                highThreshold: value.highThreshold,
                to: &errors
            )
        }
    }

    private static func appendLumaKeyUnitIntervalError(
        _ value: RationalValue,
        parameter: ClipLumaKeyParameter,
        to errors: inout [ClipEffectsValidationError]
    ) {
        appendUnitIntervalError(value, to: &errors) { invalidValue in
            .lumaKeyParameterOutOfRange(
                parameter: parameter,
                value: invalidValue,
                minimum: .zero,
                maximum: .one
            )
        }
    }

    private static func appendLumaKeyUnitIntervalErrors(
        _ parameter: Animatable<RationalValue>,
        parameter lumaParameter: ClipLumaKeyParameter,
        to errors: inout [ClipEffectsValidationError]
    ) {
        appendUnitIntervalErrors(parameter, to: &errors) { value in
            .lumaKeyParameterOutOfRange(
                parameter: lumaParameter,
                value: value,
                minimum: .zero,
                maximum: .one
            )
        }
    }

    private static func appendLumaKeyThresholdOrderError(
        lowThreshold: RationalValue,
        highThreshold: RationalValue,
        to errors: inout [ClipEffectsValidationError]
    ) {
        guard isGreaterThan(lowThreshold, highThreshold) else {
            return
        }

        errors.append(
            .lumaKeyThresholdOrderInvalid(
                lowThreshold: lowThreshold,
                highThreshold: highThreshold
            )
        )
    }

    private static func lumaKeyKeyframeTimes(
        _ settings: AnimatableClipLumaKeySettings
    ) -> [RationalTime] {
        Set(
            settings.lowThreshold.keyframes.map(\.time)
                + settings.highThreshold.keyframes.map(\.time)
        ).sorted()
    }

    private static func isGreaterThan(_ left: RationalValue, _ right: RationalValue) -> Bool {
        let leftValue = Double(left.numerator) / Double(left.denominator)
        let rightValue = Double(right.numerator) / Double(right.denominator)
        return leftValue > rightValue
    }
}
