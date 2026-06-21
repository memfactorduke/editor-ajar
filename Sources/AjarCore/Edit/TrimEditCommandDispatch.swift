// SPDX-License-Identifier: GPL-3.0-or-later

extension EditReducer {
    static func applyTrimClipCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .bladeClip:
            return try applyBladeClipCommand(command, to: project)
        case .rippleTrimClip:
            return try applyRippleTrimClipCommand(command, to: project)
        case .rollEdit:
            return try applyRollEditCommand(command, to: project)
        case .slipClip:
            return try applySlipClipCommand(command, to: project)
        case .slideClip:
            return try applySlideClipCommand(command, to: project)
        case .rippleDeleteClip(let sequenceID, let trackID, let clipID):
            return try rippleDeleteClip(
                clipID: clipID,
                sequenceID: sequenceID,
                trackID: trackID,
                in: project
            )
        case .liftClip(let sequenceID, let trackID, let clipID):
            return try liftClip(
                clipID: clipID,
                sequenceID: sequenceID,
                trackID: trackID,
                in: project
            )
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    static func applyBladeClipCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        guard
            case .bladeClip(
                let sequenceID,
                let trackID,
                let clipID,
                let atTime,
                let rightClipID
            ) = command
        else {
            throw EditReducerError.validationFailed([])
        }
        return try bladeClip(
            BladeClipEdit(
                sequenceID: sequenceID,
                trackID: trackID,
                clipID: clipID,
                atTime: atTime,
                rightClipID: rightClipID
            ),
            in: project
        )
    }

    static func applyRippleTrimClipCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        guard
            case .rippleTrimClip(
                let sequenceID,
                let trackID,
                let clipID,
                let sourceRange,
                let range
            ) = command
        else {
            throw EditReducerError.validationFailed([])
        }
        return try rippleTrimClip(
            RippleTrimClipEdit(
                sequenceID: sequenceID,
                trackID: trackID,
                clipID: clipID,
                sourceRange: sourceRange,
                timelineRange: range
            ),
            in: project
        )
    }

    static func applyRollEditCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        guard
            case .rollEdit(
                let sequenceID,
                let trackID,
                let leftClipID,
                let rightClipID,
                let editTime
            ) = command
        else {
            throw EditReducerError.validationFailed([])
        }
        return try rollEdit(
            RollEdit(
                sequenceID: sequenceID,
                trackID: trackID,
                leftClipID: leftClipID,
                rightClipID: rightClipID,
                editTime: editTime
            ),
            in: project
        )
    }

    static func applySlipClipCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        guard
            case .slipClip(let sequenceID, let trackID, let clipID, let sourceRange) = command
        else {
            throw EditReducerError.validationFailed([])
        }
        return try slipClip(
            SlipClipEdit(
                sequenceID: sequenceID,
                trackID: trackID,
                clipID: clipID,
                sourceRange: sourceRange
            ),
            in: project
        )
    }

    static func applySlideClipCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        guard
            case .slideClip(let sequenceID, let trackID, let clipID, let timelineRange) = command
        else {
            throw EditReducerError.validationFailed([])
        }
        return try slideClip(
            SlideClipEdit(
                sequenceID: sequenceID,
                trackID: trackID,
                clipID: clipID,
                timelineRange: timelineRange
            ),
            in: project
        )
    }
}
