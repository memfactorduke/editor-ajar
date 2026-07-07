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
    /// sequence, which decompose leaves in place.
    static func decomposedMarkers(
        from targetSequence: Sequence,
        compoundClip: Clip,
        expandedReferences: Set<ClipReference>
    ) throws -> [Marker] {
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

            let nestedOffset = try subtractTimes(marker.time, compoundClip.sourceRange.start)
            let parentOffset = try speedTimelineDuration(
                clipID: compoundClip.id,
                sourceDuration: nestedOffset,
                speed: compoundClip.speed
            )
            markers.append(
                Marker(
                    id: marker.id,
                    time: try addTimes(compoundClip.timelineRange.start, parentOffset),
                    name: marker.name,
                    color: marker.color,
                    note: marker.note,
                    anchor: marker.anchor
                )
            )
        }
        return markers
    }
}
