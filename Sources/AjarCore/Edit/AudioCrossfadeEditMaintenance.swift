// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    /// ADR-0015 §8 crossfade metadata maintenance for the trim-family edit commands
    /// (FR-AUD-002).
    ///
    /// After a geometry edit, every surviving pair whose partners still abut is preserved
    /// with its duration clamped to the post-edit clip durations and the outgoing clip's
    /// remaining source handle (§3/§7); clamping to zero removes the pair, and any record
    /// whose partner no longer abuts its edge is removed together with its mirror. Video
    /// tracks are untouched — crossfade records are audio-track metadata.
    static func maintainingCrossfades(_ track: Track, in project: Project) throws -> Track {
        guard track.kind == .audio else {
            return track
        }
        var items = try droppingBrokenCrossfadeRecords(track.items)
        try clampCrossfadePairs(&items, mediaDurationsByID: mediaDurationsByID(in: project))
        return copying(track, items: items)
    }

    /// Runs `maintainingCrossfades` on the track at `location` in place, for commands
    /// (like move) that rewrite tracks through the sequence-level track arrays.
    static func applyCrossfadeMaintenance(
        at location: TrackLocation,
        videoTracks: inout [Track],
        audioTracks: inout [Track],
        in project: Project
    ) throws {
        let current = track(at: location, videoTracks: videoTracks, audioTracks: audioTracks)
        setTrack(
            try maintainingCrossfades(current, in: project),
            at: location,
            videoTracks: &videoTracks,
            audioTracks: &audioTracks
        )
    }

    /// Declared media durations keyed by media-pool ID, mirroring `ProjectValidator`.
    static func mediaDurationsByID(in project: Project) -> [UUID: RationalTime] {
        Dictionary(
            project.mediaPool.map { ($0.id, $0.metadata.duration) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Returns a copy of `mix` with the given fields replaced.
    static func copying(
        _ mix: ClipAudioMix,
        fadeIn: ClipAudioFade? = nil,
        fadeOut: ClipAudioFade? = nil,
        leadingCrossfade: ClipAudioCrossfade?? = nil,
        trailingCrossfade: ClipAudioCrossfade?? = nil
    ) -> ClipAudioMix {
        ClipAudioMix(
            gain: mix.gain,
            pan: mix.pan,
            fadeIn: fadeIn ?? mix.fadeIn,
            fadeOut: fadeOut ?? mix.fadeOut,
            leadingCrossfade: leadingCrossfade ?? mix.leadingCrossfade,
            trailingCrossfade: trailingCrossfade ?? mix.trailingCrossfade
        )
    }

    /// Timeline-domain cap a trailing crossfade must respect from the outgoing clip's
    /// remaining source handle (ADR-0015 §3), or `nil` when the tail is unbounded — freeze
    /// frames hold their frame, compound sources read the nested sequence past the window,
    /// and media without a declared duration is validated at render time instead.
    static func crossfadeTailHandleLimit(
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
            // The reversed tail keeps reading backward past `sourceRange.start`.
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
}

extension EditReducer {
    /// True when `outgoing` and `incoming` form an intact ADR-0015 §5 pair: abutting edges
    /// and mutually-naming records that agree on duration and curve.
    static func crossfadePairIsIntact(outgoing: Clip, incoming: Clip) throws -> Bool {
        guard
            let trailing = outgoing.audioMix.trailingCrossfade,
            let leading = incoming.audioMix.leadingCrossfade,
            trailing.partnerClipID == incoming.id,
            leading.partnerClipID == outgoing.id,
            trailing.duration == leading.duration,
            trailing.curve == leading.curve
        else {
            return false
        }
        return try exactTime { try outgoing.timelineRange.end() } == incoming.timelineRange.start
    }

    static func droppingBrokenCrossfadeRecords(
        _ items: [TimelineItem]
    ) throws -> [TimelineItem] {
        var repaired = items
        for index in items.indices {
            guard case .clip(let clip) = items[index] else {
                continue
            }
            var mix = clip.audioMix
            if mix.leadingCrossfade != nil, try !hasIntactLeadingPair(at: index, in: items) {
                mix = copying(mix, leadingCrossfade: .some(nil))
            }
            if mix.trailingCrossfade != nil, try !hasIntactTrailingPair(at: index, in: items) {
                mix = copying(mix, trailingCrossfade: .some(nil))
            }
            if mix != clip.audioMix {
                repaired[index] = .clip(copying(clip, audioMix: mix))
            }
        }
        return repaired
    }

    static func hasIntactLeadingPair(at index: Int, in items: [TimelineItem]) throws -> Bool {
        guard
            index > items.startIndex,
            case .clip(let clip) = items[index],
            case .clip(let previous) = items[index - 1]
        else {
            return false
        }
        return try crossfadePairIsIntact(outgoing: previous, incoming: clip)
    }

    static func hasIntactTrailingPair(at index: Int, in items: [TimelineItem]) throws -> Bool {
        guard
            case .clip(let clip) = items[index],
            items.index(after: index) < items.endIndex,
            case .clip(let next) = items[items.index(after: index)]
        else {
            return false
        }
        return try crossfadePairIsIntact(outgoing: clip, incoming: next)
    }

    /// ADR-0015 §7/§8 duration cap for a pair: the two clip durations and the outgoing
    /// clip's remaining source handle.
    static func crossfadeDurationLimit(
        outgoing: Clip,
        incoming: Clip,
        mediaDurationsByID: [UUID: RationalTime]
    ) throws -> RationalTime {
        var limit = min(outgoing.timelineRange.duration, incoming.timelineRange.duration)
        if let handle = try crossfadeTailHandleLimit(
            for: outgoing,
            mediaDurationsByID: mediaDurationsByID
        ), handle < limit {
            limit = handle
        }
        return limit
    }

    static func clampCrossfadePairs(
        _ items: inout [TimelineItem],
        mediaDurationsByID: [UUID: RationalTime]
    ) throws {
        for index in items.indices {
            guard
                case .clip(let outgoing) = items[index],
                let record = outgoing.audioMix.trailingCrossfade,
                items.index(after: index) < items.endIndex,
                case .clip(let incoming) = items[items.index(after: index)]
            else {
                continue
            }
            let limit = try crossfadeDurationLimit(
                outgoing: outgoing,
                incoming: incoming,
                mediaDurationsByID: mediaDurationsByID
            )
            guard record.duration > limit else {
                continue
            }
            if limit > .zero {
                setCrossfadePairDuration(limit, outgoingIndex: index, in: &items)
            } else {
                removeCrossfadePair(outgoingIndex: index, in: &items)
            }
        }
    }

    static func setCrossfadePairDuration(
        _ duration: RationalTime,
        outgoingIndex: Int,
        in items: inout [TimelineItem]
    ) {
        updateCrossfadePair(outgoingIndex: outgoingIndex, in: &items) { record in
            ClipAudioCrossfade(
                partnerClipID: record.partnerClipID,
                duration: duration,
                curve: record.curve
            )
        }
    }

    static func removeCrossfadePair(outgoingIndex: Int, in items: inout [TimelineItem]) {
        updateCrossfadePair(outgoingIndex: outgoingIndex, in: &items) { _ in nil }
    }

    /// Rewrites both records of the intact pair owned at `outgoingIndex` atomically.
    static func updateCrossfadePair(
        outgoingIndex: Int,
        in items: inout [TimelineItem],
        transform: (ClipAudioCrossfade) -> ClipAudioCrossfade?
    ) {
        let incomingIndex = items.index(after: outgoingIndex)
        guard
            case .clip(let outgoing) = items[outgoingIndex],
            case .clip(let incoming) = items[incomingIndex],
            let trailing = outgoing.audioMix.trailingCrossfade,
            let leading = incoming.audioMix.leadingCrossfade
        else {
            return
        }
        items[outgoingIndex] = .clip(
            copying(
                outgoing,
                audioMix: copying(outgoing.audioMix, trailingCrossfade: .some(transform(trailing)))
            )
        )
        items[incomingIndex] = .clip(
            copying(
                incoming,
                audioMix: copying(incoming.audioMix, leadingCrossfade: .some(transform(leading)))
            )
        )
    }
}

extension EditReducer {
    /// ADR-0015 §8 blade row, region guard: the ADR does not define blading *inside* an
    /// active transition region `[T, T + D)` (the incoming clip's leading span), so it is
    /// rejected with a typed error rather than guessed at (NFR-STAB-003).
    static func rejectBladeInsideCrossfadeRegion(clip: Clip, atTime: RationalTime) throws {
        guard let leading = clip.audioMix.leadingCrossfade, leading.duration > .zero else {
            return
        }
        let regionEnd = try addTimes(clip.timelineRange.start, leading.duration)
        if atTime < regionEnd {
            throw EditReducerError.invalidEdit(
                .bladeInsideCrossfadeRegion(clipID: clip.id, atTime: atTime)
            )
        }
    }

    /// ADR-0015 §8 blade row: the trailing record moves to the right half, so the next
    /// partner's leading mirror must re-point at the right half's ID.
    static func repointBladeMirror(
        _ items: inout [TimelineItem],
        record: ClipAudioCrossfade?,
        from originalClipID: UUID,
        to rightClipID: UUID
    ) {
        guard
            let record,
            let partnerIndex = clipIndex(record.partnerClipID, in: items),
            case .clip(let partner) = items[partnerIndex],
            let mirror = partner.audioMix.leadingCrossfade,
            mirror.partnerClipID == originalClipID
        else {
            return
        }
        items[partnerIndex] = .clip(
            copying(
                partner,
                audioMix: copying(
                    partner.audioMix,
                    leadingCrossfade: .some(
                        ClipAudioCrossfade(
                            partnerClipID: rightClipID,
                            duration: mirror.duration,
                            curve: mirror.curve
                        )
                    )
                )
            )
        )
    }
}
