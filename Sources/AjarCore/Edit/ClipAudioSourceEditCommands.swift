// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct DetachClipAudioEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
    }

    struct ReplaceClipAudioSourceEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let mediaID: UUID
    }

    static func applyClipAudioSourceCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .detachClipAudio(let sequenceID, let trackID, let clipID):
            return try detachClipAudio(
                DetachClipAudioEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID
                ),
                in: project
            )
        case .replaceClipAudioSource(let sequenceID, let trackID, let clipID, let mediaID):
            return try replaceClipAudioSource(
                ReplaceClipAudioSourceEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    mediaID: mediaID
                ),
                in: project
            )
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    static func detachClipAudio(
        _ edit: DetachClipAudioEdit,
        in project: Project
    ) throws -> Project {
        let sequence = try sequence(edit.sequenceID, in: project)
        let selectedLocation = try locateClip(
            ClipReference(trackID: edit.trackID, clipID: edit.clipID),
            in: sequence
        )

        guard let linkGroupID = selectedLocation.clip.linkGroupID else {
            throw EditReducerError.invalidEdit(
                .detachAudioRequiresLinkedAudio(clipID: edit.clipID)
            )
        }

        let groupLocations = clipLocations(in: sequence, linkGroupID: linkGroupID)
        guard groupLocations.contains(where: { $0.clip.kind == .video }),
              groupLocations.contains(where: { $0.clip.kind == .audio })
        else {
            throw EditReducerError.invalidEdit(
                .detachAudioRequiresLinkedAudio(clipID: edit.clipID)
            )
        }

        return try replacingSequence(in: project, sequenceID: edit.sequenceID) { sequence in
            var videoTracks = sequence.videoTracks
            var audioTracks = sequence.audioTracks
            for location in groupLocations {
                setClip(
                    copying(location.clip, linkGroupID: .some(nil)),
                    at: location,
                    videoTracks: &videoTracks,
                    audioTracks: &audioTracks
                )
            }
            return copying(sequence, videoTracks: videoTracks, audioTracks: audioTracks)
        }
    }

    static func replaceClipAudioSource(
        _ edit: ReplaceClipAudioSourceEdit,
        in project: Project
    ) throws -> Project {
        try validateReplacementAudioSource(edit.mediaID, in: project)

        return try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
            var items = track.items
            guard
                let index = clipIndex(edit.clipID, in: items),
                case .clip(let clip) = items[index]
            else {
                throw EditReducerError.clipNotFound(
                    sequenceID: edit.sequenceID,
                    trackID: edit.trackID,
                    clipID: edit.clipID
                )
            }

            guard clip.kind == .audio else {
                throw EditReducerError.invalidEdit(
                    .replaceAudioRequiresAudioClip(clipID: edit.clipID, kind: clip.kind)
                )
            }

            items[index] = .clip(copying(clip, source: .media(id: edit.mediaID)))
            return copying(track, items: sortedItems(items))
        }
    }

    static func validateReplacementAudioSource(_ mediaID: UUID, in project: Project) throws {
        guard let media = project.mediaPool.first(where: { $0.id == mediaID }) else {
            throw EditReducerError.invalidEdit(
                .replacementAudioSourceNotFound(mediaID: mediaID)
            )
        }

        guard let layout = media.metadata.audioChannelLayout,
              layout.channelCount > 0
        else {
            throw EditReducerError.invalidEdit(
                .replacementAudioSourceHasNoAudio(mediaID: mediaID)
            )
        }
    }
}
