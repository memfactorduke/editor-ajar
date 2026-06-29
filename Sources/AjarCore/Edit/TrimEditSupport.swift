// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    static func rollClipRanges(
        _ edit: RollEdit,
        selection: RollClipSelection
    ) throws -> RollClipRanges {
        let leftClip = selection.leftClip
        let rightClip = selection.rightClip
        let leftEnd = try exactTime { try leftClip.timelineRange.end() }
        let rightEnd = try exactTime { try rightClip.timelineRange.end() }
        guard leftEnd == rightClip.timelineRange.start else {
            throw EditReducerError.invalidEdit(
                .clipsNotAdjacent(leftClipID: edit.leftClipID, rightClipID: edit.rightClipID)
            )
        }
        guard edit.editTime > leftClip.timelineRange.start, edit.editTime < rightEnd else {
            throw EditReducerError.invalidEdit(.nonPositiveDuration(clipID: edit.leftClipID))
        }

        let leftDuration = try subtractTimes(edit.editTime, leftClip.timelineRange.start)
        let rightDuration = try subtractTimes(rightEnd, edit.editTime)
        let rightSourceDelta = try subtractTimes(edit.editTime, rightClip.timelineRange.start)
        let leftSourceDuration = try speedSourceDuration(
            clipID: leftClip.id,
            timelineDuration: leftDuration,
            speed: leftClip.speed
        )
        let rightSourceDuration = try speedSourceDuration(
            clipID: rightClip.id,
            timelineDuration: rightDuration,
            speed: rightClip.speed
        )
        let rightSourceStartDelta = try speedSourceDuration(
            clipID: rightClip.id,
            timelineDuration: rightSourceDelta,
            speed: rightClip.speed
        )
        let rightSourceStart = try addTimes(rightClip.sourceRange.start, rightSourceStartDelta)
        return try RollClipRanges(
            leftSourceRange: makeRange(
                start: leftClip.sourceRange.start,
                duration: leftSourceDuration
            ),
            leftTimelineRange: makeRange(
                start: leftClip.timelineRange.start,
                duration: leftDuration
            ),
            rightSourceRange: makeRange(start: rightSourceStart, duration: rightSourceDuration),
            rightTimelineRange: makeRange(start: edit.editTime, duration: rightDuration)
        )
    }

    static func validateMatchingDurations(
        clipID: UUID,
        sourceRange: TimeRange,
        timelineRange: TimeRange,
        speed: RationalValue
    ) throws {
        let expectedTimelineDuration = try speedTimelineDuration(
            clipID: clipID,
            sourceDuration: sourceRange.duration,
            speed: speed
        )
        guard expectedTimelineDuration == timelineRange.duration else {
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
            let sourceRange = try trimmedSourceRangeForEnd(clip, duration: duration)
            let timelineRange = try makeRange(
                start: clip.timelineRange.start,
                duration: duration
            )
            return .clip(copying(clip, sourceRange: sourceRange, timelineRange: timelineRange))
        case .gap:
            return .gap(try makeRange(start: item.timelineRange.start, duration: duration))
        case .transition(let transition):
            return .transition(
                Transition(
                    id: transition.id,
                    timelineRange: try makeRange(
                        start: item.timelineRange.start,
                        duration: duration
                    ),
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
            return .clip(
                copying(
                    clip,
                    sourceRange: try trimmedSourceRangeForStart(
                        clip,
                        start: start,
                        duration: duration
                    ),
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

    static func trimmedSourceRangeForEnd(
        _ clip: Clip,
        duration: RationalTime
    ) throws -> TimeRange {
        let sourceDuration = try speedSourceDuration(
            clipID: clip.id,
            timelineDuration: duration,
            speed: clip.speed
        )
        return try makeRange(start: clip.sourceRange.start, duration: sourceDuration)
    }

    static func trimmedSourceRangeForStart(
        _ clip: Clip,
        start: RationalTime,
        duration: RationalTime
    ) throws -> TimeRange {
        let timelineDelta = try subtractTimes(start, clip.timelineRange.start)
        let sourceDelta = try speedSourceDuration(
            clipID: clip.id,
            timelineDuration: timelineDelta,
            speed: clip.speed
        )
        let sourceStart = try addTimes(clip.sourceRange.start, sourceDelta)
        let sourceDuration = try speedSourceDuration(
            clipID: clip.id,
            timelineDuration: duration,
            speed: clip.speed
        )
        return try makeRange(start: sourceStart, duration: sourceDuration)
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
