// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct BladeClipEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let atTime: RationalTime
        let rightClipID: UUID
    }

    struct RippleTrimClipEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let sourceRange: TimeRange
        let timelineRange: TimeRange
        let linkedClipEditMode: LinkedClipEditMode
    }

    struct RollEdit {
        let sequenceID: UUID
        let trackID: UUID
        let leftClipID: UUID
        let rightClipID: UUID
        let editTime: RationalTime
    }

    struct SlipClipEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let sourceRange: TimeRange
        let linkedClipEditMode: LinkedClipEditMode
    }

    struct SlideClipEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let timelineRange: TimeRange
        let linkedClipEditMode: LinkedClipEditMode
    }

    struct RollClipSelection {
        let leftIndex: Int
        let leftClip: Clip
        let rightIndex: Int
        let rightClip: Clip
    }

    struct RollClipRanges {
        let leftSourceRange: TimeRange
        let leftTimelineRange: TimeRange
        let rightSourceRange: TimeRange
        let rightTimelineRange: TimeRange
    }

    static func bladeClip(_ edit: BladeClipEdit, in project: Project) throws -> Project {
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

            let clipEnd = try exactTime { try clip.timelineRange.end() }
            guard edit.atTime > clip.timelineRange.start, edit.atTime < clipEnd else {
                throw EditReducerError.invalidEdit(
                    .bladeTimeOutsideClip(clipID: edit.clipID, atTime: edit.atTime)
                )
            }
            try rejectBladeInsideCrossfadeRegion(clip: clip, atTime: edit.atTime)
            try rejectBladeInsideVideoTransitionRegion(clip: clip, atTime: edit.atTime)

            let halves = try bladeHalves(of: clip, edit: edit, clipEnd: clipEnd)
            items[index] = .clip(halves.left)
            items.insert(.clip(halves.right), at: index + 1)
            repointBladeMirror(
                &items,
                record: clip.audioMix.trailingCrossfade,
                from: clip.id,
                to: edit.rightClipID
            )
            repointBladeVideoTransitionMirror(
                &items,
                record: clip.trailingTransition,
                from: clip.id,
                to: edit.rightClipID
            )
            return try maintainingCutEdgeMetadata(
                copying(track, items: sortedItems(items)),
                in: project
            )
        }
    }

    /// Splits `clip` at the blade point. Per the ADR-0015 §8 blade row the leading
    /// crossfade record stays on the left half and the trailing record moves to the right
    /// half; the new cut itself gets no automatic crossfade.
    ///
    /// The split is retime-aware (FR-SPD-002/003) and animation-aware (FR-XFORM-008): the
    /// source range splits direction-aware for reverse and freeze, a time-remap curve is
    /// split at the blade offset with the right half re-anchored to local time zero, and
    /// keyframed transform/effects animations split at the cut with shared boundary
    /// keyframes so the rendered output is unchanged by the blade.
    static func bladeHalves(
        of clip: Clip,
        edit: BladeClipEdit,
        clipEnd: RationalTime
    ) throws -> (left: Clip, right: Clip) {
        let leftDuration = try subtractTimes(edit.atTime, clip.timelineRange.start)
        let rightDuration = try subtractTimes(clipEnd, edit.atTime)
        let sourceRanges = try bladeSourceRanges(
            of: clip,
            leftDuration: leftDuration,
            rightDuration: rightDuration
        )
        let remapHalves = try bladeTimeRemapHalves(of: clip, leftDuration: leftDuration)
        let animation = try bladeAnimationHalves(of: clip, at: edit.atTime)
        let sources = try bladeTitleSources(of: clip, at: edit.atTime)
        let leftClip = copying(
            clip,
            source: sources.left,
            sourceRange: sourceRanges.left,
            timelineRange: try makeRange(
                start: clip.timelineRange.start,
                duration: leftDuration
            ),
            transformAnimation: animation.leftTransform,
            effectsAnimation: animation.leftEffects,
            effectStackAnimation: animation.leftEffectStack,
            audioMix: bladeLeftAudioMix(clip.audioMix),
            leadingTransition: .some(clip.leadingTransition),
            trailingTransition: .some(nil),
            timeRemap: .some(remapHalves?.left)
        )
        let rightClip = Clip(
            id: edit.rightClipID,
            source: sources.right,
            sourceRange: sourceRanges.right,
            timelineRange: try makeRange(start: edit.atTime, duration: rightDuration),
            kind: clip.kind,
            name: "\(clip.name) 2",
            transform: clip.transform,
            transformAnimation: animation.rightTransform,
            effects: clip.effects,
            effectsAnimation: animation.rightEffects,
            effectStack: clip.effectStack,
            effectStackAnimation: animation.rightEffectStack,
            audioMix: bladeRightAudioMix(clip.audioMix),
            leadingTransition: nil,
            trailingTransition: clip.trailingTransition,
            speed: clip.speed,
            reverse: clip.reverse,
            freezeFrame: clip.freezeFrame,
            timeRemap: remapHalves?.right,
            frameSampling: clip.frameSampling
        )
        return (left: leftClip, right: rightClip)
    }

    /// Blades title `revealFraction` keyframes with the same boundary rules as transform
    /// animation (FR-TXT-004 / FR-XFORM-008). Non-title sources pass through unchanged.
    static func bladeTitleSources(
        of clip: Clip,
        at cut: RationalTime
    ) throws -> (left: ClipSource, right: ClipSource) {
        guard case .title(let title) = clip.source else {
            return (clip.source, clip.source)
        }
        let split = try exactTime { try title.revealFraction.bladed(at: cut) }
        return (
            left: .title(title.withRevealFraction(split.left)),
            right: .title(title.withRevealFraction(split.right))
        )
    }

    /// The left half keeps the start-edge audio metadata: gain/pan automation, `fadeIn`,
    /// and the leading crossfade record (ADR-0015 §8 blade row).
    static func bladeLeftAudioMix(_ mix: ClipAudioMix) -> ClipAudioMix {
        copying(mix, fadeOut: ClipAudioFade.none, trailingCrossfade: .some(nil))
    }

    /// The right half keeps the end-edge audio metadata: gain/pan automation, `fadeOut`,
    /// and the trailing crossfade record (ADR-0015 §8 blade row).
    static func bladeRightAudioMix(_ mix: ClipAudioMix) -> ClipAudioMix {
        copying(mix, fadeIn: ClipAudioFade.none, leadingCrossfade: .some(nil))
    }

    static func rippleTrimClipWithoutLinkedPartners(
        _ edit: RippleTrimClipEdit,
        in project: Project
    ) throws -> Project {
        try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
            var items: [TimelineItem] = []
            guard
                let clipIndex = clipIndex(edit.clipID, in: track.items),
                case .clip(let clip) = track.items[clipIndex]
            else {
                throw EditReducerError.clipNotFound(
                    sequenceID: edit.sequenceID,
                    trackID: edit.trackID,
                    clipID: edit.clipID
                )
            }

            try validateMatchingDurations(
                clipID: edit.clipID,
                sourceRange: edit.sourceRange,
                timelineRange: edit.timelineRange,
                speed: clip.speed
            )
            let oldEnd = try exactTime { try clip.timelineRange.end() }
            let newEnd = try exactTime { try edit.timelineRange.end() }
            let downstreamOffset = try subtractTimes(newEnd, oldEnd)

            for itemIndex in track.items.indices {
                let item = track.items[itemIndex]
                if itemIndex == clipIndex {
                    items.append(
                        .clip(
                            copying(
                                clip,
                                sourceRange: edit.sourceRange,
                                timelineRange: edit.timelineRange
                            )
                        )
                    )
                } else if item.timelineRange.start >= oldEnd {
                    items.append(try offsetItem(item, by: downstreamOffset))
                } else {
                    items.append(item)
                }
            }

            return try maintainingCutEdgeMetadata(
                copying(track, items: sortedItems(items)),
                in: project
            )
        }
    }

    static func rollEdit(_ edit: RollEdit, in project: Project) throws -> Project {
        try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
            var items = track.items
            let selection = try rollClipSelection(edit, in: items)
            let ranges = try rollClipRanges(edit, selection: selection)
            items[selection.leftIndex] = .clip(
                copying(
                    selection.leftClip,
                    sourceRange: ranges.leftSourceRange,
                    timelineRange: ranges.leftTimelineRange
                )
            )
            items[selection.rightIndex] = .clip(
                copying(
                    selection.rightClip,
                    sourceRange: ranges.rightSourceRange,
                    timelineRange: ranges.rightTimelineRange
                )
            )
            return try maintainingCutEdgeMetadata(
                copying(track, items: sortedItems(items)),
                in: project
            )
        }
    }

    static func rollClipSelection(
        _ edit: RollEdit,
        in items: [TimelineItem]
    ) throws -> RollClipSelection {
        guard
            let leftIndex = clipIndex(edit.leftClipID, in: items),
            case .clip(let leftClip) = items[leftIndex]
        else {
            throw EditReducerError.clipNotFound(
                sequenceID: edit.sequenceID,
                trackID: edit.trackID,
                clipID: edit.leftClipID
            )
        }
        guard
            let rightIndex = clipIndex(edit.rightClipID, in: items),
            case .clip(let rightClip) = items[rightIndex]
        else {
            throw EditReducerError.clipNotFound(
                sequenceID: edit.sequenceID,
                trackID: edit.trackID,
                clipID: edit.rightClipID
            )
        }

        return RollClipSelection(
            leftIndex: leftIndex,
            leftClip: leftClip,
            rightIndex: rightIndex,
            rightClip: rightClip
        )
    }

    static func slipClipWithoutLinkedPartners(
        _ edit: SlipClipEdit,
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

            try validateMatchingDurations(
                clipID: edit.clipID,
                sourceRange: edit.sourceRange,
                timelineRange: clip.timelineRange,
                speed: clip.speed
            )
            items[index] = .clip(copying(clip, sourceRange: edit.sourceRange))
            return try maintainingCutEdgeMetadata(
                copying(track, items: sortedItems(items)),
                in: project
            )
        }
    }

    static func slideClipWithoutLinkedPartners(
        _ edit: SlideClipEdit,
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
            guard index > items.startIndex, index < items.index(before: items.endIndex) else {
                throw EditReducerError.invalidEdit(.slideRequiresNeighbors(clipID: edit.clipID))
            }
            try validateMatchingDurations(
                clipID: edit.clipID,
                sourceRange: clip.sourceRange,
                timelineRange: edit.timelineRange,
                speed: clip.speed
            )

            let previousIndex = items.index(before: index)
            let nextIndex = items.index(after: index)
            let previous = items[previousIndex]
            let next = items[nextIndex]
            let newEnd = try exactTime { try edit.timelineRange.end() }
            let nextEnd = try exactTime { try next.timelineRange.end() }
            let previousDuration = try subtractTimes(
                edit.timelineRange.start,
                previous.timelineRange.start
            )
            let nextDuration = try subtractTimes(nextEnd, newEnd)
            guard previousDuration > .zero, nextDuration > .zero else {
                throw EditReducerError.invalidEdit(.nonPositiveDuration(clipID: edit.clipID))
            }

            items[previousIndex] = try adjustingItemEnd(previous, end: edit.timelineRange.start)
            // Slide body-moves the middle clip; neighbor edges are trims (no animation rebase).
            items[index] = .clip(try relocating(clip, timelineRange: edit.timelineRange))
            items[nextIndex] = try adjustingItemStart(next, start: newEnd)
            return try maintainingCutEdgeMetadata(
                copying(track, items: sortedItems(items)),
                in: project
            )
        }
    }

    static func rippleDeleteClip(
        clipID: UUID,
        sequenceID: UUID,
        trackID: UUID,
        in project: Project
    ) throws -> Project {
        try replacingTrack(trackID, sequenceID: sequenceID, in: project) { track in
            var items: [TimelineItem] = []
            guard
                let removedIndex = clipIndex(clipID, in: track.items),
                case .clip(let removedClip) = track.items[removedIndex]
            else {
                throw EditReducerError.clipNotFound(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID
                )
            }

            let removedEnd = try exactTime { try removedClip.timelineRange.end() }
            let offset = try negatedTime(removedClip.timelineRange.duration)
            for itemIndex in track.items.indices {
                if itemIndex == removedIndex {
                    continue
                }
                let item = track.items[itemIndex]
                if item.timelineRange.start >= removedEnd {
                    items.append(try offsetItem(item, by: offset))
                } else {
                    items.append(item)
                }
            }
            // ADR-0015 §8: the deleted clip's pairs and mirrors are removed; the newly
            // abutting neighbors get no automatic crossfade.
            return try maintainingCutEdgeMetadata(
                copying(track, items: sortedItems(items)),
                in: project
            )
        }
    }

    static func liftClip(
        clipID: UUID,
        sequenceID: UUID,
        trackID: UUID,
        in project: Project
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

            items[index] = .gap(clip.timelineRange)
            // ADR-0015 §8: the gap breaks adjacency, so the lifted clip's pairs vanish
            // with it and the neighbors' mirrors are cleared.
            return try maintainingCutEdgeMetadata(
                copying(track, items: sortedItems(items)),
                in: project
            )
        }
    }
}
