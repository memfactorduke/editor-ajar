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

    /// A clip mask edit referenced a missing mask.
    case clipMaskNotFound(clipID: UUID, maskID: UUID)

    /// A clip mask reorder target was outside the mask list.
    case clipMaskDestinationIndexOutOfRange(clipID: UUID, index: Int, count: Int)
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

public extension EditCommand {
    /// Human-readable action name for menus, autosave logs, and diagnostics.
    var actionName: String {
        switch self {
        case .addClip:
            return "Add Clip"
        case .insertClip:
            return "Insert Clip"
        case .overwriteClip:
            return "Overwrite Clip"
        case .appendClip:
            return "Append Clip"
        case .removeClip:
            return "Remove Clip"
        case .replaceClipSource:
            return "Replace Clip Source"
        case .threePointEdit:
            return "Three-Point Edit"
        case .bladeClip:
            return "Blade Clip"
        case .rippleTrimClip:
            return "Ripple Trim"
        case .rollEdit:
            return "Roll Edit"
        case .slipClip:
            return "Slip Clip"
        case .slideClip:
            return "Slide Clip"
        case .rippleDeleteClip:
            return "Ripple Delete"
        case .liftClip:
            return "Lift Clip"
        case .setTrackState:
            return "Change Track State"
        case .setTrackCompositing:
            return "Set Track Compositing"
        case .moveClip:
            return "Move Clip"
        case .trimClip:
            return "Trim Clip"
        case .setClipTransform:
            return "Set Clip Transform"
        case .addClipTransformKeyframe:
            return "Add Transform Keyframe"
        case .moveClipTransformKeyframe:
            return "Move Transform Keyframe"
        case .deleteClipTransformKeyframe:
            return "Delete Transform Keyframe"
        case .setClipChromaKey:
            return "Set Chroma Key"
        case .setClipLumaKey:
            return "Set Luma Key"
        case .clearClipLumaKey:
            return "Clear Luma Key"
        case .setClipColorCorrection:
            return "Set Color Correction"
        case .clearClipColorCorrection:
            return "Clear Color Correction"
        case .addClipMask:
            return "Add Clip Mask"
        case .removeClipMask:
            return "Remove Clip Mask"
        case .moveClipMask:
            return "Reorder Clip Mask"
        case .setClipMask:
            return "Set Clip Mask"
        case .addTrack:
            return "Add Track"
        case .removeTrack:
            return "Remove Track"
        case .addSequence:
            return "Add Sequence"
        case .removeSequence:
            return "Remove Sequence"
        case .duplicateSequence:
            return "Duplicate Sequence"
        case .renameSequence:
            return "Rename Sequence"
        case .addMarker:
            return "Add Marker"
        case .removeMarker:
            return "Delete Marker"
        case .updateMarker:
            return "Update Marker"
        case .linkClips:
            return "Link Clips"
        case .unlinkClips:
            return "Detach Audio"
        case .setProjectSettings:
            return "Change Project Settings"
        }
    }
}
