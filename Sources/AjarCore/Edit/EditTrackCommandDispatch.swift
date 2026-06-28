// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    static func applyTrackCommand(_ command: EditCommand, to project: Project) throws -> Project {
        switch command {
        case .setTrackState(let sequenceID, let trackID, let state):
            return try applyTrackStateCommand(
                sequenceID: sequenceID,
                trackID: trackID,
                state: state,
                to: project
            )
        case .setTrackCompositing(let sequenceID, let trackID, let compositing):
            return try applyTrackCompositingCommand(
                sequenceID: sequenceID,
                trackID: trackID,
                compositing: compositing,
                to: project
            )
        case .setTrackAudioMix(let sequenceID, let trackID, let audio):
            return try setTrackAudioMix(
                TrackAudioMixEdit(sequenceID: sequenceID, trackID: trackID, audio: audio),
                in: project
            )
        case .clearTrackAudioMix(let sequenceID, let trackID):
            return try clearTrackAudioMix(
                TrackAudioMixTarget(sequenceID: sequenceID, trackID: trackID),
                in: project
            )
        default:
            throw TrackCommandDispatchError.unsupported(command)
        }
    }

    static func applyTrackStateCommand(
        sequenceID: UUID,
        trackID: UUID,
        state: TrackStatePatch,
        to project: Project
    ) throws -> Project {
        try setTrackState(
            TrackStateEdit(sequenceID: sequenceID, trackID: trackID, state: state),
            in: project
        )
    }

    static func applyTrackCompositingCommand(
        sequenceID: UUID,
        trackID: UUID,
        compositing: TrackCompositingPatch,
        to project: Project
    ) throws -> Project {
        try setTrackCompositing(
            TrackCompositingEdit(
                sequenceID: sequenceID,
                trackID: trackID,
                compositing: compositing
            ),
            in: project
        )
    }
}

private enum TrackCommandDispatchError: Error, Equatable {
    case unsupported(EditCommand)
}
