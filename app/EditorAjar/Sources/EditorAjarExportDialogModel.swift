// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarExport
import Foundation

/// Export product mode exposed by the minimal export dialog (FR-EXP-003/004).
enum EditorAjarExportMode: String, CaseIterable, Equatable, Sendable, Identifiable {
    case video
    case animatedGIF
    case stillFrame
    case audioOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video:
            AppString.localized("export.mode.video", "Video")
        case .animatedGIF:
            AppString.localized("export.mode.animatedGIF", "Animated GIF")
        case .stillFrame:
            AppString.localized("export.mode.stillFrame", "Still frame")
        case .audioOnly:
            AppString.localized("export.mode.audioOnly", "Audio only")
        }
    }
}

/// Output raster choices for animated GIF. Every choice applies one uniform scale to both axes.
enum EditorAjarAnimatedGIFSizeChoice: String, CaseIterable, Equatable, Sendable, Identifiable {
    case original
    case half
    case quarter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original:
            AppString.localized("export.gif.size.original", "Original")
        case .half:
            AppString.localized("export.gif.size.half", "Half")
        case .quarter:
            AppString.localized("export.gif.size.quarter", "Quarter")
        }
    }

    /// Scales the project raster uniformly, rounding each pixel dimension to the nearest integer.
    func dimensions(for original: PixelDimensions) -> PixelDimensions {
        let scale: Double
        switch self {
        case .original:
            scale = 1
        case .half:
            scale = 0.5
        case .quarter:
            scale = 0.25
        }
        return PixelDimensions(
            width: max(1, Int((Double(original.width) * scale).rounded())),
            height: max(1, Int((Double(original.height) * scale).rounded()))
        )
    }
}

/// GIF sampling rates chosen to balance motion quality and file size.
enum EditorAjarAnimatedGIFFrameRateChoice:
    Int, CaseIterable, Equatable, Sendable, Identifiable
{
    case fps10 = 10
    case fps15 = 15
    case fps24 = 24
    case fps30 = 30

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .fps10:
            AppString.localized("export.gif.frameRate.fps10", "10 fps")
        case .fps15:
            AppString.localized("export.gif.frameRate.fps15", "15 fps")
        case .fps24:
            AppString.localized("export.gif.frameRate.fps24", "24 fps")
        case .fps30:
            AppString.localized("export.gif.frameRate.fps30", "30 fps")
        }
    }

    func makeFrameRate() throws -> FrameRate {
        try FrameRate(frames: Int64(rawValue))
    }
}

/// Playback behavior written into the exported GIF metadata.
enum EditorAjarAnimatedGIFLoopChoice: String, CaseIterable, Equatable, Sendable, Identifiable {
    case forever
    case playOnce

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forever:
            AppString.localized("export.gif.loop.forever", "Forever")
        case .playOnce:
            AppString.localized("export.gif.loop.playOnce", "Play once")
        }
    }

    var loopPolicy: AnimatedGIFLoopPolicy {
        switch self {
        case .forever:
            .forever
        case .playOnce:
            .playOnce
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
            AppString.localized("export.range.wholeTimeline", "Whole timeline")
        case .inOutMarks:
            AppString.localized("export.range.inOut", "In/out range")
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
    var animatedGIFSizeChoice: EditorAjarAnimatedGIFSizeChoice
    var animatedGIFFrameRateChoice: EditorAjarAnimatedGIFFrameRateChoice
    var animatedGIFLoopChoice: EditorAjarAnimatedGIFLoopChoice
    var statusMessage: String?

    init(
        isPresented: Bool = false,
        mode: EditorAjarExportMode = .video,
        rangeChoice: EditorAjarExportRangeChoice = .wholeTimeline,
        selectedPresetID: UUID? = ExportBuiltInPresets.youTube1080pID,
        availablePresets: [ExportPreset] = ExportBuiltInPresets.all,
        stillFormat: EditorAjarStillFormatChoice = .png,
        audioOnlyFormat: EditorAjarAudioOnlyFormatChoice = .wavPCM,
        animatedGIFSizeChoice: EditorAjarAnimatedGIFSizeChoice = .half,
        animatedGIFFrameRateChoice: EditorAjarAnimatedGIFFrameRateChoice = .fps15,
        animatedGIFLoopChoice: EditorAjarAnimatedGIFLoopChoice = .forever,
        statusMessage: String? = nil
    ) {
        self.isPresented = isPresented
        self.mode = mode
        self.rangeChoice = rangeChoice
        self.selectedPresetID = selectedPresetID
        self.availablePresets = availablePresets
        self.stillFormat = stillFormat
        self.audioOnlyFormat = audioOnlyFormat
        self.animatedGIFSizeChoice = animatedGIFSizeChoice
        self.animatedGIFFrameRateChoice = animatedGIFFrameRateChoice
        self.animatedGIFLoopChoice = animatedGIFLoopChoice
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

    /// Builds validated video export settings from the selected preset and project delivery
    /// settings.
    ///
    /// Presets choose the container, codec, raster, frame rate, and rate control. Color space and
    /// audio sample rate must follow the project because the export engine deliberately rejects a
    /// request that would silently reinterpret either timeline setting.
    func makeVideoSettings(project: Project) throws -> ExportSettings {
        guard let preset = selectedPreset else {
            throw ExportError.stillFrameWriteFailed("no export preset selected")
        }
        let colorSpace = try Self.exportColorSpace(for: project.settings.colorSpace)
        do {
            let video = try ExportVideoSettings(
                codec: preset.videoCodec,
                resolution: preset.resolution,
                frameRate: preset.frameRate,
                averageBitRate: preset.averageBitRate,
                quality: preset.quality,
                colorSpace: colorSpace
            )
            let audio = try preset.audio.map {
                try ExportAudioSettings(
                    codec: $0.codec,
                    sampleRate: project.settings.audioSampleRate,
                    channelCount: $0.channelCount,
                    bitRate: $0.bitRate
                )
            }
            return try ExportSettings(
                container: preset.container,
                video: video,
                audio: audio
            )
        } catch let error as ExportSettingsValidationError {
            throw ExportError.invalidSettings(error)
        }
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

    /// Builds validated animated-GIF settings from the project canvas and delivery space.
    func makeAnimatedGIFSettings(project: Project) throws -> AnimatedGIFExportSettings {
        let sourceColorSpace = try Self.exportColorSpace(for: project.settings.colorSpace)
        return try AnimatedGIFExportSettings(
            resolution: animatedGIFSizeChoice.dimensions(for: project.settings.resolution),
            frameRate: animatedGIFFrameRateChoice.makeFrameRate(),
            sourceColorSpace: sourceColorSpace,
            loopPolicy: animatedGIFLoopChoice.loopPolicy
        )
    }

    /// Suggested file extension for the current mode/format/preset.
    var suggestedPathExtension: String {
        switch mode {
        case .video:
            return selectedPreset?.container.rawValue ?? "mp4"
        case .animatedGIF:
            return "gif"
        case .stillFrame:
            return stillFormat == .png ? "png" : "jpg"
        case .audioOnly:
            return audioOnlyFormat == .wavPCM ? "wav" : "m4a"
        }
    }

    private static func exportColorSpace(
        for mediaColorSpace: MediaColorSpace
    ) throws -> ExportColorSpace {
        switch mediaColorSpace {
        case .rec709:
            return .rec709
        case .sRGB:
            return .sRGB
        case .displayP3:
            return .displayP3
        case .rec2020, .unspecified, .unknown:
            throw ExportError.colorSpaceMismatch(
                project: mediaColorSpace,
                export: .rec709
            )
        }
    }
}
