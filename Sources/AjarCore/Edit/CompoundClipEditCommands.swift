// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct InsertCompoundClipEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let targetSequenceID: UUID
        let timelineStart: RationalTime
        let kind: TrackKind
        let name: String
    }

    static func applyCompoundClipCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .insertCompoundClip(
            let sequenceID,
            let trackID,
            let clipID,
            let targetSequenceID,
            let timelineStart,
            let kind,
            let name
        ):
            return try insertCompoundClip(
                InsertCompoundClipEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    targetSequenceID: targetSequenceID,
                    timelineStart: timelineStart,
                    kind: kind,
                    name: name
                ),
                in: project
            )
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    static func insertCompoundClip(
        _ edit: InsertCompoundClipEdit,
        in project: Project
    ) throws -> Project {
        guard let targetSequence = project.sequences.first(
            where: { $0.id == edit.targetSequenceID }
        ) else {
            throw EditReducerError.sequenceNotFound(edit.targetSequenceID)
        }

        let duration = try durationForCompoundInsert(targetSequence, clipID: edit.clipID)
        let clip = Clip(
            id: edit.clipID,
            source: .sequence(id: edit.targetSequenceID),
            sourceRange: try makeRange(start: .zero, duration: duration),
            timelineRange: try makeRange(start: edit.timelineStart, duration: duration),
            kind: edit.kind,
            name: edit.name
        )

        return try insertClip(
            clip,
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            in: project
        )
    }

    private static func durationForCompoundInsert(
        _ targetSequence: Sequence,
        clipID: UUID
    ) throws -> RationalTime {
        let duration: RationalTime
        do {
            duration = try targetSequence.timelineDuration()
        } catch let error as ClipSourceResolutionError {
            switch error {
            case .timeArithmeticFailed(let timeError):
                throw EditReducerError.timeArithmeticFailed(timeError)
            case .missingMediaReference, .missingSequenceReference:
                throw EditReducerError.validationFailed([])
            }
        }

        guard duration > .zero else {
            throw EditReducerError.invalidEdit(.nonPositiveDuration(clipID: clipID))
        }
        return duration
    }
}
