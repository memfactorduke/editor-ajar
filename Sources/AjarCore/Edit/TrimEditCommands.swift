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
    }

    struct SlideClipEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let timelineRange: TimeRange
    }

    struct RollClipSelection {
        let leftIndex: Int
        let leftClip: Clip
        let rightIndex: Int
        let rightClip: Clip
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

            let leftDuration = try subtractTimes(edit.atTime, clip.timelineRange.start)
            let rightDuration = try subtractTimes(clipEnd, edit.atTime)
            let rightSourceStart = try addTimes(clip.sourceRange.start, leftDuration)
            let leftClip = copying(
                clip,
                sourceRange: try makeRange(start: clip.sourceRange.start, duration: leftDuration),
                timelineRange: try makeRange(
                    start: clip.timelineRange.start,
                    duration: leftDuration
                )
            )
            let rightClip = Clip(
                id: edit.rightClipID,
                source: clip.source,
                sourceRange: try makeRange(start: rightSourceStart, duration: rightDuration),
                timelineRange: try makeRange(start: edit.atTime, duration: rightDuration),
                kind: clip.kind,
                name: "\(clip.name) 2"
            )

            items[index] = .clip(leftClip)
            items.insert(.clip(rightClip), at: index + 1)
            return copying(track, items: sortedItems(items))
        }
    }

    static func rippleTrimClip(
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
                timelineRange: edit.timelineRange
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

            return copying(track, items: sortedItems(items))
        }
    }

    static func rollEdit(_ edit: RollEdit, in project: Project) throws -> Project {
        try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
            var items = track.items
            let selection = try rollClipSelection(edit, in: items)
            let leftClip = selection.leftClip
            let rightClip = selection.rightClip

            let leftEnd = try exactTime { try leftClip.timelineRange.end() }
            let rightEnd = try exactTime { try rightClip.timelineRange.end() }
            guard leftEnd == rightClip.timelineRange.start else {
                throw EditReducerError.invalidEdit(
                    .clipsNotAdjacent(
                        leftClipID: edit.leftClipID,
                        rightClipID: edit.rightClipID
                    )
                )
            }
            guard edit.editTime > leftClip.timelineRange.start, edit.editTime < rightEnd else {
                throw EditReducerError.invalidEdit(.nonPositiveDuration(clipID: edit.leftClipID))
            }

            let leftDuration = try subtractTimes(edit.editTime, leftClip.timelineRange.start)
            let rightDuration = try subtractTimes(rightEnd, edit.editTime)
            let rightSourceDelta = try subtractTimes(edit.editTime, rightClip.timelineRange.start)
            let rightSourceStart = try addTimes(rightClip.sourceRange.start, rightSourceDelta)
            items[selection.leftIndex] = .clip(
                copying(
                    leftClip,
                    sourceRange: try makeRange(
                        start: leftClip.sourceRange.start,
                        duration: leftDuration
                    ),
                    timelineRange: try makeRange(
                        start: leftClip.timelineRange.start,
                        duration: leftDuration
                    )
                )
            )
            items[selection.rightIndex] = .clip(
                copying(
                    rightClip,
                    sourceRange: try makeRange(start: rightSourceStart, duration: rightDuration),
                    timelineRange: try makeRange(start: edit.editTime, duration: rightDuration)
                )
            )
            return copying(track, items: sortedItems(items))
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

    static func slipClip(_ edit: SlipClipEdit, in project: Project) throws -> Project {
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
                timelineRange: clip.timelineRange
            )
            items[index] = .clip(copying(clip, sourceRange: edit.sourceRange))
            return copying(track, items: sortedItems(items))
        }
    }

    static func slideClip(_ edit: SlideClipEdit, in project: Project) throws -> Project {
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
                timelineRange: edit.timelineRange
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
            items[index] = .clip(copying(clip, timelineRange: edit.timelineRange))
            items[nextIndex] = try adjustingItemStart(next, start: newEnd)
            return copying(track, items: sortedItems(items))
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
            return copying(track, items: sortedItems(items))
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
            return copying(track, items: sortedItems(items))
        }
    }
}

extension EditReducer {
    static func validateMatchingDurations(
        clipID: UUID,
        sourceRange: TimeRange,
        timelineRange: TimeRange
    ) throws {
        guard sourceRange.duration == timelineRange.duration else {
            throw EditReducerError.invalidEdit(
                .durationMismatch(
                    clipID: clipID,
                    sourceDuration: sourceRange.duration,
                    timelineDuration: timelineRange.duration
                )
            )
        }
        guard timelineRange.duration > .zero else {
            throw EditReducerError.invalidEdit(.nonPositiveDuration(clipID: clipID))
        }
    }

    static func adjustingItemEnd(_ item: TimelineItem, end: RationalTime) throws -> TimelineItem {
        let duration = try subtractTimes(end, item.timelineRange.start)
        switch item {
        case .clip(let clip):
            let sourceRange = try makeRange(
                start: clip.sourceRange.start,
                duration: duration
            )
            let timelineRange = try makeRange(
                start: clip.timelineRange.start,
                duration: duration
            )
            return .clip(
                copying(
                    clip,
                    sourceRange: sourceRange,
                    timelineRange: timelineRange
                )
            )
        case .gap:
            return .gap(try makeRange(start: item.timelineRange.start, duration: duration))
        case .transition(let transition):
            let timelineRange = try makeRange(
                start: item.timelineRange.start,
                duration: duration
            )
            return .transition(
                Transition(
                    id: transition.id,
                    timelineRange: timelineRange,
                    kind: transition.kind,
                    name: transition.name
                )
            )
        }
    }

    static func adjustingItemStart(
        _ item: TimelineItem,
        start: RationalTime
    ) throws -> TimelineItem {
        let itemEnd = try exactTime { try item.timelineRange.end() }
        let duration = try subtractTimes(itemEnd, start)
        switch item {
        case .clip(let clip):
            let sourceDelta = try subtractTimes(start, clip.timelineRange.start)
            let sourceStart = try addTimes(clip.sourceRange.start, sourceDelta)
            return .clip(
                copying(
                    clip,
                    sourceRange: try makeRange(start: sourceStart, duration: duration),
                    timelineRange: try makeRange(start: start, duration: duration)
                )
            )
        case .gap:
            return .gap(try makeRange(start: start, duration: duration))
        case .transition(let transition):
            return .transition(
                Transition(
                    id: transition.id,
                    timelineRange: try makeRange(start: start, duration: duration),
                    kind: transition.kind,
                    name: transition.name
                )
            )
        }
    }

    static func addTimes(_ left: RationalTime, _ right: RationalTime) throws -> RationalTime {
        try exactTime { try left.adding(right) }
    }

    static func subtractTimes(_ left: RationalTime, _ right: RationalTime) throws -> RationalTime {
        try exactTime { try left.subtracting(right) }
    }

    static func negatedTime(_ time: RationalTime) throws -> RationalTime {
        try exactTime { try time.negated() }
    }
}
