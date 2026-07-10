// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    /// Body-moves `clip` onto `timelineRange`, shifting every absolute keyframe time by the
    /// start delta so the clip-relative animation shape is preserved (issue #198).
    ///
    /// This is the **single** translation rebase rule for move / ripple offset / append /
    /// make-compound collapse / slide. Edge trims deliberately keep using plain `copying`
    /// so absolute keyframe times stay put when only the range ends change. Blade is already
    /// correct via `bladed(at:)` and must not go through this path for the right half
    /// (constructed directly) — the left half keeps the same start, so a relocating call
    /// would be a no-op if ever used.
    ///
    /// Families rebased together: transform, legacy effects, effect stack, audioMix gain/pan,
    /// title `revealFraction`. Call once per placement change — never stack with a second
    /// manual keyframe shift (double-rebase).
    static func relocating(
        _ clip: Clip,
        timelineRange newRange: TimeRange
    ) throws -> Clip {
        let delta = try subtractTimes(newRange.start, clip.timelineRange.start)
        guard delta != .zero else {
            // Duration-only or identical placement: keyframes already match the timebase.
            return copying(clip, timelineRange: newRange)
        }
        return try remappingAnimationTimes(
            clip,
            timelineRange: newRange,
            mapTime: { time in
                try addTimes(time, delta)
            }
        )
    }

    /// Rebuilds a clip with a new placement and maps every absolute keyframe time through
    /// `mapTime`. Used by decompose when the compound carries non-unit speed or a non-zero
    /// `sourceRange` origin (affine map, not a pure start-delta).
    static func remappingAnimationTimes(
        _ clip: Clip,
        source: ClipSource? = nil,
        sourceRange: TimeRange? = nil,
        timelineRange: TimeRange,
        speed: RationalValue? = nil,
        mapTime: (RationalTime) throws -> RationalTime
    ) throws -> Clip {
        let mappedSource: ClipSource
        if let source {
            mappedSource = source
        } else {
            mappedSource = try rebasedClipSource(clip.source, mapTime: mapTime)
        }
        return copying(
            clip,
            source: mappedSource,
            sourceRange: sourceRange,
            timelineRange: timelineRange,
            transformAnimation: try clip.transformAnimation.mappingKeyframeTimes(mapTime),
            effectsAnimation: try clip.effectsAnimation.mappingKeyframeTimes(mapTime),
            effectStackAnimation: try clip.effectStackAnimation.mappingKeyframeTimes(mapTime),
            audioMix: try clip.audioMix.mappingKeyframeTimes(mapTime),
            speed: speed
        )
    }

    /// Maps a nested-sequence absolute time onto the parent timeline through a compound
    /// clip's placement and speed — the inverse of make-compound's subtract-selectionStart
    /// collapse (and matching marker restoration in `decomposedMarkers`).
    static func parentTimelineTime(
        forNestedTime nestedTime: RationalTime,
        compoundClip: Clip
    ) throws -> RationalTime {
        let nestedOffset = try subtractTimes(nestedTime, compoundClip.sourceRange.start)
        let parentOffset = try speedTimelineDuration(
            clipID: compoundClip.id,
            sourceDuration: nestedOffset,
            speed: compoundClip.speed
        )
        return try addTimes(compoundClip.timelineRange.start, parentOffset)
    }

    /// Rebuilds a track whose absolute track-automation keyframe times are mapped through
    /// `mapTime` (opacity / audioGain / audioPan). Items, blend mode, and mute/solo flags are
    /// passed through unchanged. Used by make-compound collapse so nested-track curves stay
    /// aligned with the inner timebase after clips shift by `-selectionStart`.
    static func remappingTrackAutomationTimes(
        _ track: Track,
        items: [TimelineItem]? = nil,
        mapTime: (RationalTime) throws -> RationalTime
    ) throws -> Track {
        Track(
            id: track.id,
            kind: track.kind,
            items: items ?? track.items,
            enabled: track.enabled,
            locked: track.locked,
            muted: track.muted,
            solo: track.solo,
            hidden: track.hidden,
            opacity: try track.opacity.mappingKeyframeTimes(mapTime),
            blendMode: track.blendMode,
            audioGain: try track.audioGain.mappingKeyframeTimes(mapTime),
            audioPan: try track.audioPan.mappingKeyframeTimes(mapTime)
        )
    }

    private static func rebasedClipSource(
        _ source: ClipSource,
        mapTime: (RationalTime) throws -> RationalTime
    ) throws -> ClipSource {
        switch source {
        case .title(let title):
            return .title(try title.mappingKeyframeTimes(mapTime))
        case .media, .sequence:
            return source
        }
    }
}
