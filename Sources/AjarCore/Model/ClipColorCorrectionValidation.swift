// SPDX-License-Identifier: GPL-3.0-or-later

extension ClipEffectsValidator {
    static func appendColorCorrectionErrors(
        _ correction: ClipColorCorrection,
        to errors: inout [ClipEffectsValidationError]
    ) {
        let channelInputs = [
            (correction.lift, ClipColorCorrectionChannelGroup.lift, ColorCorrectionRange.lift),
            (correction.gamma, ClipColorCorrectionChannelGroup.gamma, ColorCorrectionRange.gamma),
            (correction.gain, ClipColorCorrectionChannelGroup.gain, ColorCorrectionRange.gain)
        ]
        for (channels, group, range) in channelInputs {
            appendChannelRangeErrors(channels, group: group, range: range, to: &errors)
        }

        let scalarInputs = [
            (
                correction.exposure,
                ClipColorCorrectionParameter.exposure,
                ColorCorrectionRange.exposure
            ),
            (
                correction.contrast,
                ClipColorCorrectionParameter.contrast,
                ColorCorrectionRange.scalar
            ),
            (
                correction.saturation,
                ClipColorCorrectionParameter.saturation,
                ColorCorrectionRange.scalar
            ),
            (
                correction.temperature,
                ClipColorCorrectionParameter.temperature,
                ColorCorrectionRange.balance
            ),
            (correction.tint, ClipColorCorrectionParameter.tint, ColorCorrectionRange.balance),
            (
                correction.vibrance,
                ClipColorCorrectionParameter.vibrance,
                ColorCorrectionRange.balance
            )
        ]
        for (value, parameter, range) in scalarInputs {
            appendParameterRangeError(value, parameter: parameter, range: range, to: &errors)
        }
    }

    static func appendColorCorrectionKeyframeErrors(
        _ correction: AnimatableClipColorCorrection,
        to errors: inout [ClipEffectsValidationError]
    ) {
        let channelInputs = [
            (correction.lift, ClipColorCorrectionChannelGroup.lift, ColorCorrectionRange.lift),
            (correction.gamma, ClipColorCorrectionChannelGroup.gamma, ColorCorrectionRange.gamma),
            (correction.gain, ClipColorCorrectionChannelGroup.gain, ColorCorrectionRange.gain)
        ]
        for (channels, group, range) in channelInputs {
            appendChannelRangeErrors(channels, group: group, range: range, to: &errors)
        }

        let scalarInputs = [
            (
                correction.exposure,
                ClipColorCorrectionParameter.exposure,
                ColorCorrectionRange.exposure
            ),
            (
                correction.contrast,
                ClipColorCorrectionParameter.contrast,
                ColorCorrectionRange.scalar
            ),
            (
                correction.saturation,
                ClipColorCorrectionParameter.saturation,
                ColorCorrectionRange.scalar
            ),
            (
                correction.temperature,
                ClipColorCorrectionParameter.temperature,
                ColorCorrectionRange.balance
            ),
            (correction.tint, ClipColorCorrectionParameter.tint, ColorCorrectionRange.balance),
            (
                correction.vibrance,
                ClipColorCorrectionParameter.vibrance,
                ColorCorrectionRange.balance
            )
        ]
        for (parameter, colorParameter, range) in scalarInputs {
            appendParameterRangeErrors(
                parameter,
                parameter: colorParameter,
                range: range,
                to: &errors
            )
        }
    }

    private static func appendChannelRangeErrors(
        _ channels: ClipColorChannels,
        group: ClipColorCorrectionChannelGroup,
        range: ColorCorrectionRange,
        to errors: inout [ClipEffectsValidationError]
    ) {
        appendChannelRangeError(
            channels.red,
            group: group,
            channel: .red,
            range: range,
            to: &errors
        )
        appendChannelRangeError(
            channels.green,
            group: group,
            channel: .green,
            range: range,
            to: &errors
        )
        appendChannelRangeError(
            channels.blue,
            group: group,
            channel: .blue,
            range: range,
            to: &errors
        )
    }

    private static func appendChannelRangeErrors(
        _ channels: AnimatableClipColorChannels,
        group: ClipColorCorrectionChannelGroup,
        range: ColorCorrectionRange,
        to errors: inout [ClipEffectsValidationError]
    ) {
        appendChannelRangeErrors(
            channels.red,
            group: group,
            channel: .red,
            range: range,
            to: &errors
        )
        appendChannelRangeErrors(
            channels.green,
            group: group,
            channel: .green,
            range: range,
            to: &errors
        )
        appendChannelRangeErrors(
            channels.blue,
            group: group,
            channel: .blue,
            range: range,
            to: &errors
        )
    }

    private static func appendChannelRangeErrors(
        _ parameter: Animatable<RationalValue>,
        group: ClipColorCorrectionChannelGroup,
        channel: ClipColorChannel,
        range: ColorCorrectionRange,
        to errors: inout [ClipEffectsValidationError]
    ) {
        for keyframe in parameter.keyframes {
            appendChannelRangeError(
                keyframe.value,
                group: group,
                channel: channel,
                range: range,
                to: &errors
            )
        }
    }

    private static func appendChannelRangeError(
        _ value: RationalValue,
        group: ClipColorCorrectionChannelGroup,
        channel: ClipColorChannel,
        range: ColorCorrectionRange,
        to errors: inout [ClipEffectsValidationError]
    ) {
        guard range.contains(value) == false else {
            return
        }

        errors.append(
            .colorCorrectionChannelOutOfRange(
                group: group,
                channel: channel,
                value: value,
                minimum: range.minimum,
                maximum: range.maximum
            )
        )
    }

    private static func appendParameterRangeErrors(
        _ parameter: Animatable<RationalValue>,
        parameter colorParameter: ClipColorCorrectionParameter,
        range: ColorCorrectionRange,
        to errors: inout [ClipEffectsValidationError]
    ) {
        for keyframe in parameter.keyframes {
            appendParameterRangeError(
                keyframe.value,
                parameter: colorParameter,
                range: range,
                to: &errors
            )
        }
    }

    private static func appendParameterRangeError(
        _ value: RationalValue,
        parameter: ClipColorCorrectionParameter,
        range: ColorCorrectionRange,
        to errors: inout [ClipEffectsValidationError]
    ) {
        guard range.contains(value) == false else {
            return
        }

        errors.append(
            .colorCorrectionParameterOutOfRange(
                parameter: parameter,
                value: value,
                minimum: range.minimum,
                maximum: range.maximum
            )
        )
    }
}

private struct ColorCorrectionRange {
    let minimum: RationalValue
    let maximum: RationalValue

    static let lift = ColorCorrectionRange(minimum: RationalValue(-1), maximum: RationalValue(1))
    static let gamma = ColorCorrectionRange(
        minimum: RationalValue.approximating(0.01),
        maximum: RationalValue(4)
    )
    static let gain = ColorCorrectionRange(minimum: RationalValue(0), maximum: RationalValue(4))
    static let exposure = ColorCorrectionRange(
        minimum: RationalValue(-10),
        maximum: RationalValue(10)
    )
    static let scalar = ColorCorrectionRange(minimum: RationalValue(0), maximum: RationalValue(4))
    static let balance = ColorCorrectionRange(minimum: RationalValue(-1), maximum: RationalValue(1))

    func contains(_ value: RationalValue) -> Bool {
        value.doubleValue >= minimum.doubleValue && value.doubleValue <= maximum.doubleValue
    }
}
