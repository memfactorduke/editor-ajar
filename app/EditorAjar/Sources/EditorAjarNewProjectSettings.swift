// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import Foundation

/// Common new-project raster choices (FR-PROJ-003).
enum EditorAjarProjectResolutionChoice: String, CaseIterable, Identifiable {
    case fullHD
    case ultraHD
    case verticalHD
    case squareHD

    var id: String { rawValue }

    var dimensions: PixelDimensions {
        switch self {
        case .fullHD:
            PixelDimensions(width: 1_920, height: 1_080)
        case .ultraHD:
            PixelDimensions(width: 3_840, height: 2_160)
        case .verticalHD:
            PixelDimensions(width: 1_080, height: 1_920)
        case .squareHD:
            PixelDimensions(width: 1_080, height: 1_080)
        }
    }

    var localizedName: String {
        switch self {
        case .fullHD:
            AppString.localized(
                "document.settings.resolution.fullHD",
                "Full HD — 1920 × 1080"
            )
        case .ultraHD:
            AppString.localized(
                "document.settings.resolution.ultraHD",
                "Ultra HD — 3840 × 2160"
            )
        case .verticalHD:
            AppString.localized(
                "document.settings.resolution.verticalHD",
                "Vertical HD — 1080 × 1920"
            )
        case .squareHD:
            AppString.localized(
                "document.settings.resolution.squareHD",
                "Square HD — 1080 × 1080"
            )
        }
    }
}

/// Exact rational frame-rate choices for new projects.
enum EditorAjarProjectFrameRateChoice: String, CaseIterable, Identifiable {
    case fps23976
    case fps24
    case fps25
    case fps2997
    case fps30
    case fps50
    case fps5994
    case fps60

    var id: String { rawValue }

    func makeFrameRate() throws -> FrameRate {
        // Every case is a positive compile-time rational. Keeping construction throwing preserves
        // the core's typed validation boundary without a force-unwrap or trap.
        let components: (frames: Int64, seconds: Int64)
        switch self {
        case .fps23976:
            components = (24_000, 1_001)
        case .fps24:
            components = (24, 1)
        case .fps25:
            components = (25, 1)
        case .fps2997:
            components = (30_000, 1_001)
        case .fps30:
            components = (30, 1)
        case .fps50:
            components = (50, 1)
        case .fps5994:
            components = (60_000, 1_001)
        case .fps60:
            components = (60, 1)
        }
        return try FrameRate(frames: components.frames, per: components.seconds)
    }

    var localizedName: String {
        switch self {
        case .fps23976:
            AppString.localized("document.settings.frameRate.fps23976", "23.976 fps")
        case .fps24:
            AppString.localized("document.settings.frameRate.fps24", "24 fps")
        case .fps25:
            AppString.localized("document.settings.frameRate.fps25", "25 fps")
        case .fps2997:
            AppString.localized("document.settings.frameRate.fps2997", "29.97 fps")
        case .fps30:
            AppString.localized("document.settings.frameRate.fps30", "30 fps")
        case .fps50:
            AppString.localized("document.settings.frameRate.fps50", "50 fps")
        case .fps5994:
            AppString.localized("document.settings.frameRate.fps5994", "59.94 fps")
        case .fps60:
            AppString.localized("document.settings.frameRate.fps60", "60 fps")
        }
    }

}

/// Supported working color spaces shown by the New Project sheet.
enum EditorAjarProjectColorSpaceChoice: String, CaseIterable, Identifiable {
    case rec709
    case sRGB
    case displayP3

    var id: String { rawValue }

    var colorSpace: MediaColorSpace {
        switch self {
        case .rec709:
            .rec709
        case .sRGB:
            .sRGB
        case .displayP3:
            .displayP3
        }
    }

    var localizedName: String {
        switch self {
        case .rec709:
            AppString.localized("document.settings.colorSpace.rec709", "Rec. 709")
        case .sRGB:
            AppString.localized("document.settings.colorSpace.sRGB", "sRGB")
        case .displayP3:
            AppString.localized("document.settings.colorSpace.displayP3", "Display P3")
        }
    }
}

/// Common project audio sample rates.
enum EditorAjarProjectAudioRateChoice: Int, CaseIterable, Identifiable {
    case hz44100 = 44_100
    case hz48000 = 48_000
    case hz96000 = 96_000

    var id: Int { rawValue }

    var localizedName: String {
        switch self {
        case .hz44100:
            AppString.localized("document.settings.audioRate.khz441", "44.1 kHz")
        case .hz48000:
            AppString.localized("document.settings.audioRate.khz48", "48 kHz")
        case .hz96000:
            AppString.localized("document.settings.audioRate.khz96", "96 kHz")
        }
    }
}

