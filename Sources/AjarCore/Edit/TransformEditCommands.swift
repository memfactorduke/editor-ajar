// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct SetClipTransformEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let transform: ClipTransform
    }

    static func setClipTransform(
        _ edit: SetClipTransformEdit,
        in project: Project
    ) throws -> Project {
        try validateTransform(
            edit.transform,
            clipID: edit.clipID,
            frame: project.settings.resolution
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

            items[index] = .clip(copying(clip, transform: edit.transform))
            return copying(track, items: items)
        }
    }

    static func validateTransform(
        _ transform: ClipTransform,
        clipID: UUID,
        frame: PixelDimensions
    ) throws {
        guard let error = ClipTransformValidator.errors(for: transform, frame: frame).first else {
            return
        }

        throw EditReducerError.invalidEdit(
            .invalidClipTransform(clipID: clipID, error: error)
        )
    }
}
