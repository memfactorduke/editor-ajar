// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How a three-point edit places its source range on the timeline.
public enum ThreePointEditMode: String, Codable, Equatable, Sendable {
    /// Insert at the timeline target and ripple later items right.
    case insert

    /// Overwrite the timeline target range without rippling later items.
    case overwrite
}

extension EditReducer {
    struct ReplaceClipSourceEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let source: ClipSource
        let sourceRange: TimeRange
    }

    struct ThreePointEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let source: ClipSource
        let sourceRange: TimeRange
        let timelineStart: RationalTime
        let kind: TrackKind
        let name: String
        let mode: ThreePointEditMode
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func applyClipCommand(_ command: EditCommand, to project: Project) throws -> Project {
        switch command {
        case .insertCompoundClip, .makeCompoundClip, .decomposeCompoundClip:
            return try applyCompoundClipCommand(command, to: project)
        case .insertClip, .overwriteClip, .appendClip, .replaceClipSource, .threePointEdit,
            .addClip, .removeClip:
            return try applyCoreClipCommand(command, to: project)
        case .bladeClip, .rippleTrimClip, .rollEdit, .slipClip, .slideClip,
            .rippleDeleteClip, .liftClip:
            return try applyTrimClipCommand(command, to: project)
        case .moveClip, .trimClip:
            return try applyRangeClipCommand(command, to: project)
        case .setClipSpeed:
            return try applyClipSpeedCommand(command, to: project)
        case .setClipTransform, .addClipTransformKeyframe, .moveClipTransformKeyframe,
            .deleteClipTransformKeyframe, .setClipChromaKey, .setClipColorCorrection,
            .clearClipColorCorrection, .setClipLumaKey, .clearClipLumaKey:
            return try applyTransformClipCommand(command, to: project)
        case .addClipMask, .removeClipMask, .moveClipMask, .setClipMask:
            return try applyClipMaskCommand(command, to: project)
        case .addClipEffectNode, .removeClipEffectNode, .moveClipEffectNode,
            .setClipEffectNodeEnabled, .setClipEffectNodeParameters,
            .resetClipEffectNode, .resetClipEffectStack:
            return try applyClipEffectStackCommand(command, to: project)
        case .setClipAudioMix, .clearClipAudioMix, .setClipAudioRetimeMode:
            return try applyClipAudioMixCommand(command, to: project)
        case .setClipAudioCrossfade, .removeClipAudioCrossfade:
            return try applyClipAudioCrossfadeCommand(command, to: project)
        case .setClipVideoTransition, .removeClipVideoTransition:
            return try applyClipVideoTransitionCommand(command, to: project)
        case .detachClipAudio, .replaceClipAudioSource:
            return try applyClipAudioSourceCommand(command, to: project)
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    static func applyClipMaskCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .addClipMask(let sequenceID, let trackID, let clipID, let mask):
            return try addClipMask(
                ClipMaskEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    mask: mask
                ),
                in: project
            )
        case .removeClipMask(let sequenceID, let trackID, let clipID, let maskID):
            return try removeClipMask(
                RemoveClipMaskEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    maskID: maskID
                ),
                in: project
            )
        case .moveClipMask(
            let sequenceID,
            let trackID,
            let clipID,
            let maskID,
            let destinationIndex
        ):
            return try moveClipMask(
                MoveClipMaskEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    maskID: maskID,
                    destinationIndex: destinationIndex
                ),
                in: project
            )
        case .setClipMask(let sequenceID, let trackID, let clipID, let mask):
            return try setClipMask(
                ClipMaskEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    mask: mask
                ),
                in: project
            )
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    static func applyTransformKeyframeCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .addClipTransformKeyframe(
            let sequenceID,
            let trackID,
            let clipID,
            let parameter,
            let keyframe
        ):
            return try addClipTransformKeyframe(
                TransformKeyframeEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    parameter: parameter,
                    keyframe: keyframe
                ),
                in: project
            )
        case .moveClipTransformKeyframe(
            let sequenceID,
            let trackID,
            let clipID,
            let parameter,
            let fromTime,
            let keyframe
        ):
            return try moveClipTransformKeyframe(
                MoveTransformKeyframeEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    parameter: parameter,
                    fromTime: fromTime,
                    keyframe: keyframe
                ),
                in: project
            )
        case .deleteClipTransformKeyframe(
            let sequenceID,
            let trackID,
            let clipID,
            let parameter,
            let time
        ):
            return try deleteClipTransformKeyframe(
                DeleteTransformKeyframeEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    parameter: parameter,
                    time: time
                ),
                in: project
            )
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    static func applyCoreClipCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .insertClip(let sequenceID, let trackID, let clip):
            return try insertClip(clip, sequenceID: sequenceID, trackID: trackID, in: project)
        case .overwriteClip(let sequenceID, let trackID, let clip):
            return try overwriteClip(
                clip,
                sequenceID: sequenceID,
                trackID: trackID,
                in: project
            )
        case .appendClip(let sequenceID, let trackID, let clip):
            return try appendClip(clip, sequenceID: sequenceID, trackID: trackID, in: project)
        case .replaceClipSource(let sequenceID, let trackID, let clipID, let source, let range):
            return try replaceClipSource(
                ReplaceClipSourceEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    source: source,
                    sourceRange: range
                ),
                in: project
            )
        case .threePointEdit(
            let sequenceID,
            let trackID,
            let clipID,
            let source,
            let sourceRange,
            let timelineStart,
            let kind,
            let name,
            let mode
        ):
            return try threePointEdit(
                ThreePointEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    source: source,
                    sourceRange: sourceRange,
                    timelineStart: timelineStart,
                    kind: kind,
                    name: name,
                    mode: mode
                ),
                in: project
            )
        case .addClip(let sequenceID, let trackID, let clip):
            return try addClip(clip, sequenceID: sequenceID, trackID: trackID, to: project)
        case .removeClip(let sequenceID, let trackID, let clipID):
            return try removeClip(
                clipID: clipID,
                sequenceID: sequenceID,
                trackID: trackID,
                from: project
            )
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    static func applyRangeClipCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .moveClip(
            let sequenceID,
            let sourceTrackID,
            let clipID,
            let destinationTrackID,
            let timelineRange,
            let linkedClipEditMode
        ):
            return try moveClip(
                MoveClipEdit(
                    clipID: clipID,
                    sequenceID: sequenceID,
                    sourceTrackID: sourceTrackID,
                    destinationTrackID: destinationTrackID,
                    timelineRange: timelineRange,
                    linkedClipEditMode: linkedClipEditMode
                ),
                in: project
            )
        case .trimClip(
            let sequenceID,
            let trackID,
            let clipID,
            let sourceRange,
            let timelineRange,
            let linkedClipEditMode
        ):
            return try trimClip(
                TrimClipEdit(
                    clipID: clipID,
                    sequenceID: sequenceID,
                    trackID: trackID,
                    sourceRange: sourceRange,
                    timelineRange: timelineRange,
                    linkedClipEditMode: linkedClipEditMode
                ),
                in: project
            )
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    static func insertClip(
        _ clip: Clip,
        sequenceID: UUID,
        trackID: UUID,
        in project: Project
    ) throws -> Project {
        try replacingTrack(trackID, sequenceID: sequenceID, in: project) { track in
            var items: [TimelineItem] = []
            for item in track.items {
                if item.timelineRange.start >= clip.timelineRange.start {
                    items.append(try offsetItem(item, by: clip.timelineRange.duration))
                } else {
                    items.append(item)
                }
            }
            items.append(.clip(clip))
            return copying(track, items: sortedItems(items))
        }
    }

    static func overwriteClip(
        _ clip: Clip,
        sequenceID: UUID,
        trackID: UUID,
        in project: Project
    ) throws -> Project {
        try replacingTrack(trackID, sequenceID: sequenceID, in: project) { track in
            var items: [TimelineItem] = []
            for item in track.items {
                if try rangesIntersect(item.timelineRange, clip.timelineRange) {
                    continue
                }
                items.append(item)
            }
            items.append(.clip(clip))
            return copying(track, items: sortedItems(items))
        }
    }

    static func appendClip(
        _ clip: Clip,
        sequenceID: UUID,
        trackID: UUID,
        in project: Project
    ) throws -> Project {
        try replacingTrack(trackID, sequenceID: sequenceID, in: project) { track in
            let timelineStart = try endOfTrackItems(track.items)
            let timelineRange = try makeRange(
                start: timelineStart,
                duration: clip.timelineRange.duration
            )
            var items = track.items
            items.append(
                .clip(try relocating(clip, timelineRange: timelineRange))
            )
            return copying(track, items: sortedItems(items))
        }
    }

    static func replaceClipSource(
        _ edit: ReplaceClipSourceEdit,
        in project: Project
    ) throws -> Project {
        try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
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

            items[index] = .clip(
                copying(clip, source: edit.source, sourceRange: edit.sourceRange)
            )
            return copying(track, items: sortedItems(items))
        }
    }

    static func threePointEdit(_ edit: ThreePointEdit, in project: Project) throws -> Project {
        let clip = Clip(
            id: edit.clipID,
            source: edit.source,
            sourceRange: edit.sourceRange,
            timelineRange: try makeRange(
                start: edit.timelineStart,
                duration: edit.sourceRange.duration
            ),
            kind: edit.kind,
            name: edit.name
        )

        switch edit.mode {
        case .insert:
            return try insertClip(
                clip,
                sequenceID: edit.sequenceID,
                trackID: edit.trackID,
                in: project
            )
        case .overwrite:
            return try overwriteClip(
                clip,
                sequenceID: edit.sequenceID,
                trackID: edit.trackID,
                in: project
            )
        }
    }

}

