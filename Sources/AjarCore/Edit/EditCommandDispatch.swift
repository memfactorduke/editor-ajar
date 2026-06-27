// SPDX-License-Identifier: GPL-3.0-or-later

extension EditReducer {
    // swiftlint:disable:next cyclomatic_complexity
    static func applyUnchecked(_ command: EditCommand, to project: Project) throws -> Project {
        switch command {
        case .addClip, .insertClip, .overwriteClip, .appendClip,
            .removeClip, .replaceClipSource, .threePointEdit, .bladeClip,
            .rippleTrimClip, .rollEdit, .slipClip, .slideClip, .rippleDeleteClip,
            .liftClip, .moveClip, .trimClip, .setClipTransform,
            .addClipTransformKeyframe, .moveClipTransformKeyframe,
            .deleteClipTransformKeyframe, .setClipChromaKey,
            .addClipMask, .removeClipMask, .moveClipMask, .setClipMask:
            return try applyClipCommand(command, to: project)
        case .setTrackState(let sequenceID, let trackID, let state):
            return try setTrackState(
                TrackStateEdit(sequenceID: sequenceID, trackID: trackID, state: state),
                in: project
            )
        case .addTrack(let sequenceID, let track):
            return try addTrack(track, sequenceID: sequenceID, to: project)
        case .removeTrack(let sequenceID, let trackID):
            return try removeTrack(trackID: trackID, sequenceID: sequenceID, from: project)
        case .addSequence(let sequence):
            return try addSequence(sequence, to: project)
        case .removeSequence(let sequenceID):
            return try removeSequence(sequenceID: sequenceID, from: project)
        case .duplicateSequence(let sourceSequenceID, let duplicate):
            return try duplicateSequence(
                sourceSequenceID: sourceSequenceID,
                duplicate: duplicate,
                in: project
            )
        case .renameSequence(let sequenceID, let name):
            return try renameSequence(sequenceID: sequenceID, name: name, in: project)
        case .addMarker(let sequenceID, let marker):
            return try addMarker(marker, sequenceID: sequenceID, to: project)
        case .removeMarker(let sequenceID, let markerID):
            return try removeMarker(markerID: markerID, sequenceID: sequenceID, from: project)
        case .updateMarker(let sequenceID, let marker):
            return try updateMarker(marker, sequenceID: sequenceID, in: project)
        case .linkClips(let sequenceID, let linkGroupID, let clips):
            return try linkClips(
                sequenceID: sequenceID,
                linkGroupID: linkGroupID,
                clips: clips,
                in: project
            )
        case .unlinkClips(let sequenceID, let linkGroupID):
            return try unlinkClips(
                sequenceID: sequenceID,
                linkGroupID: linkGroupID,
                in: project
            )
        case .setProjectSettings(let settings):
            return Project(
                schemaVersion: project.schemaVersion,
                settings: settings,
                mediaPool: project.mediaPool,
                sequences: project.sequences
            )
        }
    }
}
