// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Typed failures from the edit reducer.
public enum EditReducerError: Error, Equatable, Sendable {
    /// The command references a missing sequence.
    case sequenceNotFound(UUID)

    /// The command references a missing track.
    case trackNotFound(sequenceID: UUID, trackID: UUID)

    /// The command references a missing clip.
    case clipNotFound(sequenceID: UUID, trackID: UUID, clipID: UUID)

    /// The command references a missing marker.
    case markerNotFound(sequenceID: UUID, markerID: UUID)

    /// The command references a media ID that is not in the project manifest.
    case mediaReferenceNotFound(UUID)

    /// A batch media rewrite contains the same stable ID more than once.
    case duplicateMediaReferenceReplacement(UUID)

    /// The command would create duplicate sequence IDs inside the project.
    case duplicateSequenceID(UUID)

    /// The command would leave the project without any editable sequence.
    case cannotRemoveLastSequence(UUID)

    /// The command would create duplicate track IDs inside a sequence.
    case duplicateTrackID(sequenceID: UUID, trackID: UUID)

    /// The command would create duplicate marker IDs inside a sequence.
    case duplicateMarkerID(sequenceID: UUID, markerID: UUID)

    /// The command references a missing link group.
    case linkGroupNotFound(sequenceID: UUID, linkGroupID: UUID)

    /// The command's requested edit is not valid for the current timeline state.
    case invalidEdit(EditCommandValidationError)

    /// Exact timeline arithmetic failed while applying the command.
    case timeArithmeticFailed(RationalTimeError)

    /// The command produced a project that failed central validation.
    case validationFailed([ProjectValidationError])
}

/// Pure reducer entry point required by ADR-0008.
public func apply(_ command: EditCommand, to project: Project) throws -> Project {
    try EditReducer.apply(command, to: project)
}

/// Pure project edit reducer.
public enum EditReducer {
    /// Applies `command` to `project`, returning a new validated project.
    public static func apply(_ command: EditCommand, to project: Project) throws -> Project {
        try validated(try applyUnchecked(command, to: project))
    }
}
