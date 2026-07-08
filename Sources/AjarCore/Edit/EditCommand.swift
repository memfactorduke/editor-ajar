// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A deterministic edit operation applied to an immutable `Project`.
public enum EditCommand: Codable, Equatable, Sendable {
    /// Adds a clip to an existing track.
    case addClip(sequenceID: UUID, trackID: UUID, clip: Clip)

    /// Inserts a clip and pushes later items right by the clip duration.
    case insertClip(sequenceID: UUID, trackID: UUID, clip: Clip)

    /// Overwrites the clip's timeline range without rippling later items.
    case overwriteClip(sequenceID: UUID, trackID: UUID, clip: Clip)

    /// Appends a clip after the last item on an existing track.
    case appendClip(sequenceID: UUID, trackID: UUID, clip: Clip)

    /// Removes a clip from an existing track.
    case removeClip(sequenceID: UUID, trackID: UUID, clipID: UUID)

    /// Swaps a clip source while keeping its timeline placement.
    case replaceClipSource(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        source: ClipSource,
        sourceRange: TimeRange
    )

    /// Places a source in/out range at a timeline target as an insert or overwrite edit.
    case threePointEdit(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        source: ClipSource,
        sourceRange: TimeRange,
        timelineStart: RationalTime,
        kind: TrackKind,
        name: String,
        mode: ThreePointEditMode
    )

    /// Inserts a compound clip referencing another sequence.
    case insertCompoundClip(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        targetSequenceID: UUID,
        timelineStart: RationalTime,
        kind: TrackKind,
        name: String
    )

    /// Collapses selected clips into a new nested sequence and a replacement compound clip.
    case makeCompoundClip(
        sequenceID: UUID,
        compoundSequenceID: UUID,
        compoundClipID: UUID,
        selectedClips: [ClipReference],
        name: String
    )

    /// Expands a compound clip's referenced sequence back into the parent timeline.
    case decomposeCompoundClip(sequenceID: UUID, trackID: UUID, clipID: UUID)

    /// Splits a clip at a timeline time into two adjacent clips.
    case bladeClip(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        atTime: RationalTime,
        rightClipID: UUID
    )

    /// Trims a clip and ripples later items by the trim delta.
    case rippleTrimClip(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        sourceRange: TimeRange,
        timelineRange: TimeRange,
        linkedClipEditMode: LinkedClipEditMode = .linked
    )

    /// Moves the shared edit point between two adjacent clips.
    case rollEdit(
        sequenceID: UUID,
        trackID: UUID,
        leftClipID: UUID,
        rightClipID: UUID,
        editTime: RationalTime
    )

    /// Changes a clip's source in/out while keeping its timeline placement fixed.
    case slipClip(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        sourceRange: TimeRange,
        linkedClipEditMode: LinkedClipEditMode = .linked
    )

    /// Moves a clip while adjusting the neighboring items to preserve the outer span.
    case slideClip(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        timelineRange: TimeRange,
        linkedClipEditMode: LinkedClipEditMode = .linked
    )

    /// Removes a clip and shifts later items left by the removed duration.
    case rippleDeleteClip(sequenceID: UUID, trackID: UUID, clipID: UUID)

    /// Removes a clip and leaves a gap with the same timeline range.
    case liftClip(sequenceID: UUID, trackID: UUID, clipID: UUID)

    /// Updates track playback/editing state flags without changing track items or order.
    case setTrackState(
        sequenceID: UUID,
        trackID: UUID,
        state: TrackStatePatch
    )

    /// Updates track-level blend and opacity without changing track items or order.
    case setTrackCompositing(
        sequenceID: UUID,
        trackID: UUID,
        compositing: TrackCompositingPatch
    )

    /// Updates track-level audio gain and pan without changing track items or order.
    case setTrackAudioMix(
        sequenceID: UUID,
        trackID: UUID,
        audio: TrackAudioMixPatch
    )

    /// Clears track-level audio gain and pan back to unity/center defaults.
    case clearTrackAudioMix(sequenceID: UUID, trackID: UUID)

    /// Moves a clip to a new track/range.
    case moveClip(
        sequenceID: UUID,
        sourceTrackID: UUID,
        clipID: UUID,
        destinationTrackID: UUID,
        timelineRange: TimeRange,
        linkedClipEditMode: LinkedClipEditMode = .linked
    )

    /// Updates a clip's source and timeline ranges.
    case trimClip(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        sourceRange: TimeRange,
        timelineRange: TimeRange,
        linkedClipEditMode: LinkedClipEditMode = .linked
    )

    /// Replaces a clip's visual transform.
    case setClipTransform(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        transform: ClipTransform
    )

    /// Replaces a clip's constant playback speed and derives its timeline duration.
    case setClipSpeed(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        speed: RationalValue
    )

    /// Adds a keyframe to one transform parameter.
    case addClipTransformKeyframe(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        parameter: ClipTransformParameter,
        keyframe: ClipTransformKeyframe
    )

    /// Moves or replaces a keyframe on one transform parameter.
    case moveClipTransformKeyframe(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        parameter: ClipTransformParameter,
        fromTime: RationalTime,
        keyframe: ClipTransformKeyframe
    )

    /// Deletes a keyframe from one transform parameter.
    case deleteClipTransformKeyframe(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        parameter: ClipTransformParameter,
        time: RationalTime
    )

    /// Replaces a clip's chroma-key settings.
    case setClipChromaKey(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        settings: ClipChromaKeySettings
    )

    /// Replaces a clip's luma-key settings.
    case setClipLumaKey(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        settings: ClipLumaKeySettings
    )

    /// Clears a clip's luma key back to disabled defaults.
    case clearClipLumaKey(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID
    )

