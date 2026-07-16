// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    private struct MidInsertSplitContext {
        let insertedClipID: UUID
        let cut: RationalTime
        let insertDuration: RationalTime
        let location: (sequenceID: UUID, trackID: UUID)
        let reservedClipIDs: Set<UUID>
    }

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
        let reservedClipIDs = Set(
            project.sequences.flatMap { sequence in
                (sequence.videoTracks + sequence.audioTracks).flatMap { track in
                    track.items.compactMap { item -> UUID? in
                        guard case .clip(let existing) = item else {
                            return nil
                        }
                        return existing.id
                    }
                }
            } + [clip.id]
        )
        return try replacingTrack(trackID, sequenceID: sequenceID, in: project) { track in
            let insertStart = clip.timelineRange.start
            let insertDuration = clip.timelineRange.duration
            let splitContext = MidInsertSplitContext(
                insertedClipID: clip.id,
                cut: insertStart,
                insertDuration: insertDuration,
                location: (sequenceID, trackID),
                reservedClipIDs: reservedClipIDs
            )
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
                        context: splitContext,
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
        context: MidInsertSplitContext,
        into items: inout [TimelineItem]
    ) throws {
        switch item {
        case .clip(let existing):
            try splitClipForInsert(
                existing,
                context: context,
                into: &items
            )
        case .gap(let range):
            try splitGapForInsert(
                range,
                cut: context.cut,
                ripple: context.insertDuration,
                into: &items
            )
        case .transition(let transition):
            // Standalone transition items that straddle the insert point are not split;
            // refuse rather than invent geometry (callers insert at a cut in normal use).
            throw EditReducerError.invalidEdit(
                .bladeTimeOutsideClip(clipID: transition.id, atTime: context.cut)
            )
        }
    }

    private static func splitClipForInsert(
        _ existing: Clip,
        context: MidInsertSplitContext,
        into items: inout [TimelineItem]
    ) throws {
        if let linkGroupID = existing.linkGroupID {
            // Splitting one track in isolation would leave the old linked partner spanning the
            // cut while this clip gains an unlinked right half. The app prepares linked inserts
            // as one explicit blade/relink/insert transaction; lower-level callers get a typed
            // refusal instead of silently corrupting A/V linkage.
            throw EditReducerError.invalidEdit(
                .insertWouldSplitLinkedClip(
                    clipID: existing.id,
                    linkGroupID: linkGroupID,
                    atTime: context.cut
                )
            )
        }
        try rejectBladeInsideCrossfadeRegion(clip: existing, atTime: context.cut)
        try rejectBladeInsideVideoTransitionRegion(clip: existing, atTime: context.cut)
        let rightClipID = derivedInsertSplitClipID(
            originalClipID: existing.id,
            insertedClipID: context.insertedClipID,
            reservedClipIDs: context.reservedClipIDs
        )
        let edit = BladeClipEdit(
            sequenceID: context.location.sequenceID,
            trackID: context.location.trackID,
            clipID: existing.id,
            atTime: context.cut,
            rightClipID: rightClipID
        )
        let clipEnd = try exactTime { try existing.timelineRange.end() }
        let halves = try bladeHalves(of: existing, edit: edit, clipEnd: clipEnd)
        items.append(.clip(halves.left))
        items.append(try offsetItem(.clip(halves.right), by: context.insertDuration))
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

    /// Derives the implicit right-half identity from IDs already recorded in `insertClip`.
    ///
    /// Mid-clip insert is replayed for redo and Save As history validation. Generating a fresh UUID
    /// here would make the same persisted command produce a different project on every replay.
    private static func derivedInsertSplitClipID(
        originalClipID: UUID,
        insertedClipID: UUID,
        reservedClipIDs: Set<UUID>
    ) -> UUID {
        let original = originalClipID.uuid
        let inserted = insertedClipID.uuid
        var attempt: UInt64 = 0
        while true {
            let mix = withUnsafeBytes(of: attempt.littleEndian) { Array($0) }
            let candidate = UUID(
                uuid: (
                    original.0 ^ inserted.0 ^ mix[0],
                    original.1 ^ inserted.1 ^ mix[1],
                    original.2 ^ inserted.2 ^ mix[2],
                    original.3 ^ inserted.3 ^ mix[3],
                    original.4 ^ inserted.4 ^ mix[4],
                    original.5 ^ inserted.5 ^ mix[5],
                    original.6 ^ inserted.6 ^ mix[6],
                    original.7 ^ inserted.7 ^ mix[7],
                    original.8 ^ inserted.8,
                    original.9 ^ inserted.9,
                    original.10 ^ inserted.10,
                    original.11 ^ inserted.11,
                    original.12 ^ inserted.12,
                    original.13 ^ inserted.13,
                    original.14 ^ inserted.14,
                    original.15 ^ inserted.15
                )
            )
            if !reservedClipIDs.contains(candidate) {
                return candidate
            }
            attempt &+= 1
        }
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
