// SPDX-License-Identifier: GPL-3.0-or-later

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
        case .insertCompoundClip:
            return "Insert Compound Clip"
        case .makeCompoundClip:
            return "Make Compound Clip"
        case .decomposeCompoundClip:
            return "Decompose Compound Clip"
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
        case .setTrackAudioMix:
            return "Set Track Audio Mix"
        case .clearTrackAudioMix:
            return "Clear Track Audio Mix"
        case .moveClip:
            return "Move Clip"
        case .trimClip:
            return "Trim Clip"
        case .setClipTransform:
            return "Set Clip Transform"
        case .setClipSpeed:
            return "Set Clip Speed"
        case .setClipPlaybackAttributes:
            return "Set Clip Playback"
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
        case .addClipEffectNode:
            return "Add Effect"
        case .removeClipEffectNode:
            return "Remove Effect"
        case .moveClipEffectNode:
            return "Reorder Effect"
        case .setClipEffectNodeEnabled:
            return "Toggle Effect"
        case .setClipEffectNodeParameters:
            return "Set Effect Parameters"
        case .resetClipEffectNode:
            return "Reset Effect"
        case .resetClipEffectStack:
            return "Reset Effects Stack"
        case .copyClipGrade:
            return "Copy Grade"
        case .saveLookFromClip:
            return "Save Look"
        case .applyLookToClip:
            return "Apply Look"
        case .renameLook:
            return "Rename Look"
        case .deleteLook:
            return "Delete Look"
        case .setClipAudioMix:
            return "Set Clip Audio Mix"
        case .clearClipAudioMix:
            return "Clear Clip Audio Mix"
        case .setClipAudioRetimeMode:
            return "Set Audio Retime Mode"
        case .setClipAudioCrossfade:
            return "Add Crossfade"
        case .removeClipAudioCrossfade:
            return "Remove Crossfade"
        case .setClipVideoTransition:
            return "Add Transition"
        case .removeClipVideoTransition:
            return "Remove Transition"
        case .detachClipAudio:
            return "Detach Audio"
        case .replaceClipAudioSource:
            return "Replace Clip Audio"
        case .insertTitleClip:
            return "Insert Title"
        case .setClipTitleSource:
            return "Set Title"
        case .setTitleTextBox:
            return "Set Title Text Box"
        case .removeTitleTextBox:
            return "Remove Title Text Box"
        case .applyTitleAnimationPreset:
            return "Apply Title Animation"
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
        case .setSequenceAudioDucking:
            return "Set Audio Ducking"
        case .clearSequenceAudioDucking:
            return "Clear Audio Ducking"
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
        case .addMediaReferences:
            return "Import Media"
        case .updateMediaReferences(let kind, _):
            switch kind {
            case .relink:
                return "Relink Media"
            case .batchRelink:
                return "Batch Relink Media"
            case .consolidate:
                return "Consolidate Media"
            }
        case .transaction(let commands):
            // A transaction reads as its shared sub-command name when uniform (e.g. a multi-clip
            // ripple delete undoes as "Ripple Delete"), otherwise as a generic grouped label.
            let names = Set(commands.map(\.actionName))
            if let only = names.first, names.count == 1 {
                return only
            }
            // Creating a muxed A/V placement is one gesture even though it places two clips and
            // then validates their link. Mid-clip insert additionally blades/relinks the old pair
            // first. Keep the undo label on the user's requested operation, not implementation
            // scaffolding such as "Link Clips" or "Add Clip".
            if let placementName = Self.linkedPlacementTransactionActionName(commands) {
                return placementName
            }
            // Occupied-track / locked-track title insert is one user gesture: create a free video
            // track, then insert the title on it (`insertTitleAtPlayhead` via `applyEditGroup`).
            // Track creation is scaffolding — the undo menu should still say "Insert Title", not
            // "Multiple Edits" (#240 MIXED default vs FR-TXT-001 overlay insert). Pure shape
            // match only; no persisted label field on the enum.
            if commands.count == 2 {
                switch (commands[0], commands[1]) {
                case (.addTrack, .insertTitleClip):
                    return commands[1].actionName
                default:
                    break
                }
            }
            return "Multiple Edits"
        }
    }

    // Counting the allowed command shapes is clearer here than scattering nested pattern matches.
    // swiftlint:disable:next cyclomatic_complexity
    private static func linkedPlacementTransactionActionName(
        _ commands: [EditCommand]
    ) -> String? {
        var addCount = 0
        var insertCount = 0
        var overwriteCount = 0
        var appendCount = 0
        var threePointCount = 0
        var bladeCount = 0
        var linkCount = 0
        var containsOtherCommand = false

        for command in commands {
            switch command {
            case .addClip:
                addCount += 1
            case .insertClip:
                insertCount += 1
            case .overwriteClip:
                overwriteCount += 1
            case .appendClip:
                appendCount += 1
            case .threePointEdit:
                threePointCount += 1
            case .bladeClip:
                bladeCount += 1
            case .linkClips:
                linkCount += 1
            default:
                containsOtherCommand = true
            }
        }

        guard linkCount > 0, !containsOtherCommand else {
            return nil
        }

        let placementCount =
            addCount + insertCount + overwriteCount + appendCount + threePointCount
        if threePointCount >= 2 && placementCount == threePointCount {
            return "Three-Point Edit"
        }
        if insertCount >= 2 && placementCount == insertCount {
            return "Insert Clip"
        }
        if overwriteCount >= 2 && placementCount == overwriteCount && bladeCount == 0 {
            return "Overwrite Clip"
        }
        let appendPlacementCount = addCount + appendCount
        let isAppendPair = appendPlacementCount == 2 && appendCount > 0
        let containsOnlyAppendCommands = placementCount == appendPlacementCount && bladeCount == 0
        if isAppendPair && containsOnlyAppendCommands {
            return "Append Clip"
        }
        if bladeCount >= 2 && placementCount == 0 {
            return "Blade Clip"
        }
        return nil
    }
}
