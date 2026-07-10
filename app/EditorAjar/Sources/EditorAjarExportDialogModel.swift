// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarExport
import Foundation

/// Export product mode exposed by the minimal export dialog (FR-EXP-003/004).
enum EditorAjarExportMode: String, CaseIterable, Equatable, Sendable, Identifiable {
    case video
    case stillFrame
    case audioOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video:
            "Video"
        case .stillFrame:
            "Still frame"
        case .audioOnly:
            "Audio only"
        }
    }
}

/// Range choice for video / audio-only export (FR-EXP-004).
enum EditorAjarExportRangeChoice: String, CaseIterable, Equatable, Sendable, Identifiable {
    case wholeTimeline
    case inOutMarks

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wholeTimeline:
            "Whole timeline"
        case .inOutMarks:
            "In/out range"
        }
    }
}

/// Still image format for the dialog.
enum EditorAjarStillFormatChoice: String, CaseIterable, Equatable, Sendable, Identifiable {
    case png
    case jpeg

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png:
            "PNG"
        case .jpeg:
            "JPEG"
        }
    }

    var stillFormat: StillImageFormat {
        switch self {
        case .png:
            .png
        case .jpeg:
            .jpeg
        }
    }
}

/// Audio-only format for the dialog.
enum EditorAjarAudioOnlyFormatChoice: String, CaseIterable, Equatable, Sendable, Identifiable {
    case wavPCM
    case aacM4A

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wavPCM:
            "WAV (PCM)"
        case .aacM4A:
            "M4A (AAC)"
        }
    }
}

/// Pure, testable state for the export dialog (no SwiftUI / no disk I/O on mutation).
///
/// Persistence of custom presets is owned by `EditorAjarExportPresetStore`. This model only holds
/// the current picker selection and validates range/mode combinations against the open project.
struct EditorAjarExportDialogModel: Equatable, Sendable {
    var isPresented: Bool
    var mode: EditorAjarExportMode
    var rangeChoice: EditorAjarExportRangeChoice
    var selectedPresetID: UUID?
    var availablePresets: [ExportPreset]
    var stillFormat: EditorAjarStillFormatChoice
    var audioOnlyFormat: EditorAjarAudioOnlyFormatChoice
    var statusMessage: String?

    init(
        isPresented: Bool = false,
        mode: EditorAjarExportMode = .video,
        rangeChoice: EditorAjarExportRangeChoice = .wholeTimeline,
        selectedPresetID: UUID? = ExportBuiltInPresets.youTube1080pID,
        availablePresets: [ExportPreset] = ExportBuiltInPresets.all,
        stillFormat: EditorAjarStillFormatChoice = .png,
        audioOnlyFormat: EditorAjarAudioOnlyFormatChoice = .wavPCM,
        statusMessage: String? = nil
    ) {
        self.isPresented = isPresented
        self.mode = mode
        self.rangeChoice = rangeChoice
        self.selectedPresetID = selectedPresetID
        self.availablePresets = availablePresets
        self.stillFormat = stillFormat
        self.audioOnlyFormat = audioOnlyFormat
        self.statusMessage = statusMessage
    }

    var selectedPreset: ExportPreset? {
        availablePresets.first { $0.id == selectedPresetID } ?? availablePresets.first
    }

    /// Resolves the export timeline range from dialog choice + sequence + in/out marks.
    func resolvedRange(
        sequence: Sequence,
        selectionInFrame: Int64?,
        selectionOutFrame: Int64?
    ) throws -> TimeRange {
        switch rangeChoice {
        case .wholeTimeline:
            return try ExportRangeResolver.resolve(.wholeTimeline, sequence: sequence)
        case .inOutMarks:
            guard let inFrame = selectionInFrame, let outFrame = selectionOutFrame else {
                throw ExportError.emptyOrInvertedRange(start: .zero, end: .zero)
            }
            let startFrame = min(inFrame, outFrame)
            let endFrame = max(inFrame, outFrame)
            // NLE convention: out mark is inclusive. Export the half-open engine range
            // [start, end+1) so a UI range "0-2" yields frames 0, 1, and 2. Equal marks
            // export a single frame. Inverted marks are swapped (min/max above).
            let exclusiveEndFrame = endFrame + 1
            let inPoint = try RationalTime.atFrame(startFrame, frameRate: sequence.timebase)
            let outPoint = try RationalTime.atFrame(
                exclusiveEndFrame,
                frameRate: sequence.timebase
            )
            return try ExportRangeResolver.resolve(
                .inOut(inPoint: inPoint, outPoint: outPoint),
                sequence: sequence
            )
        }
    }

    /// Builds validated video export settings from the selected preset.
    func makeVideoSettings() throws -> ExportSettings {
        guard let preset = selectedPreset else {
            throw ExportError.stillFrameWriteFailed("no export preset selected")
        }
        return try preset.makeSettings()
    }

    /// Builds validated audio-only settings for the dialog format choice.
    func makeAudioOnlySettings(projectSampleRate: Int) throws -> AudioOnlyExportSettings {
        switch audioOnlyFormat {
        case .wavPCM:
            return try AudioOnlyExportSettings(
                container: .wav,
                codec: .linearPCM,
                sampleRate: projectSampleRate,
                channelCount: 2
            )
        case .aacM4A:
            return try AudioOnlyExportSettings(
                container: .m4a,
                codec: .aac,
                sampleRate: projectSampleRate,
                channelCount: 2,
                bitRate: 192_000
            )
        }
    }

    /// Suggested file extension for the current mode/format/preset.
    var suggestedPathExtension: String {
        switch mode {
        case .video:
            return selectedPreset?.container.rawValue ?? "mp4"
        case .stillFrame:
            return stillFormat == .png ? "png" : "jpg"
        case .audioOnly:
            return audioOnlyFormat == .wavPCM ? "wav" : "m4a"
        }
    }
}
