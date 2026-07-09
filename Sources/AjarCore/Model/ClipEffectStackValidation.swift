// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum ClipEffectStackValidator {
    static func errors(for stack: ClipEffectStack) -> [ClipEffectStackValidationError] {
        var errors: [ClipEffectStackValidationError] = []
        appendDuplicateIDErrors(stack.nodes.map(\.id), to: &errors)
        for node in stack.nodes {
            appendDefinitionErrors(node.definition, to: &errors)
        }
        return errors
    }

    static func errors(for stack: AnimatableClipEffectStack) -> [ClipEffectStackValidationError] {
        var errors = errors(for: stack.baseStack)
        for node in stack.nodes {
            appendAnimatableDefinitionErrors(node.definition, to: &errors)
        }
        return errors
    }

    private static func appendDuplicateIDErrors(
        _ ids: [UUID],
        to errors: inout [ClipEffectStackValidationError]
    ) {
        var seen: Set<UUID> = []
        for id in ids {
            if seen.contains(id) {
                errors.append(.duplicateEffectNodeID(id))
            } else {
                seen.insert(id)
            }
        }
    }

    private static func appendDefinitionErrors(
        _ definition: ClipEffectDefinition,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        switch definition {
        case .placeholder(let parameters):
            appendPlaceholderErrors(parameters, to: &errors)
        case .gaussianBlur(let parameters):
            appendGaussianBlurErrors(parameters, to: &errors)
        case .boxBlur(let parameters):
            appendBoxBlurErrors(parameters, to: &errors)
        case .zoomBlur(let parameters):
            appendZoomBlurErrors(parameters, to: &errors)
        case .sharpen(let parameters):
            appendSharpenErrors(parameters, to: &errors)
        case .glow(let parameters):
            appendGlowErrors(parameters, to: &errors)
        case .lut(let parameters):
            appendLUTTableErrors(parameters.table, to: &errors)
            appendUnitIntervalError(parameters.strength, to: &errors) { value in
                .lutStrengthOutOfRange(value)
            }
        }
    }

    private static func appendAnimatableDefinitionErrors(
        _ definition: AnimatableClipEffectDefinition,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        switch definition {
        case .placeholder(let parameters):
            appendAnimatablePlaceholderErrors(parameters, to: &errors)
        case .gaussianBlur(let parameters):
            appendAnimatableGaussianBlurErrors(parameters, to: &errors)
        case .boxBlur(let parameters):
            appendAnimatableBoxBlurErrors(parameters, to: &errors)
        case .zoomBlur(let parameters):
            appendAnimatableZoomBlurErrors(parameters, to: &errors)
        case .sharpen(let parameters):
            appendAnimatableSharpenErrors(parameters, to: &errors)
        case .glow(let parameters):
            appendAnimatableGlowErrors(parameters, to: &errors)
        case .lut(let parameters):
            appendAnimatableLUTErrors(parameters, to: &errors)
        }
    }

    private static func appendPlaceholderErrors(
        _ parameters: ClipPlaceholderEffectParameters,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        appendUnitIntervalError(parameters.amount, to: &errors) { value in
            .placeholderAmountOutOfRange(value)
        }
    }

    private static func appendGaussianBlurErrors(
        _ parameters: ClipGaussianBlurParameters,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        appendBlurRadiusError(parameters.radius, to: &errors) { value in
            .gaussianBlurRadiusOutOfRange(value)
        }
    }

    private static func appendBoxBlurErrors(
        _ parameters: ClipBoxBlurParameters,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        appendBoxBlurRadiusError(parameters.radius, to: &errors)
    }

    private static func appendZoomBlurErrors(
        _ parameters: ClipZoomBlurParameters,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        appendUnitIntervalError(parameters.amount, to: &errors) { value in
            .zoomBlurAmountOutOfRange(value)
        }
        appendUnitIntervalError(parameters.centerX, to: &errors) { value in
            .zoomBlurCenterOutOfRange(axis: .x, value: value)
        }
        appendUnitIntervalError(parameters.centerY, to: &errors) { value in
            .zoomBlurCenterOutOfRange(axis: .y, value: value)
        }
    }

    private static func appendSharpenErrors(
        _ parameters: ClipSharpenParameters,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        appendUnitIntervalError(parameters.amount, to: &errors) { value in
            .sharpenAmountOutOfRange(value)
        }
        appendSharpenRadiusError(parameters.radius, to: &errors)
    }

    private static func appendGlowErrors(
        _ parameters: ClipGlowParameters,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        appendBlurRadiusError(parameters.radius, to: &errors) { value in
            .glowRadiusOutOfRange(value)
        }
        appendUnitIntervalError(parameters.amount, to: &errors) { value in
            .glowAmountOutOfRange(value)
        }
    }

    private static func appendAnimatablePlaceholderErrors(
        _ parameters: AnimatableClipPlaceholderSettings,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        for keyframe in parameters.amount.keyframes {
            appendUnitIntervalError(keyframe.value, to: &errors) { value in
                .placeholderAmountOutOfRange(value)
            }
        }
    }

    private static func appendAnimatableGaussianBlurErrors(
        _ parameters: AnimatableClipGaussianBlurSettings,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        for keyframe in parameters.radius.keyframes {
            appendBlurRadiusError(keyframe.value, to: &errors) { value in
                .gaussianBlurRadiusOutOfRange(value)
            }
        }
    }

    private static func appendAnimatableBoxBlurErrors(
        _ parameters: AnimatableClipBoxBlurSettings,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        for keyframe in parameters.radius.keyframes {
            appendBoxBlurRadiusError(keyframe.value, to: &errors)
        }
    }

    private static func appendAnimatableZoomBlurErrors(
        _ parameters: AnimatableClipZoomBlurSettings,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        for keyframe in parameters.amount.keyframes {
            appendUnitIntervalError(keyframe.value, to: &errors) { value in
                .zoomBlurAmountOutOfRange(value)
            }
        }
        for keyframe in parameters.centerX.keyframes {
            appendUnitIntervalError(keyframe.value, to: &errors) { value in
                .zoomBlurCenterOutOfRange(axis: .x, value: value)
            }
        }
        for keyframe in parameters.centerY.keyframes {
            appendUnitIntervalError(keyframe.value, to: &errors) { value in
                .zoomBlurCenterOutOfRange(axis: .y, value: value)
            }
        }
    }

    private static func appendAnimatableSharpenErrors(
        _ parameters: AnimatableClipSharpenSettings,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        for keyframe in parameters.amount.keyframes {
            appendUnitIntervalError(keyframe.value, to: &errors) { value in
                .sharpenAmountOutOfRange(value)
            }
        }
        for keyframe in parameters.radius.keyframes {
            appendSharpenRadiusError(keyframe.value, to: &errors)
        }
    }

    private static func appendAnimatableGlowErrors(
        _ parameters: AnimatableClipGlowSettings,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        for keyframe in parameters.radius.keyframes {
            appendBlurRadiusError(keyframe.value, to: &errors) { value in
                .glowRadiusOutOfRange(value)
            }
        }
        for keyframe in parameters.amount.keyframes {
            appendUnitIntervalError(keyframe.value, to: &errors) { value in
                .glowAmountOutOfRange(value)
            }
        }
    }

    private static func appendAnimatableLUTErrors(
        _ parameters: AnimatableClipLUTSettings,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        appendLUTTableErrors(parameters.table, to: &errors)
        for keyframe in parameters.strength.keyframes {
            appendUnitIntervalError(keyframe.value, to: &errors) { value in
                .lutStrengthOutOfRange(value)
            }
        }
    }

    private static func appendLUTTableErrors(
        _ table: CubeLUTTable,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        if case .failure(let error) = table.validated() {
            errors.append(.lutTableInvalid(error))
        }
    }

    private static func appendUnitIntervalError(
        _ value: RationalValue,
        to errors: inout [ClipEffectStackValidationError],
        error: (RationalValue) -> ClipEffectStackValidationError
    ) {
        if value.isNegative || value.isGreaterThanOne {
            errors.append(error(value))
        }
    }

    private static func appendBlurRadiusError(
        _ value: RationalValue,
        to errors: inout [ClipEffectStackValidationError],
        error: (RationalValue) -> ClipEffectStackValidationError
    ) {
        let maximum = ClipEffectLibraryLimits.maximumBlurRadius.doubleValue
        if value.isNegative || value.doubleValue > maximum {
            errors.append(error(value))
        }
    }

    private static func appendBoxBlurRadiusError(
        _ value: RationalValue,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        let maximum = ClipEffectLibraryLimits.maximumBoxBlurRadius.doubleValue
        if value.isNegative || value.doubleValue > maximum {
            errors.append(.boxBlurRadiusOutOfRange(value))
        }
    }

    private static func appendSharpenRadiusError(
        _ value: RationalValue,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        let maximum = ClipEffectLibraryLimits.maximumSharpenRadius.doubleValue
        if value.isNegative || value.doubleValue > maximum {
            errors.append(.sharpenRadiusOutOfRange(value))
        }
    }
}
