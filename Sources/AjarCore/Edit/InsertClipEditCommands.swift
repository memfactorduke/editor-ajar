// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    /// Inserts `clip` at its timeline start, rippling later items (FR-TL-003).
    ///
    /// Items that *start* at/after the insert point ripple right by the new duration. An item
    /// that *contains* the insert point (common when the app playhead is clamped to the last
    /// displayable frame of a clip) is split first — otherwise the new clip would overlap and
    /// project validation would refuse the edit under ADR-0008 non-overlap.
    static func insertClip(
        _ clip: Clip,
        sequenceID: UUID,
        trackID: UUID,
        in project: Project
    ) throws -> Project {
        try replacingTrack(trackID, sequenceID: sequenceID, in: project) { track in
            let insertStart = clip.timelineRange.start
            let insertDuration = clip.timelineRange.duration
            var items: [TimelineItem] = []
            for item in track.items {
                let itemStart = item.timelineRange.start
                let itemEnd = try exactTime { try item.timelineRange.end() }
                if itemStart >= insertStart {
                    items.append(try offsetItem(item, by: insertDuration))
                } else if itemEnd <= insertStart {
                    items.append(item)
                } else {
                    try appendMidInsertSplit(
                        item,
                        cut: insertStart,
                        ripple: insertDuration,
                        location: (sequenceID, trackID),
                        into: &items
                    )
                }
            }
            items.append(.clip(clip))
            return try maintainingCutEdgeMetadata(
                copying(track, items: sortedItems(items)),
                in: project
            )
        }
    }

    /// Splits a track item that straddles `cut` and appends left + rippled-right halves.
    private static func appendMidInsertSplit(
        _ item: TimelineItem,
        cut: RationalTime,
        ripple insertDuration: RationalTime,
        location: (sequenceID: UUID, trackID: UUID),
        into items: inout [TimelineItem]
    ) throws {
        switch item {
        case .clip(let existing):
            try splitClipForInsert(
                existing,
                cut: cut,
                ripple: insertDuration,
                location: location,
                into: &items
            )
        case .gap(let range):
            try splitGapForInsert(
                range,
                cut: cut,
                ripple: insertDuration,
                into: &items
            )
        case .transition(let transition):
            // Standalone transition items that straddle the insert point are not split;
            // refuse rather than invent geometry (callers insert at a cut in normal use).
            throw EditReducerError.invalidEdit(
                .bladeTimeOutsideClip(clipID: transition.id, atTime: cut)
            )
        }
    }

    private static func splitClipForInsert(
        _ existing: Clip,
        cut: RationalTime,
        ripple insertDuration: RationalTime,
        location: (sequenceID: UUID, trackID: UUID),
        into items: inout [TimelineItem]
    ) throws {
        try rejectBladeInsideCrossfadeRegion(clip: existing, atTime: cut)
        try rejectBladeInsideVideoTransitionRegion(clip: existing, atTime: cut)
        let rightClipID = UUID()
        let edit = BladeClipEdit(
            sequenceID: location.sequenceID,
            trackID: location.trackID,
            clipID: existing.id,
            atTime: cut,
            rightClipID: rightClipID
        )
        let clipEnd = try exactTime { try existing.timelineRange.end() }
        let halves = try bladeHalves(of: existing, edit: edit, clipEnd: clipEnd)
        items.append(.clip(halves.left))
        items.append(try offsetItem(.clip(halves.right), by: insertDuration))
        repointBladeMirror(
            &items,
            record: existing.audioMix.trailingCrossfade,
            from: existing.id,
            to: rightClipID
        )
        repointBladeVideoTransitionMirror(
            &items,
            record: existing.trailingTransition,
            from: existing.id,
            to: rightClipID
        )
    }

    private static func splitGapForInsert(
        _ range: TimeRange,
        cut: RationalTime,
        ripple insertDuration: RationalTime,
        into items: inout [TimelineItem]
    ) throws {
        let leftDuration = try subtractTimes(cut, range.start)
        let rightDuration = try subtractTimes(
            try exactTime { try range.end() },
            cut
        )
        if leftDuration > .zero {
            items.append(.gap(try makeRange(start: range.start, duration: leftDuration)))
        }
        if rightDuration > .zero {
            let rightStart = try addTimes(cut, insertDuration)
            items.append(.gap(try makeRange(start: rightStart, duration: rightDuration)))
        }
    }
}
