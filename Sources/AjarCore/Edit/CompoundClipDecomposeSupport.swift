// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    /// Rejects decompose when the compound clip carries attributes that cannot be composed
    /// exactly onto the expanded clips (FR-CMP-004).
    ///
    /// Speed is folded into every expanded clip and is therefore always allowed. The compound
    /// clip's name is intentionally not preserved: expanded clips keep their own names, matching
    /// the exact inverse of make-compound.
    static func validateDecomposableCompoundAttributes(_ compoundClip: Clip) throws {
        if compoundClip.transform != .identity || compoundClip.transformAnimation != .identity {
            throw unsupportedDecomposeAttribute(compoundClip, .transform)
        }
        if compoundClip.effects != .none || compoundClip.effectsAnimation != .none {
            throw unsupportedDecomposeAttribute(compoundClip, .effects)
        }
        if compoundClip.audioMix != .identity {
            throw unsupportedDecomposeAttribute(compoundClip, .audioMix)
        }
        if compoundClip.reverse {
            throw unsupportedDecomposeAttribute(compoundClip, .reverse)
        }
        if compoundClip.freezeFrame {
            throw unsupportedDecomposeAttribute(compoundClip, .freezeFrame)
        }
    }

    private static func unsupportedDecomposeAttribute(
        _ compoundClip: Clip,
        _ attribute: CompoundClipDecomposeAttribute
    ) -> EditReducerError {
        .invalidEdit(
            .compoundDecomposeUnsupportedAttribute(
                clipID: compoundClip.id,
                attribute: attribute
            )
        )
    }

    /// Expands the clips of one nested track, windowed to the compound clip's `sourceRange`.
    static func decomposedClips(
        from nestedTrack: Track,
        compoundClip: Clip
    ) throws -> [Clip] {
        var clips: [Clip] = []
        for item in nestedTrack.items {
            guard case .clip(let clip) = item else {
                continue
            }
            if let windowed = try decomposedWindowedClip(clip, compoundClip: compoundClip) {
                clips.append(windowed)
            }
        }
        return clips
    }

    /// Maps one nested clip into the parent timeline, clipped to the compound clip's
    /// `sourceRange` window. Returns `nil` for clips entirely outside the window.
    private static func decomposedWindowedClip(
        _ clip: Clip,
        compoundClip: Clip
    ) throws -> Clip? {
        let window = compoundClip.sourceRange
        guard try rangesIntersect(clip.timelineRange, window) else {
            return nil
        }

        let clipEnd = try exactTime { try clip.timelineRange.end() }
        let windowEnd = try exactTime { try window.end() }
        let clippedStart = max(clip.timelineRange.start, window.start)
        let clippedEnd = min(clipEnd, windowEnd)
        let clippedDuration = try subtractTimes(clippedEnd, clippedStart)
        let headDelta = try subtractTimes(clippedStart, clip.timelineRange.start)
        let tailDelta = try subtractTimes(clipEnd, clippedEnd)

        return copying(
            clip,
            sourceRange: try windowedSourceRange(
                for: clip,
                clippedDuration: clippedDuration,
                headDelta: headDelta,
                tailDelta: tailDelta
            ),
            timelineRange: try decomposedTimelineRange(
                nestedStart: clippedStart,
                nestedDuration: clippedDuration,
                compoundClip: compoundClip
            ),
            speed: try combinedSpeed(clip.speed, compoundClip.speed)
        )
    }

    /// Trims a nested clip's source range to match its window-clipped timeline range.
    ///
    /// Forward clips consume source from the head, reverse clips consume source from the tail,
    /// and freeze-frame clips keep `sourceRange.start` so the held frame never changes.
    private static func windowedSourceRange(
        for clip: Clip,
        clippedDuration: RationalTime,
        headDelta: RationalTime,
        tailDelta: RationalTime
    ) throws -> TimeRange {
        guard headDelta > .zero || tailDelta > .zero else {
            return clip.sourceRange
        }

        let sourceDuration = try speedSourceDuration(
            clipID: clip.id,
            timelineDuration: clippedDuration,
            speed: clip.speed
        )
        if clip.freezeFrame {
            return try makeRange(start: clip.sourceRange.start, duration: sourceDuration)
        }
        let startDelta = try speedSourceDuration(
            clipID: clip.id,
            timelineDuration: clip.reverse ? tailDelta : headDelta,
            speed: clip.speed
        )
        return try makeRange(
            start: try addTimes(clip.sourceRange.start, startDelta),
            duration: sourceDuration
        )
    }

    /// Maps a window-clipped nested range onto the parent timeline through the compound's
    /// placement and speed.
    private static func decomposedTimelineRange(
        nestedStart: RationalTime,
        nestedDuration: RationalTime,
        compoundClip: Clip
    ) throws -> TimeRange {
        let nestedStartOffset = try subtractTimes(nestedStart, compoundClip.sourceRange.start)
        let parentStartOffset = try speedTimelineDuration(
            clipID: compoundClip.id,
            sourceDuration: nestedStartOffset,
            speed: compoundClip.speed
        )
        let parentDuration = try speedTimelineDuration(
            clipID: compoundClip.id,
            sourceDuration: nestedDuration,
            speed: compoundClip.speed
        )
        return try makeRange(
            start: try addTimes(compoundClip.timelineRange.start, parentStartOffset),
            duration: parentDuration
        )
    }

    static func combinedSpeed(
        _ clipSpeed: RationalValue,
        _ compoundSpeed: RationalValue
    ) throws -> RationalValue {
        do {
            let numerator = try RationalTime.multiplied(
                clipSpeed.numerator,
                by: compoundSpeed.numerator
            )
            let denominator = try RationalTime.multiplied(
                clipSpeed.denominator,
                by: compoundSpeed.denominator
            )
            return try RationalValue(numerator: numerator, denominator: denominator)
        } catch let error as RationalTimeError {
            throw EditReducerError.timeArithmeticFailed(error)
        }
    }

    /// Restores clip-anchored markers from the nested sequence onto the parent timeline,
    /// inverting make-compound's marker relocation (FR-CMP-004).
    ///
    /// Only markers anchored to an expanded clip and timed inside the compound's `sourceRange`
    /// window are restored; markers pointing at trimmed-away content stay in the nested
    /// sequence, which decompose leaves in place. Restored markers keep their original ID for
    /// an exact make-compound inverse; when that ID already exists on the parent (for example
    /// two compound clips referencing the same nested sequence), a deterministic replacement
    /// ID is derived so the marker is never dropped and redo replays byte-identically.
    static func decomposedMarkers(
        from targetSequence: Sequence,
        compoundClip: Clip,
        expandedReferences: Set<ClipReference>,
        parentMarkerIDs: Set<UUID>
    ) throws -> [Marker] {
        var reservedIDs = parentMarkerIDs
        var markers: [Marker] = []
        for marker in targetSequence.markers {
            guard case .clip(let trackID, let clipID) = marker.anchor else {
                continue
            }
            guard expandedReferences.contains(ClipReference(trackID: trackID, clipID: clipID))
            else {
                continue
            }
            guard try exactTime({ try compoundClip.sourceRange.contains(marker.time) }) else {
                continue
            }

            let restored = try restoredMarker(
                marker,
                compoundClip: compoundClip,
                reservedIDs: reservedIDs
            )
            reservedIDs.insert(restored.id)
            markers.append(restored)
        }
        return markers
    }

    private static func restoredMarker(
        _ marker: Marker,
        compoundClip: Clip,
        reservedIDs: Set<UUID>
    ) throws -> Marker {
        let nestedOffset = try subtractTimes(marker.time, compoundClip.sourceRange.start)
        let parentOffset = try speedTimelineDuration(
            clipID: compoundClip.id,
            sourceDuration: nestedOffset,
            speed: compoundClip.speed
        )
        return Marker(
            id: restoredMarkerID(
                original: marker.id,
                compoundClipID: compoundClip.id,
                reservedIDs: reservedIDs
            ),
            time: try addTimes(compoundClip.timelineRange.start, parentOffset),
            name: marker.name,
            color: marker.color,
            note: marker.note,
            anchor: marker.anchor
        )
    }

    private static func restoredMarkerID(
        original: UUID,
        compoundClipID: UUID,
        reservedIDs: Set<UUID>
    ) -> UUID {
        guard reservedIDs.contains(original) else {
            return original
        }

        var attempt: UInt64 = 0
        while true {
            let candidate = derivedMarkerID(
                original: original,
                compoundClipID: compoundClipID,
                attempt: attempt
            )
            if !reservedIDs.contains(candidate) {
                return candidate
            }
            attempt &+= 1
        }
    }

    /// Deterministically mixes the compound clip ID and an attempt counter into the original
    /// marker ID. Candidates are distinct for every attempt, so the collision-escape loop in
    /// `restoredMarkerID` terminates against any finite reserved-ID set.
    private static func derivedMarkerID(
        original: UUID,
        compoundClipID: UUID,
        attempt: UInt64
    ) -> UUID {
        let left = original.uuid
        let right = compoundClipID.uuid
        let mix = withUnsafeBytes(of: attempt.littleEndian) { Array($0) }
        return UUID(
            uuid: (
                left.0 ^ right.0 ^ mix[0],
                left.1 ^ right.1 ^ mix[1],
                left.2 ^ right.2 ^ mix[2],
                left.3 ^ right.3 ^ mix[3],
                left.4 ^ right.4 ^ mix[4],
                left.5 ^ right.5 ^ mix[5],
                left.6 ^ right.6 ^ mix[6],
                left.7 ^ right.7 ^ mix[7],
                left.8 ^ right.8,
                left.9 ^ right.9,
                left.10 ^ right.10,
                left.11 ^ right.11,
                left.12 ^ right.12,
                left.13 ^ right.13,
                left.14 ^ right.14,
                left.15 ^ right.15
            )
        )
    }
}