extension EditReducer {
    static func offsetItem(_ item: TimelineItem, by duration: RationalTime) throws -> TimelineItem {
        switch item {
        case .clip(let clip):
            return .clip(
                try relocating(
                    clip,
                    timelineRange: try offsetRange(clip.timelineRange, by: duration)
                )
            )
        case .gap(let range):
            return .gap(try offsetRange(range, by: duration))
        case .transition(let transition):
            return .transition(
                Transition(
                    id: transition.id,
                    timelineRange: try offsetRange(transition.timelineRange, by: duration),
                    kind: transition.kind,
                    name: transition.name
                )
            )
        }
    }

    static func offsetRange(_ range: TimeRange, by duration: RationalTime) throws -> TimeRange {
        try makeRange(
            start: try exactTime { try range.start.adding(duration) },
            duration: range.duration
        )
    }

    static func endOfTrackItems(_ items: [TimelineItem]) throws -> RationalTime {
        var end = RationalTime.zero
        for item in items {
            let itemEnd = try exactTime { try item.timelineRange.end() }
            if itemEnd > end {
                end = itemEnd
            }
        }
        return end
    }

    static func rangesIntersect(_ left: TimeRange, _ right: TimeRange) throws -> Bool {
        try exactTime { try left.intersects(right) }
    }

    static func makeRange(start: RationalTime, duration: RationalTime) throws -> TimeRange {
        try exactTime { try TimeRange(start: start, duration: duration) }
    }

    static func exactTime<Value>(_ operation: () throws -> Value) throws -> Value {
        do {
            return try operation()
        } catch let error as RationalTimeError {
            throw EditReducerError.timeArithmeticFailed(error)
        }
    }
}
