// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Typed validation failures for semantic edit operations.
public enum EditCommandValidationError: Equatable, Sendable {
    /// Blade time must be strictly inside the clip range.
    case bladeTimeOutsideClip(clipID: UUID, atTime: RationalTime)

    /// A trim-style command must keep source and timeline durations equal.
    case durationMismatch(
        clipID: UUID,
        sourceDuration: RationalTime,
        timelineDuration: RationalTime
    )

    /// The requested edit would make a zero-or-negative clip/item duration.
    case nonPositiveDuration(clipID: UUID)

    /// Making a compound requires at least one selected clip.
    case compoundSelectionEmpty(sequenceID: UUID)

    /// The same selected clip reference was supplied more than once.
    case duplicateCompoundSelectionReference(trackID: UUID, clipID: UUID)

    /// A compound replacement clip currently needs at least one selected video clip.
    case compoundSelectionRequiresVideo(sequenceID: UUID)

    /// No selected video track can host the replacement compound without overlapping leftovers.
    case compoundSelectionNeedsDestinationTrack(sequenceID: UUID)

    /// Roll requires two clips that share one edit point.
    case clipsNotAdjacent(leftClipID: UUID, rightClipID: UUID)

    /// Slide needs both a previous and next item to adjust.
    case slideRequiresNeighbors(clipID: UUID)

    /// Linking requires at least two distinct clips.
    case linkRequiresAtLeastTwoClips(linkGroupID: UUID)

    /// A link group must include at least one video clip and one audio clip.
    case linkRequiresVideoAndAudio(linkGroupID: UUID)

    /// The same clip was included more than once in a link command.
    case duplicateClipLinkReference(trackID: UUID, clipID: UUID)

    /// A clip is already assigned to a different link group.
    case clipAlreadyLinked(clipID: UUID, linkGroupID: UUID)

    /// A clip transform failed semantic validation.
    case invalidClipTransform(clipID: UUID, error: ClipTransformValidationError)

    /// A transform keyframe value did not match the requested parameter.
    case transformKeyframeValueMismatch(
        clipID: UUID,
        parameter: ClipTransformParameter,
        value: ClipTransformKeyframeValue
    )

    /// A transform keyframe time falls outside its clip's timeline range.
    case transformKeyframeTimeOutsideClip(
        clipID: UUID,
        parameter: ClipTransformParameter,
        time: RationalTime,
        clipRange: TimeRange
    )

    /// A transform keyframe duplicates an existing keyframe time.
    case duplicateTransformKeyframeTime(
        clipID: UUID,
        parameter: ClipTransformParameter,
        time: RationalTime
    )

    /// A transform keyframe was not found.
    case transformKeyframeNotFound(
        clipID: UUID,
        parameter: ClipTransformParameter,
        time: RationalTime
    )

    /// A transform keyframe value failed semantic transform validation.
    case invalidClipTransformKeyframe(
        clipID: UUID,
        parameter: ClipTransformParameter,
        time: RationalTime,
        error: ClipTransformValidationError
    )

    /// A clip effect failed semantic validation.
    case invalidClipEffects(clipID: UUID, error: ClipEffectsValidationError)

    /// A clip audio mix failed semantic validation.
    case invalidClipAudioMix(clipID: UUID, error: AudioMixValidationError)

    /// A clip speed failed semantic validation.
    case invalidClipSpeed(clipID: UUID, error: ClipSpeedValidationError)

    /// A track audio mix failed semantic validation.
    case invalidTrackAudioMix(trackID: UUID, error: AudioMixValidationError)

    /// A sequence ducking rule failed semantic validation.
    case invalidAudioDucking(
        sequenceID: UUID,
        ruleIndex: Int,
        error: AudioDuckingValidationError
    )

    /// Detaching audio requires the clip to be part of a linked A/V group.
    case detachAudioRequiresLinkedAudio(clipID: UUID)

    /// Replacing clip audio requires an audio clip target.
    case replaceAudioRequiresAudioClip(clipID: UUID, kind: TrackKind)

    /// The replacement audio source was not found in the media pool.
    case replacementAudioSourceNotFound(mediaID: UUID)

    /// The replacement media has no audio channels.
    case replacementAudioSourceHasNoAudio(mediaID: UUID)

    /// A clip mask edit referenced a missing mask.
    case clipMaskNotFound(clipID: UUID, maskID: UUID)

    /// A clip mask reorder target was outside the mask list.
    case clipMaskDestinationIndexOutOfRange(clipID: UUID, index: Int, count: Int)
}
