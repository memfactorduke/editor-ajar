// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct SetClipChromaKeyEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let settings: ClipChromaKeySettings
    }

    struct SetClipColorCorrectionEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let correction: ClipColorCorrection
    }

    struct ClipEffectsEditTarget {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
    }

    struct ClipMaskEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let mask: ClipMask
    }

    struct RemoveClipMaskEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let maskID: UUID
    }

    struct MoveClipMaskEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let maskID: UUID
        let destinationIndex: Int
    }

    static func setClipChromaKey(
        _ edit: SetClipChromaKeyEdit,
        in project: Project
    ) throws -> Project {
        try updateClipEffects(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            clip.effects.replacing(chromaKey: edit.settings)
        }
    }

    static func setClipColorCorrection(
        _ edit: SetClipColorCorrectionEdit,
        in project: Project
    ) throws -> Project {
        try updateClipEffects(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            clip.effects.replacing(colorCorrection: edit.correction)
        }
    }

    static func clearClipColorCorrection(
        _ edit: ClipEffectsEditTarget,
        in project: Project
    ) throws -> Project {
        try updateClipEffects(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            clip.effects.replacing(colorCorrection: .identity)
        }
    }

    static func addClipMask(
        _ edit: ClipMaskEdit,
        in project: Project
    ) throws -> Project {
        try updateClipEffects(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            clip.effects.replacing(masks: clip.effects.masks + [edit.mask])
        }
    }

    static func removeClipMask(
        _ edit: RemoveClipMaskEdit,
        in project: Project
    ) throws -> Project {
        try updateClipEffects(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            var masks = clip.effects.masks
            guard let index = masks.firstIndex(where: { mask in mask.id == edit.maskID }) else {
                throw EditReducerError.invalidEdit(
                    .clipMaskNotFound(clipID: edit.clipID, maskID: edit.maskID)
                )
            }

            masks.remove(at: index)
            return clip.effects.replacing(masks: masks)
        }
    }

    static func moveClipMask(
        _ edit: MoveClipMaskEdit,
        in project: Project
    ) throws -> Project {
        try updateClipEffects(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            var masks = clip.effects.masks
            guard let sourceIndex = masks.firstIndex(where: { mask in mask.id == edit.maskID }) else {
                throw EditReducerError.invalidEdit(
                    .clipMaskNotFound(clipID: edit.clipID, maskID: edit.maskID)
                )
            }
            guard masks.indices.contains(edit.destinationIndex) else {
                throw EditReducerError.invalidEdit(
                    .clipMaskDestinationIndexOutOfRange(
                        clipID: edit.clipID,
                        index: edit.destinationIndex,
                        count: masks.count
                    )
                )
            }

            let mask = masks.remove(at: sourceIndex)
            masks.insert(mask, at: edit.destinationIndex)
            return clip.effects.replacing(masks: masks)
        }
    }

    static func setClipMask(
        _ edit: ClipMaskEdit,
        in project: Project
    ) throws -> Project {
        try updateClipEffects(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            var masks = clip.effects.masks
            guard let index = masks.firstIndex(where: { mask in mask.id == edit.mask.id }) else {
                throw EditReducerError.invalidEdit(
                    .clipMaskNotFound(clipID: edit.clipID, maskID: edit.mask.id)
                )
            }

            masks[index] = edit.mask
            return clip.effects.replacing(masks: masks)
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

    private static func updateClipEffects(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        in project: Project,
        update: (Clip) throws -> ClipEffects
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

            let effects = try update(clip)
            try validateEffects(effects, clipID: clipID)
            items[index] = .clip(copying(clip, effects: effects))
            return copying(track, items: items)
        }
    }
}