/// Session-only choices collected before creating an untitled document.
struct EditorAjarNewProjectSettings: Equatable {
    var resolutionChoice: EditorAjarProjectResolutionChoice
    var frameRateChoice: EditorAjarProjectFrameRateChoice
    var colorSpaceChoice: EditorAjarProjectColorSpaceChoice
    var audioRateChoice: EditorAjarProjectAudioRateChoice

    static let sensibleDefaults = EditorAjarNewProjectSettings(
        resolutionChoice: .fullHD,
        frameRateChoice: .fps30,
        colorSpaceChoice: .rec709,
        audioRateChoice: .hz48000
    )

    func makeProjectSettings() throws -> ProjectSettings {
        ProjectSettings(
            frameRate: try frameRateChoice.makeFrameRate(),
            resolution: resolutionChoice.dimensions,
            colorSpace: colorSpaceChoice.colorSpace,
            audioSampleRate: audioRateChoice.rawValue
        )
    }
}

/// Creates a valid empty project with one video and one audio track.
enum EditorAjarNewProjectFactory {
    static func makeProject(settings: EditorAjarNewProjectSettings) throws -> Project {
        let projectSettings = try settings.makeProjectSettings()
        let sequence = Sequence(
            id: UUID(),
            name: AppString.localized("document.new.sequenceName", "Sequence 1"),
            videoTracks: [Track(id: UUID(), kind: .video, items: [])],
            audioTracks: [Track(id: UUID(), kind: .audio, items: [])],
            markers: [],
            timebase: projectSettings.frameRate
        )
        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: projectSettings,
            mediaPool: [],
            sequences: [sequence]
        )
    }
}

/// FR-PROJ-003 first-clip auto-detection seam for the #234 import flow.
///
/// The importer calls this when the first media lands in an empty-default project, then the app
/// model presents a confirmation sheet (apply = undoable settings edit; decline = keep).
/// Resolution, exact frame rate (including VFR-conformed rate), and a known color tag come from
/// `MediaMetadata`.
///
/// **Audio sample rate:** not a persisted `MediaMetadata` field (would require `schemaMinor` /
/// ADR-0018). The native probe carries it session-only on `MediaProbeResult.audioSampleRate` →
/// `ImportedMediaItem.audioSampleRate`; callers must pass `detectedAudioSampleRate` for the
/// proposal to pick up the source rate. Without that argument the detector keeps the current
/// project audio rate.
///
/// **Stills propose resolution only** (keep fps/color/audio).
enum EditorAjarFirstClipSettingsDetector {
    /// Whether `media` is a still image (ImageIO codecs from AjarMedia probe).
    static func isStillImage(_ media: MediaRef) -> Bool {
        StillMediaDefaults.isStillCodec(media.metadata.codecID)
            || media.sourceURL.map(StillMediaDefaults.isStillImageFile) == true
    }

    static func detectedSettings(
        from media: MediaRef,
        current: ProjectSettings,
        detectedAudioSampleRate: Int? = nil
    ) -> ProjectSettings {
        let metadata = media.metadata

        // Stills: resolution only — no fps/audio on pure images; keep project timebase/audio.
        if isStillImage(media) {
            return ProjectSettings(
                frameRate: current.frameRate,
                resolution: metadata.pixelDimensions ?? current.resolution,
                colorSpace: current.colorSpace,
                audioSampleRate: current.audioSampleRate,
                preferProxyPlayback: current.preferProxyPlayback
            )
        }

        let detectedColorSpace: MediaColorSpace
        switch metadata.colorSpace {
        case .unspecified, .unknown:
            detectedColorSpace = current.colorSpace
        case .rec709, .sRGB, .displayP3, .rec2020:
            detectedColorSpace = metadata.colorSpace
        }
        // VFR: conformed rate wins when present (FR-MED-010 + FR-PROJ-003).
        let frameRate = metadata.conformedFrameRate ?? metadata.frameRate ?? current.frameRate
        return ProjectSettings(
            frameRate: frameRate,
            resolution: metadata.pixelDimensions ?? current.resolution,
            colorSpace: detectedColorSpace,
            audioSampleRate: detectedAudioSampleRate ?? current.audioSampleRate,
            preferProxyPlayback: current.preferProxyPlayback
        )
    }

    /// Whether a proposal differs enough from current settings to warrant a confirmation sheet.
    static func proposalDiffersFromCurrent(
        _ proposed: ProjectSettings,
        current: ProjectSettings
    ) -> Bool {
        proposed.resolution != current.resolution
            || proposed.frameRate != current.frameRate
            || proposed.colorSpace != current.colorSpace
            || proposed.audioSampleRate != current.audioSampleRate
    }
}
