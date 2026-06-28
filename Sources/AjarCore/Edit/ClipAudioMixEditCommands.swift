// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct SetClipAudioMixEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let audioMix: ClipAudioMix
    }

    struct ClipAudioMixEditTarget {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
    }

    static func applyClipAudioMixCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .setClipAudioMix(let sequenceID, let trackID, let clipID, let audioMix):
            return try setClipAudioMix(
                SetClipAudioMixEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    audioMix: audioMix
                ),
                in: project
            )
        case .clearClipAudioMix(let sequenceID, let trackID, let clipID):
            return try clearClipAudioMix(
                ClipAudioMixEditTarget(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID
                ),
                in: project
            )
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    static func setClipAudioMix(
        _ edit: SetClipAudioMixEdit,
        in project: Project
    ) throws -> Project {
        try updateClipAudioMix(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { _ in
            edit.audioMix
        }
    }

    static func clearClipAudioMix(
        _ edit: ClipAudioMixEditTarget,
        in project: Project
    ) throws -> Project {
        try updateClipAudioMix(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { _ in
            .identity
        }
    }

    static func validateAudioMix(_ audioMix: ClipAudioMix, clip: Clip) throws {
        guard let error = AudioMixValidator.errors(
            for: audioMix,
            clipID: clip.id,
            clipDuration: clip.timelineRange.duration
        ).first else {
            return
        }

        throw EditReducerError.invalidEdit(
            .invalidClipAudioMix(clipID: clip.id, error: error)
        )
    }

    private static func updateClipAudioMix(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        in project: Project,
        update: (Clip) throws -> ClipAudioMix
    ) throws -> Project {
        try replacingTrack(trackID, sequenceID: sequenceID, in: project) { track in
            var items = track.items
            guard
                let index = clipIndex(clipID, in: items),
                case .clip(let clip) = items[index]
            else {
                throw EditReducerError.clipNotFound(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID
                )
            }

            let audioMix = try update(clip)
            try validateAudioMix(audioMix, clip: clip)
            items[index] = .clip(copying(clip, audioMix: audioMix))
            return copying(track, items: items)
        }
    }
}
