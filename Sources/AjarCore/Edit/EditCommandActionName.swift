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
        }
    }
}
