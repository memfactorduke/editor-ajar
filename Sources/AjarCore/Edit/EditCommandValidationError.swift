// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A compound-clip-level attribute that decompose cannot compose exactly onto expanded clips.
public enum CompoundClipDecomposeAttribute: String, Equatable, Sendable {
    /// A non-identity transform or transform animation on the compound clip.
    case transform

    /// Non-identity effects or an effects animation on the compound clip.
    case effects

    /// A non-empty video effects stack on the compound clip (FR-FX-003).
    case effectStack

    /// A non-identity audio mix on the compound clip.
    case audioMix

    /// A reverse time remap on the compound clip.
    case reverse

    /// A freeze-frame time remap on the compound clip.
    case freezeFrame

    /// An FR-SPD-002 keyframed time-remap curve on the compound clip or a nested clip.
    case timeRemap
}

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

    /// Collapsing would sever a sidechain ducking rule across the compound boundary, silently
    /// changing audible behavior. Remove or retarget the rule, or change the selection.
    case compoundSelectionSeversAudioDucking(sequenceID: UUID, ruleIndex: Int)

    /// Decomposing requires a sequence-backed compound clip.
    case decomposeRequiresCompoundClip(clipID: UUID)

    /// Decomposing cannot compose a compound-clip-level attribute exactly onto expanded clips.
    case compoundDecomposeUnsupportedAttribute(
        clipID: UUID,
        attribute: CompoundClipDecomposeAttribute
    )

    /// Decomposing would sever a nested sidechain ducking rule across the expansion boundary,
    /// silently changing audible behavior. Remove or retarget the nested rule first.
    case compoundDecomposeSeversAudioDucking(sequenceID: UUID, ruleIndex: Int)

    /// Decomposing would overlap an existing parent timeline item.
    case compoundDecomposeWouldOverlap(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        timelineRange: TimeRange
    )

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

    /// A clip effects stack failed FR-FX-003 semantic validation.
    case invalidClipEffectStack(clipID: UUID, error: ClipEffectStackValidationError)

    /// A clip audio mix failed semantic validation.
    case invalidClipAudioMix(clipID: UUID, error: AudioMixValidationError)

    /// A crossfade edit failed the ADR-0015 pair taxonomy, curve, retime, or
    /// source-handle rules (FR-AUD-002).
    case invalidClipAudioCrossfade(clipID: UUID, error: AudioCrossfadeValidationError)

    /// Creating a crossfade requires an abutting next clip on the same track (ADR-0015 §5).
    case crossfadeRequiresAdjacentClips(clipID: UUID)

    /// Crossfades are audio-track metadata; the addressed track is not an audio track.
    case crossfadeRequiresAudioTrack(clipID: UUID)

    /// Removing a crossfade requires an existing trailing record on the addressed clip.
    case crossfadeNotFound(clipID: UUID)

    /// The blade point falls inside an active ADR-0015 crossfade transition region, which
    /// the ADR does not define; the edit is rejected rather than guessed at.
    case bladeInsideCrossfadeRegion(clipID: UUID, atTime: RationalTime)

    /// A clip speed failed semantic validation.
    case invalidClipSpeed(clipID: UUID, error: ClipSpeedValidationError)

    /// A clip time-remap curve failed FR-SPD-002 semantic validation.
    case invalidClipTimeRemap(clipID: UUID, error: ClipTimeRemapValidationError)

    /// A clip audio retime mode failed the FR-SPD-001 composition policy.
    case invalidClipAudioRetime(clipID: UUID, error: ClipAudioRetimeValidationError)

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

    /// An effects-stack edit referenced a missing node (FR-FX-003).
    case clipEffectNodeNotFound(clipID: UUID, nodeID: UUID)

    /// An effects-stack reorder or insert index was out of range (FR-FX-003).
    case clipEffectNodeDestinationIndexOutOfRange(clipID: UUID, index: Int, count: Int)

    /// Adding an effects-stack node would duplicate a stable node ID (FR-FX-003).
    case duplicateClipEffectNodeID(clipID: UUID, nodeID: UUID)

    /// A title generator source failed FR-TXT-001 semantic validation.
    case invalidTitleSource(clipID: UUID, error: TitleSourceValidationError)

    /// Title edits require a title-generator clip source.
    case titleRequiresTitleClip(clipID: UUID)

    /// Title generators may only live on video tracks.
    case titleRequiresVideoTrack(clipID: UUID, trackKind: TrackKind)

    /// A title text box edit referenced a missing box ID.
    case titleTextBoxNotFound(clipID: UUID, boxID: UUID)
}
