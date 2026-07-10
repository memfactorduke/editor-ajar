// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct InsertTitleClipEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let title: TitleSource
        let timelineRange: TimeRange
        let name: String
    }

    struct SetClipTitleSourceEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let title: TitleSource
    }

    struct SetTitleTextBoxEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let box: TitleTextBox
    }

    struct RemoveTitleTextBoxEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let boxID: UUID
    }

    struct ApplyTitleAnimationPresetEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let preset: TitleAnimationPreset
    }

    /// Dispatches FR-TXT-001/004 title edit commands (routed from `applyUnchecked`).
    static func applyTitleClipCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .insertTitleClip(
            let sequenceID, let trackID, let clipID, let title, let timelineRange, let name
        ):
            return try insertTitleClip(
                InsertTitleClipEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    title: title,
                    timelineRange: timelineRange,
                    name: name
                ),
                in: project
            )
        case .setClipTitleSource(let sequenceID, let trackID, let clipID, let title):
            return try setClipTitleSource(
                SetClipTitleSourceEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    title: title
                ),
                in: project
            )
        case .setTitleTextBox(let sequenceID, let trackID, let clipID, let box):
            return try setTitleTextBox(
                SetTitleTextBoxEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    box: box
                ),
                in: project
            )
        case .removeTitleTextBox(let sequenceID, let trackID, let clipID, let boxID):
            return try removeTitleTextBox(
                RemoveTitleTextBoxEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    boxID: boxID
                ),
                in: project
            )
        case .applyTitleAnimationPreset(let sequenceID, let trackID, let clipID, let preset):
            return try applyTitleAnimationPreset(
                ApplyTitleAnimationPresetEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    preset: preset
                ),
                in: project
            )
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    static func insertTitleClip(
        _ edit: InsertTitleClipEdit,
        in project: Project
    ) throws -> Project {
        if let error = edit.title.validate() {
            throw EditReducerError.invalidEdit(
                .invalidTitleSource(clipID: edit.clipID, error: error)
            )
        }
        guard edit.timelineRange.duration > .zero else {
            throw EditReducerError.invalidEdit(.nonPositiveDuration(clipID: edit.clipID))
        }

        let clip = Clip(
            id: edit.clipID,
            source: .title(edit.title),
            sourceRange: try makeRange(start: .zero, duration: edit.timelineRange.duration),
            timelineRange: edit.timelineRange,
            kind: .video,
            name: edit.name
        )
        return try insertClip(
            clip,
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            in: project
        )
    }

    static func setClipTitleSource(
        _ edit: SetClipTitleSourceEdit,
        in project: Project
    ) throws -> Project {
        if let error = edit.title.validate() {
            throw EditReducerError.invalidEdit(
                .invalidTitleSource(clipID: edit.clipID, error: error)
            )
        }
        return try updateTitleClip(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { _ in
            edit.title
        }
    }

    static func setTitleTextBox(
        _ edit: SetTitleTextBoxEdit,
        in project: Project
    ) throws -> Project {
        return try updateTitleClip(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { title in
            let next = title.replacing(box: edit.box)
            if let error = next.validate() {
                throw EditReducerError.invalidEdit(
                    .invalidTitleSource(clipID: edit.clipID, error: error)
                )
            }
            return next
        }
    }

    static func removeTitleTextBox(
        _ edit: RemoveTitleTextBoxEdit,
        in project: Project
    ) throws -> Project {
        return try updateTitleClip(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { title in
            guard title.boxes.contains(where: { $0.id == edit.boxID }) else {
                throw EditReducerError.invalidEdit(
                    .titleTextBoxNotFound(clipID: edit.clipID, boxID: edit.boxID)
                )
            }
            return title.removingBox(id: edit.boxID)
        }
    }

    /// Applies a FR-TXT-004 preset as one undoable edit.
    ///
    /// The preset **resets the clip's whole transform animation and reveal program** to that
    /// preset's clean keyframe program (not a selective merge of channels). Prior user-authored
    /// position/rotation/scale/opacity/reveal keyframes are discarded. Apply-twice is therefore
    /// idempotent for the same program. Undo restores the previous transform animation and
    /// reveal state in full.
    static func applyTitleAnimationPreset(
        _ edit: ApplyTitleAnimationPresetEdit,
        in project: Project
    ) throws -> Project {
        try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
            guard track.kind == .video else {
                throw EditReducerError.invalidEdit(
                    .titleRequiresVideoTrack(clipID: edit.clipID, trackKind: track.kind)
                )
            }
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
            guard case .title(let title) = clip.source else {
                throw EditReducerError.invalidEdit(
                    .titleRequiresTitleClip(clipID: edit.clipID)
                )
            }
            try validateTitleAnimationPreset(edit.preset, clip: clip)
            let program = try TitleAnimationPresetBuilder.program(
                for: edit.preset,
                clip: clip,
                title: title,
                frame: project.settings.resolution
            )
            if let error = program.title.validate() {
                throw EditReducerError.invalidEdit(
                    .invalidTitleSource(clipID: edit.clipID, error: error)
                )
            }
            items[index] = .clip(
                copying(
                    clip,
                    source: .title(program.title),
                    transform: program.transform,
                    transformAnimation: program.transformAnimation
                )
            )
            return copying(track, items: items)
        }
    }

    private static func validateTitleAnimationPreset(
        _ preset: TitleAnimationPreset,
        clip: Clip
    ) throws {
        if preset.duration <= .zero {
            throw EditReducerError.invalidEdit(
                .titleAnimationPresetNonPositiveDuration(
                    clipID: clip.id,
                    duration: preset.duration
                )
            )
        }
        if preset.duration > clip.timelineRange.duration {
            throw EditReducerError.invalidEdit(
                .titleAnimationPresetDurationExceedsClip(
                    clipID: clip.id,
                    duration: preset.duration,
                    clipDuration: clip.timelineRange.duration
                )
            )
        }
    }

    private static func updateTitleClip(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        in project: Project,
        transform: (TitleSource) throws -> TitleSource
    ) throws -> Project {
        try replacingTrack(trackID, sequenceID: sequenceID, in: project) { track in
            guard track.kind == .video else {
                throw EditReducerError.invalidEdit(
                    .titleRequiresVideoTrack(clipID: clipID, trackKind: track.kind)
                )
            }
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
            guard case .title(let title) = clip.source else {
                throw EditReducerError.invalidEdit(.titleRequiresTitleClip(clipID: clipID))
            }
            let nextTitle = try transform(title)
            items[index] = .clip(copying(clip, source: .title(nextTitle)))
            return copying(track, items: items)
        }
    }
}
