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
            appendUnitIntervalError(parameters.amount, to: &errors) { value in
                .placeholderAmountOutOfRange(value)
            }
        }
    }

    private static func appendAnimatableDefinitionErrors(
        _ definition: AnimatableClipEffectDefinition,
        to errors: inout [ClipEffectStackValidationError]
    ) {
        switch definition {
        case .placeholder(let parameters):
            for keyframe in parameters.amount.keyframes {
                appendUnitIntervalError(keyframe.value, to: &errors) { value in
                    .placeholderAmountOutOfRange(value)
                }
            }
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
}
