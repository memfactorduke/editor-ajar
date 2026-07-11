// SPDX-License-Identifier: GPL-3.0-or-later

extension EditReducer {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func applyUnchecked(_ command: EditCommand, to project: Project) throws -> Project {
        switch command {
        case .addClip, .insertClip, .overwriteClip, .appendClip,
            .insertCompoundClip, .makeCompoundClip, .decomposeCompoundClip,
            .removeClip, .replaceClipSource, .threePointEdit,
            .bladeClip, .rippleTrimClip, .rollEdit, .slipClip, .slideClip,
            .rippleDeleteClip, .liftClip, .moveClip, .trimClip, .setClipTransform,
            .setClipSpeed, .setClipPlaybackAttributes,
            .addClipTransformKeyframe, .moveClipTransformKeyframe,
            .deleteClipTransformKeyframe, .setClipChromaKey, .setClipLumaKey,
            .clearClipLumaKey,
            .setClipColorCorrection, .clearClipColorCorrection,
            .addClipMask, .removeClipMask, .moveClipMask, .setClipMask,
            .addClipEffectNode, .removeClipEffectNode, .moveClipEffectNode,
            .setClipEffectNodeEnabled, .setClipEffectNodeParameters,
            .resetClipEffectNode, .resetClipEffectStack,
            .setClipAudioMix, .clearClipAudioMix, .setClipAudioRetimeMode,
            .setClipAudioCrossfade, .removeClipAudioCrossfade,
            .setClipVideoTransition, .removeClipVideoTransition,
            .detachClipAudio, .replaceClipAudioSource:
            return try applyClipCommand(command, to: project)
        case .insertTitleClip, .setClipTitleSource, .setTitleTextBox, .removeTitleTextBox,
            .applyTitleAnimationPreset:
            return try applyTitleClipCommand(command, to: project)
        case .setTrackState, .setTrackCompositing, .setTrackAudioMix, .clearTrackAudioMix:
            return try applyTrackCommand(command, to: project)
        case .copyClipGrade, .saveLookFromClip, .applyLookToClip, .renameLook, .deleteLook:
            return try applyLookCommand(command, to: project)
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
        case .setSequenceAudioDucking(let sequenceID, let ducking):
            return try setSequenceAudioDucking(
                sequenceID: sequenceID, ducking: ducking, in: project
            )
        case .clearSequenceAudioDucking(let sequenceID):
            return try clearSequenceAudioDucking(sequenceID: sequenceID, in: project)
        case .addMarker(let sequenceID, let marker):
            return try addMarker(marker, sequenceID: sequenceID, to: project)
        case .removeMarker(let sequenceID, let markerID):
            return try removeMarker(markerID: markerID, sequenceID: sequenceID, from: project)
        case .updateMarker(let sequenceID, let marker):
            return try updateMarker(marker, sequenceID: sequenceID, in: project)
        case .linkClips(let sequenceID, let linkGroupID, let clips):
            return try linkClips(
                sequenceID: sequenceID, linkGroupID: linkGroupID, clips: clips, in: project
            )
        case .unlinkClips(let sequenceID, let linkGroupID):
            return try unlinkClips(sequenceID: sequenceID, linkGroupID: linkGroupID, in: project)
        case .setProjectSettings(let settings):
            return Project(
                schemaVersion: project.schemaVersion,
                settings: settings,
                mediaPool: project.mediaPool,
                sequences: project.sequences,
                looks: project.looks
            )
        case .addMediaReferences(let additions):
            return try addMediaReferences(additions, to: project)
        case .updateMediaReferences(_, let replacements):
            return try updateMediaReferences(replacements, in: project)
        case .transaction(let commands):
            return try applyTransaction(commands, to: project)
        }
    }

    /// Applies an ordered transaction of sub-commands as one atomic step (FR-TL-005 / #240).
    ///
    /// Each sub-command threads through the unchecked pipeline so the outer `apply` runs one
    /// central validation over the final project. Any sub-command that throws a typed error
    /// aborts the whole transaction, leaving the input project unchanged (NFR-STAB-003).
    static func applyTransaction(
        _ commands: [EditCommand],
        to project: Project
    ) throws -> Project {
        var result = project
        for command in commands {
            result = try applyUnchecked(command, to: result)
        }
        return result
    }
}