    /// Replaces a clip's primary color-correction settings.
    case setClipColorCorrection(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        correction: ClipColorCorrection
    )

    /// Clears a clip's primary color correction back to identity.
    case clearClipColorCorrection(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID
    )

    /// Adds a clip mask to the end of the ordered mask list.
    case addClipMask(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        mask: ClipMask
    )

    /// Removes a clip mask by stable mask ID.
    case removeClipMask(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        maskID: UUID
    )

    /// Moves a clip mask to a new ordered index.
    case moveClipMask(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        maskID: UUID,
        destinationIndex: Int
    )

    /// Replaces an existing clip mask with the same stable mask ID.
    case setClipMask(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        mask: ClipMask
    )

    /// Replaces a clip's audio gain, pan, fades, and crossfade metadata.
    case setClipAudioMix(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        audioMix: ClipAudioMix
    )

    /// Clears a clip's audio mix back to unity gain, center pan, and no fades.
    case clearClipAudioMix(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID
    )

    /// Selects pitch-shifted (varispeed) or pitch-corrected (WSOLA) audio for a retimed clip
    /// (FR-SPD-001). `pitchCorrected` is rejected with a typed error on freeze-frame or
    /// time-remapped clips.
    case setClipAudioRetimeMode(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        mode: ClipAudioRetimeMode
    )

    /// Creates or updates the ADR-0015 crossfade pair on the cut after a clip: the
    /// addressed clip gets the owning trailing record, its abutting next clip the mirror
    /// (FR-AUD-002). A `nil` curve selects `linear` for same-source contiguous edges and
    /// `equalPower` otherwise; the duration is clamped to the available tail handle.
    case setClipAudioCrossfade(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        duration: RationalTime,
        curve: ClipAudioFadeCurve? = nil
    )

    /// Removes both records of the crossfade pair owned by a clip's trailing edge
    /// (FR-AUD-002).
    case removeClipAudioCrossfade(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID
    )

    /// Breaks a linked A/V clip group so the audio clip can be edited independently.
    case detachClipAudio(sequenceID: UUID, trackID: UUID, clipID: UUID)

    /// Replaces an audio clip's media source while preserving its edits and audio mix.
    case replaceClipAudioSource(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        mediaID: UUID
    )

    /// Adds a video or audio track to a sequence.
    case addTrack(sequenceID: UUID, track: Track)

    /// Removes a track from a sequence.
    case removeTrack(sequenceID: UUID, trackID: UUID)

    /// Adds a sequence to the project.
    case addSequence(Sequence)

    /// Removes a sequence from the project.
    case removeSequence(sequenceID: UUID)

    /// Adds a caller-provided duplicate after the source sequence.
    case duplicateSequence(sourceSequenceID: UUID, duplicate: Sequence)

    /// Renames a sequence.
    case renameSequence(sequenceID: UUID, name: String)

    /// Replaces sequence-level sidechain ducking rules.
    case setSequenceAudioDucking(sequenceID: UUID, ducking: [AudioDuckingRule])

    /// Clears sequence-level sidechain ducking rules.
    case clearSequenceAudioDucking(sequenceID: UUID)

    /// Adds a marker to a sequence.
    case addMarker(sequenceID: UUID, marker: Marker)

    /// Removes a marker from a sequence.
    case removeMarker(sequenceID: UUID, markerID: UUID)

    /// Updates an existing marker.
    case updateMarker(sequenceID: UUID, marker: Marker)

    /// Assigns a shared link group to video/audio clips.
    case linkClips(sequenceID: UUID, linkGroupID: UUID, clips: [ClipReference])

    /// Removes a shared link group from every clip in a sequence.
    case unlinkClips(sequenceID: UUID, linkGroupID: UUID)

    /// Replaces project-wide settings.
    case setProjectSettings(ProjectSettings)
}

/// Typed failures from the edit reducer.
public enum EditReducerError: Error, Equatable, Sendable {
    /// The command references a missing sequence.
    case sequenceNotFound(UUID)

    /// The command references a missing track.
    case trackNotFound(sequenceID: UUID, trackID: UUID)

    /// The command references a missing clip.
    case clipNotFound(sequenceID: UUID, trackID: UUID, clipID: UUID)

    /// The command references a missing marker.
    case markerNotFound(sequenceID: UUID, markerID: UUID)

    /// The command would create duplicate sequence IDs inside the project.
    case duplicateSequenceID(UUID)

    /// The command would leave the project without any editable sequence.
    case cannotRemoveLastSequence(UUID)

    /// The command would create duplicate track IDs inside a sequence.
    case duplicateTrackID(sequenceID: UUID, trackID: UUID)

    /// The command would create duplicate marker IDs inside a sequence.
    case duplicateMarkerID(sequenceID: UUID, markerID: UUID)

    /// The command references a missing link group.
    case linkGroupNotFound(sequenceID: UUID, linkGroupID: UUID)

    /// The command's requested edit is not valid for the current timeline state.
    case invalidEdit(EditCommandValidationError)

    /// Exact timeline arithmetic failed while applying the command.
    case timeArithmeticFailed(RationalTimeError)

    /// The command produced a project that failed central validation.
    case validationFailed([ProjectValidationError])
}

/// Pure reducer entry point required by ADR-0008.
public func apply(_ command: EditCommand, to project: Project) throws -> Project {
    try EditReducer.apply(command, to: project)
}

/// Pure project edit reducer.
public enum EditReducer {
    /// Applies `command` to `project`, returning a new validated project.
    public static func apply(_ command: EditCommand, to project: Project) throws -> Project {
        try validated(try applyUnchecked(command, to: project))
    }
}
