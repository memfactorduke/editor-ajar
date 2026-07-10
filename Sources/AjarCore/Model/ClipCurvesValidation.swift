// SPDX-License-Identifier: GPL-3.0-or-later

enum ClipCurvesValidator {
    static func appendErrors(
        _ parameters: ClipCurvesEffectParameters,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        appendChannel(parameters.rgb, channel: .rgb, to: &errors)
        appendChannel(parameters.red, channel: .red, to: &errors)
        appendChannel(parameters.green, channel: .green, to: &errors)
        appendChannel(parameters.blue, channel: .blue, to: &errors)
        if parameters.strength.isNegative || parameters.strength.isGreaterThanOne {
            errors.append(.curvesStrengthOutOfRange(parameters.strength))
        }
    }

    static func appendAnimatableErrors(
        _ parameters: AnimatableClipCurvesSettings,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        appendChannel(parameters.rgb, channel: .rgb, to: &errors)
        appendChannel(parameters.red, channel: .red, to: &errors)
        appendChannel(parameters.green, channel: .green, to: &errors)
        appendChannel(parameters.blue, channel: .blue, to: &errors)
        for keyframe in parameters.strength.keyframes {
            if keyframe.value.isNegative || keyframe.value.isGreaterThanOne {
                errors.append(.curvesStrengthOutOfRange(keyframe.value))
            }
        }
    }

    private static func appendChannel(
        _ curve: ColorCurve,
        channel: ColorCurveChannel,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        if case .failure(let error) = curve.validated() {
            errors.append(.curvesInvalid(channel: channel, error: error))
        }
    }
}
