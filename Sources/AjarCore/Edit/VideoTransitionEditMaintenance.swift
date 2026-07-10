// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    /// Runs audio crossfade and video transition cut-edge maintenance (independent records).
    static func maintainingCutEdgeMetadata(_ track: Track, in project: Project) throws -> Track {
        let withCrossfades = try maintainingCrossfades(track, in: project)
        return try maintainingVideoTransitions(withCrossfades, in: project)
    }

    /// Sequence-level cut-edge maintenance at one track location (move edits).
    static func applyCutEdgeMaintenance(
        at location: TrackLocation,
        videoTracks: inout [Track],
        audioTracks: inout [Track],
        in project: Project
    ) throws {
        try applyCrossfadeMaintenance(
            at: location,
            videoTracks: &videoTracks,
            audioTracks: &audioTracks,
            in: project
        )
        try applyVideoTransitionMaintenance(
            at: location,
            videoTracks: &videoTracks,
            audioTracks: &audioTracks,
            in: project
        )
    }

    /// ADR-0016 §5 / ADR-0015 §8 video transition metadata maintenance for the
    /// trim-family edit commands (FR-FX-001).
    ///
    /// After a geometry edit, every surviving pair whose partners still abut is preserved
    /// with its duration clamped to the post-edit clip durations and the outgoing clip's
    /// remaining source handle; clamping to zero removes the pair. Audio tracks are
    /// untouched — transition records are video-track metadata. Video transitions and
    /// audio crossfades on the same cut stay independent (ADR-0016 §6).
    static func maintainingVideoTransitions(_ track: Track, in project: Project) throws -> Track {
        guard track.kind == .video else {
            return track
        }
        var items = try droppingBrokenVideoTransitionRecords(track.items)
        try clampVideoTransitionPairs(
            &items,
            mediaDurationsByID: mediaDurationsByID(in: project)
        )
        return copying(track, items: items)
    }

    /// Runs `maintainingVideoTransitions` on the track at `location` in place.
    static func applyVideoTransitionMaintenance(
        at location: TrackLocation,
        videoTracks: inout [Track],
        audioTracks: inout [Track],
        in project: Project
    ) throws {
        let current = track(at: location, videoTracks: videoTracks, audioTracks: audioTracks)
        setTrack(
            try maintainingVideoTransitions(current, in: project),
            at: location,
            videoTracks: &videoTracks,
            audioTracks: &audioTracks
        )
    }

    /// True when `outgoing` and `incoming` form an intact ADR-0016 §5 pair.
    static func videoTransitionPairIsIntact(outgoing: Clip, incoming: Clip) throws -> Bool {
        guard
            let trailing = outgoing.trailingTransition,
            let leading = incoming.leadingTransition,
            trailing.partnerClipID == incoming.id,
            leading.partnerClipID == outgoing.id,
            trailing.agrees(with: leading)
        else {
            return false
        }
        return try exactTime { try outgoing.timelineRange.end() } == incoming.timelineRange.start
    }

    static func droppingBrokenVideoTransitionRecords(
        _ items: [TimelineItem]
    ) throws -> [TimelineItem] {
        var repaired = items
        for index in items.indices {
            guard case .clip(let clip) = items[index] else {
                continue
            }
            var leading = clip.leadingTransition
            var trailing = clip.trailingTransition
            if leading != nil, try !hasIntactLeadingVideoTransition(at: index, in: items) {
                leading = nil
            }
            if trailing != nil, try !hasIntactTrailingVideoTransition(at: index, in: items) {
                trailing = nil
            }
            if leading != clip.leadingTransition || trailing != clip.trailingTransition {
                repaired[index] = .clip(
                    copying(
                        clip,
                        leadingTransition: .some(leading),
                        trailingTransition: .some(trailing)
                    )
                )
            }
        }
        return repaired
    }

    static func hasIntactLeadingVideoTransition(
        at index: Int,
        in items: [TimelineItem]
    ) throws -> Bool {
        guard
            index > items.startIndex,
            case .clip(let clip) = items[index],
            case .clip(let previous) = items[index - 1]
        else {
            return false
        }
        return try videoTransitionPairIsIntact(outgoing: previous, incoming: clip)
    }

    static func hasIntactTrailingVideoTransition(
        at index: Int,
        in items: [TimelineItem]
    ) throws -> Bool {
        guard
            case .clip(let clip) = items[index],
            items.index(after: index) < items.endIndex,
            case .clip(let next) = items[items.index(after: index)]
        else {
            return false
        }
        return try videoTransitionPairIsIntact(outgoing: clip, incoming: next)
    }

    static func videoTransitionDurationLimit(
        outgoing: Clip,
        incoming: Clip,
        mediaDurationsByID: [UUID: RationalTime]
    ) throws -> RationalTime {
        var limit = min(outgoing.timelineRange.duration, incoming.timelineRange.duration)
        if let handle = try videoTransitionTailHandleLimit(
            for: outgoing,
            mediaDurationsByID: mediaDurationsByID
        ), handle < limit {
            limit = handle
        }
        return limit
    }

    /// Timeline-domain cap from the outgoing clip's remaining source handle (fade-tail).
    static func videoTransitionTailHandleLimit(
        for clip: Clip,
        mediaDurationsByID: [UUID: RationalTime]
    ) throws -> RationalTime? {
        guard !clip.freezeFrame else {
            return nil
        }
        guard case .media(let mediaID) = clip.source else {
            return nil
        }
        guard let mediaDuration = mediaDurationsByID[mediaID] else {
            return nil
        }
        let sourceHandle: RationalTime
        if clip.reverse {
            sourceHandle = clip.sourceRange.start > .zero ? clip.sourceRange.start : .zero
        } else {
            let sourceEnd = try exactTime { try clip.sourceRange.end() }
            sourceHandle =
                sourceEnd < mediaDuration
                ? try subtractTimes(mediaDuration, sourceEnd)
                : .zero
        }
        return try speedTimelineDuration(
            clipID: clip.id,
            sourceDuration: sourceHandle,
            speed: clip.speed
        )
    }

    static func clampVideoTransitionPairs(
        _ items: inout [TimelineItem],
        mediaDurationsByID: [UUID: RationalTime]
    ) throws {
        for index in items.indices {
            guard
                case .clip(let outgoing) = items[index],
                let record = outgoing.trailingTransition,
                items.index(after: index) < items.endIndex,
                case .clip = items[items.index(after: index)]
            else {
                continue
            }
            let limit = try videoTransitionDurationLimit(
                outgoing: outgoing,
                incoming: {
                    if case .clip(let incoming) = items[items.index(after: index)] {
                        return incoming
                    }
                    return outgoing
                }(),
                mediaDurationsByID: mediaDurationsByID
            )
            guard record.duration > limit else {
                continue
            }
            if limit > .zero {
                setVideoTransitionPairDuration(limit, outgoingIndex: index, in: &items)
            } else {
                removeVideoTransitionPair(outgoingIndex: index, in: &items)
            }
        }
    }

    static func setVideoTransitionPairDuration(
        _ duration: RationalTime,
        outgoingIndex: Int,
        in items: inout [TimelineItem]
    ) {
        updateVideoTransitionPair(outgoingIndex: outgoingIndex, in: &items) { record in
            ClipVideoTransition(
                partnerClipID: record.partnerClipID,
                duration: duration,
                kind: record.kind,
                color: record.color,
                direction: record.direction
            )
        }
    }

    static func removeVideoTransitionPair(outgoingIndex: Int, in items: inout [TimelineItem]) {
        updateVideoTransitionPair(outgoingIndex: outgoingIndex, in: &items) { _ in nil }
    }

    static func updateVideoTransitionPair(
        outgoingIndex: Int,
        in items: inout [TimelineItem],
        transform: (ClipVideoTransition) -> ClipVideoTransition?
    ) {
        let incomingIndex = items.index(after: outgoingIndex)
        guard
            case .clip(let outgoing) = items[outgoingIndex],
            case .clip(let incoming) = items[incomingIndex],
            let trailing = outgoing.trailingTransition,
            let leading = incoming.leadingTransition
        else {
            return
        }
        items[outgoingIndex] = .clip(
            copying(outgoing, trailingTransition: .some(transform(trailing)))
        )
        items[incomingIndex] = .clip(
            copying(incoming, leadingTransition: .some(transform(leading)))
        )
    }

    /// Blade inside an active transition region `[T, T + D)` is rejected (ADR-0015 §8).
    static func rejectBladeInsideVideoTransitionRegion(
        clip: Clip,
        atTime: RationalTime
    ) throws {
        guard let leading = clip.leadingTransition, leading.duration > .zero else {
            return
        }
        let regionEnd = try addTimes(clip.timelineRange.start, leading.duration)
        if atTime < regionEnd {
            throw EditReducerError.invalidEdit(
                .bladeInsideVideoTransitionRegion(clipID: clip.id, atTime: atTime)
            )
        }
    }

    /// Blade row: trailing record moves to the right half; repoint the partner's mirror.
    static func repointBladeVideoTransitionMirror(
        _ items: inout [TimelineItem],
        record: ClipVideoTransition?,
        from originalClipID: UUID,
        to rightClipID: UUID
    ) {
        guard
            let record,
            let partnerIndex = clipIndex(record.partnerClipID, in: items),
            case .clip(let partner) = items[partnerIndex],
            let mirror = partner.leadingTransition,
            mirror.partnerClipID == originalClipID
        else {
            return
        }
        items[partnerIndex] = .clip(
            copying(
                partner,
                leadingTransition: .some(
                    ClipVideoTransition(
                        partnerClipID: rightClipID,
                        duration: mirror.duration,
                        kind: mirror.kind,
                        color: mirror.color,
                        direction: mirror.direction
                    )
                )
            )
        )
    }
}
