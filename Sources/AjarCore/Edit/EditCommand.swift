// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// User-visible reason a prepared media-reference rewrite is entering undo history.
public enum MediaReferenceEditKind: String, Codable, Equatable, Sendable {
    /// One media source was relinked explicitly.
    case relink

    /// Multiple offline sources were matched recursively in a folder.
    case batchRelink

    /// Referenced originals were copied into the project package.
    case consolidate
}

// swiftlint:disable file_length type_body_length
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

    /// Adds a node to the per-clip video effects stack (FR-FX-003).
    ///
    /// When `destinationIndex` is `nil`, the node is appended. Otherwise it is inserted at
    /// that index (0...count inclusive).
    case addClipEffectNode(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        node: ClipEffectNode,
        destinationIndex: Int? = nil
    )

    /// Removes a node from the per-clip video effects stack by stable ID (FR-FX-003).
    case removeClipEffectNode(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        nodeID: UUID
    )

    /// Reorders a node within the per-clip video effects stack (FR-FX-003).
    case moveClipEffectNode(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        nodeID: UUID,
        destinationIndex: Int
    )

    /// Enables or disables one effects-stack node without changing its parameters (FR-FX-003).
    case setClipEffectNodeEnabled(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        nodeID: UUID,
        enabled: Bool
    )

    /// Replaces the typed parameters of one effects-stack node; kind must match (FR-FX-003).
    case setClipEffectNodeParameters(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        nodeID: UUID,
        definition: ClipEffectDefinition
    )

    /// Resets one effects-stack node's parameters to that kind's identity defaults (FR-FX-003).
    case resetClipEffectNode(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        nodeID: UUID
    )

    /// Clears the entire per-clip video effects stack (FR-FX-003).
    case resetClipEffectStack(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID
    )

    /// Replaces a target clip's color-grade nodes with fresh-ID copies from another clip.
    ///
    /// Grade animation is flattened to base values; grades and looks are static snapshots.
    case copyClipGrade(
        source: ProjectClipReference,
        target: ProjectClipReference,
        newNodeIDs: [UUID]
    )

    /// Saves a source clip's color grade as a named project look.
    ///
    /// Grade animation is flattened to base values; grades and looks are static snapshots.
    case saveLookFromClip(
        source: ProjectClipReference,
        lookID: UUID,
        name: String
    )

    /// Replaces a target clip's color grade with a fresh-ID copy of a saved project look.
    ///
    /// Grade animation is flattened to base values; grades and looks are static snapshots.
    case applyLookToClip(
        lookID: UUID,
        target: ProjectClipReference,
        newNodeIDs: [UUID]
    )

    /// Renames a saved project look.
    case renameLook(lookID: UUID, name: String)

    /// Deletes a saved project look.
    case deleteLook(lookID: UUID)

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

    /// Creates or updates the ADR-0016 §5 video transition pair on the cut after a clip
    /// (FR-FX-001). Duration is clamped to the available fade-tail source handle; sequence
    /// duration is never changed. Independent of any audio crossfade on the same cut.
    case setClipVideoTransition(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        duration: RationalTime,
        kind: ClipVideoTransitionKind,
        color: ClipRGBColor? = nil,
        direction: ClipVideoTransitionDirection? = nil
    )

    /// Removes both records of the video transition pair owned by a clip's trailing edge
    /// (FR-FX-001).
    case removeClipVideoTransition(
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

    /// Inserts a title generator clip on a video track (FR-TXT-001).
    case insertTitleClip(
        sequenceID: UUID, trackID: UUID, clipID: UUID, title: TitleSource,
        timelineRange: TimeRange, name: String
    )

    /// Replaces the title source on an existing title clip (FR-TXT-001).
    case setClipTitleSource(sequenceID: UUID, trackID: UUID, clipID: UUID, title: TitleSource)

    /// Creates or replaces one text box on a title clip (FR-TXT-001).
    case setTitleTextBox(sequenceID: UUID, trackID: UUID, clipID: UUID, box: TitleTextBox)

    /// Removes one text box from a title clip by stable box ID (FR-TXT-001).
    case removeTitleTextBox(sequenceID: UUID, trackID: UUID, clipID: UUID, boxID: UUID)

    /// Applies a built-in title animation preset as ordinary keyframes (FR-TXT-004).
    ///
    /// One undoable edit: writes transform and/or `revealFraction` keyframes (and lower-third
    /// FR-TXT-002 styling when requested). Applying again replaces cleanly.
    case applyTitleAnimationPreset(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        preset: TitleAnimationPreset
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

    /// Replaces complete media references after platform I/O has already succeeded.
    ///
    /// URLs are never resolved, hashed, bookmarked, or copied by the reducer. Keeping those
    /// side effects in `AjarMedia` makes redo and crash-journal replay deterministic.
    case updateMediaReferences(
        kind: MediaReferenceEditKind,
        replacements: [MediaRef]
    )
}
// swiftlint:enable file_length type_body_length
