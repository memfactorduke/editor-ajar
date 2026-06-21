// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct SetClipChromaKeyEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let settings: ClipChromaKeySettings
    }

    static func setClipChromaKey(
        _ edit: SetClipChromaKeyEdit,
        in project: Project
    ) throws -> Project {
        try validateEffects(
            ClipEffects(chromaKey: edit.settings),
            clipID: edit.clipID
        )

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

            let effects = clip.effects.replacing(chromaKey: edit.settings)
            items[index] = .clip(copying(clip, effects: effects))
            return copying(track, items: items)
        }
    }

    static func validateEffects(_ effects: ClipEffects, clipID: UUID) throws {
        guard let error = ClipEffectsValidator.errors(for: effects).first else {
            return
        }

        throw EditReducerError.invalidEdit(
            .invalidClipEffects(clipID: clipID, error: error)
        )
    }
}
