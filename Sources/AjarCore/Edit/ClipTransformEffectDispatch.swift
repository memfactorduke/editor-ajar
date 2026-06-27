// SPDX-License-Identifier: GPL-3.0-or-later

extension EditReducer {
    static func applyTransformClipCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .setClipTransform(let sequenceID, let trackID, let clipID, let transform):
            return try setClipTransform(
                SetClipTransformEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    transform: transform
                ),
                in: project
            )
        case .addClipTransformKeyframe, .moveClipTransformKeyframe, .deleteClipTransformKeyframe:
            return try applyTransformKeyframeCommand(command, to: project)
        case .setClipChromaKey(let sequenceID, let trackID, let clipID, let settings):
            return try setClipChromaKey(
                SetClipChromaKeyEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    settings: settings
                ),
                in: project
            )
        case .setClipColorCorrection(let sequenceID, let trackID, let clipID, let correction):
            return try setClipColorCorrection(
                SetClipColorCorrectionEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    correction: correction
                ),
                in: project
            )
        case .clearClipColorCorrection(let sequenceID, let trackID, let clipID):
            return try clearClipColorCorrection(
                ClipEffectsEditTarget(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID
                ),
                in: project
            )
        default:
            throw EditReducerError.validationFailed([])
        }
    }
}
