// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    /// Source ranges for the two halves of a blade split.
    struct BladeSourceRanges {
        let left: TimeRange
        let right: TimeRange
    }

    /// Keyframed animation halves for a blade split (FR-XFORM-008).
    struct BladeAnimationHalves {
        let leftTransform: AnimatableClipTransform
        let rightTransform: AnimatableClipTransform
        let leftEffects: AnimatableClipEffects
        let rightEffects: AnimatableClipEffects
    }

    /// Direction-aware source split for a blade (FR-SPD-003, FR-TL-004).
    ///
    /// Forward playback consumes source from the head, so the left half keeps the head of
    /// the source range. Reverse playback consumes source backward, so the left half
    /// receives the TAIL: blading at timeline offset `L` of a clip with source `[s, e)`
    /// gives left `[e − L·speed, e)` and right `[s, e − L·speed)`. A freeze frame holds
    /// `sourceRange.start` for every rendered time, so both halves keep the same start. A
    /// time-remap curve is bounded by the clip's source range and each half keeps the full
    /// range, so the split curves stay in bounds (FR-SPD-002).
    static func bladeSourceRanges(
        of clip: Clip,
        leftDuration: RationalTime,
        rightDuration: RationalTime
    ) throws -> BladeSourceRanges {
        guard clip.timeRemap == nil else {
            return BladeSourceRanges(left: clip.sourceRange, right: clip.sourceRange)
        }
        let leftSourceDuration = try speedSourceDuration(
            clipID: clip.id,
            timelineDuration: leftDuration,
            speed: clip.speed
        )
        let rightSourceDuration = try speedSourceDuration(
            clipID: clip.id,
            timelineDuration: rightDuration,
            speed: clip.speed
        )
        let leftStart: RationalTime
        let rightStart: RationalTime
        if clip.freezeFrame {
            leftStart = clip.sourceRange.start
            rightStart = clip.sourceRange.start
        } else if clip.reverse {
            let sourceEnd = try exactTime { try clip.sourceRange.end() }
            leftStart = try subtractTimes(sourceEnd, leftSourceDuration)
            rightStart = clip.sourceRange.start
        } else {
            leftStart = clip.sourceRange.start
            rightStart = try addTimes(clip.sourceRange.start, leftSourceDuration)
        }
        return BladeSourceRanges(
            left: try makeRange(start: leftStart, duration: leftSourceDuration),
            right: try makeRange(start: rightStart, duration: rightSourceDuration)
        )
    }

    /// Splits an FR-SPD-002 time-remap curve at the blade offset, or returns `nil` for
    /// constant-rate clips. The clip's curve is validated first so evaluation at the split
    /// point is trustworthy; failures surface as typed errors (NFR-STAB-003).
    static func bladeTimeRemapHalves(
        of clip: Clip,
        leftDuration: RationalTime
    ) throws -> (left: ClipTimeRemap, right: ClipTimeRemap)? {
        guard let timeRemap = clip.timeRemap else {
            return nil
        }
        if let error = clip.validateTimeRemap() {
            throw EditReducerError.invalidEdit(
                .invalidClipTimeRemap(clipID: clip.id, error: error)
            )
        }
        do {
            return try timeRemap.bladed(atOffset: leftDuration)
        } catch let error as ClipTimeRemapValidationError {
            throw EditReducerError.invalidEdit(
                .invalidClipTimeRemap(clipID: clip.id, error: error)
            )
        } catch let error as RationalTimeError {
            throw EditReducerError.timeArithmeticFailed(error)
        }
    }

    /// Splits the clip's keyframed transform and effects animations at the cut so the
    /// rendered animation is unchanged by the blade (FR-XFORM-008).
    static func bladeAnimationHalves(
        of clip: Clip,
        at cut: RationalTime
    ) throws -> BladeAnimationHalves {
        let transform = try exactTime { try clip.transformAnimation.bladed(at: cut) }
        let effects = try exactTime { try clip.effectsAnimation.bladed(at: cut) }
        return BladeAnimationHalves(
            leftTransform: transform.left,
            rightTransform: transform.right,
            leftEffects: effects.left,
            rightEffects: effects.right
        )
    }
}
