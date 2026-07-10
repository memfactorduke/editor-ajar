// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Named, Codable video-export preset (FR-EXP-003).
///
/// ## Persistence policy
/// Built-in presets are constants compiled into `AjarExport`. **Custom presets are app-side
/// only** — they live in Application Support JSON (atomic write) and are **never** written into
/// project packages (`project.json` / `schemaMinor`). That keeps shared projects portable and
/// avoids coupling user delivery preferences to the edit document (ADR-0018 / ADR-0019).
///
/// Resolving a preset always runs through `ExportSettings` validation so invalid combinations
/// cannot reach the writer.
public struct ExportPreset: Codable, Equatable, Sendable, Identifiable {
    /// Stable identity for picker selection and custom-preset bookkeeping.
    public let id: UUID

    /// Human-readable display name.
    public let name: String

    /// Whether this preset ships with the product (not user-editable as a built-in).
    public let isBuiltIn: Bool

    /// Output container.
    public let container: ExportContainer

    /// Video codec / profile.
    public let videoCodec: ExportVideoCodec

    /// Encoded raster size.
    public let resolution: PixelDimensions

    /// Export frame rate.
    public let frameRate: FrameRate

    /// Optional average video bit rate (H.264/HEVC).
    public let averageBitRate: Int?

    /// Optional normalized encoder quality (H.264/HEVC).
    public let quality: Double?

    /// Delivery color space.
    public let colorSpace: ExportColorSpace

    /// Optional mixed audio track settings.
    public let audio: ExportAudioSettings?

    /// Creates a preset; does not validate until `makeSettings()` / `validate()`.
    public init(
        id: UUID = UUID(),
        name: String,
        isBuiltIn: Bool = false,
        container: ExportContainer,
        videoCodec: ExportVideoCodec,
        resolution: PixelDimensions,
        frameRate: FrameRate,
        averageBitRate: Int? = nil,
        quality: Double? = nil,
        colorSpace: ExportColorSpace = .rec709,
        audio: ExportAudioSettings? = nil
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.container = container
        self.videoCodec = videoCodec
        self.resolution = resolution
        self.frameRate = frameRate
        self.averageBitRate = averageBitRate
        self.quality = quality
        self.colorSpace = colorSpace
        self.audio = audio
    }

    /// Validates by constructing nested export settings (FR-EXP-003).
    public func validate() throws {
        _ = try makeSettings()
    }

    /// Materializes validated `ExportSettings` for `ExportSession`.
    public func makeSettings() throws -> ExportSettings {
        do {
            let video = try ExportVideoSettings(
                codec: videoCodec,
                resolution: resolution,
                frameRate: frameRate,
                averageBitRate: averageBitRate,
                quality: quality,
                colorSpace: colorSpace
            )
            return try ExportSettings(
                container: container,
                video: video,
                audio: audio
            )
        } catch let error as ExportSettingsValidationError {
            throw ExportError.invalidSettings(error)
        }
    }
}

/// Built-in delivery presets (FR-EXP-003).
public enum ExportBuiltInPresets {
    /// Stable UUIDs so app pickers and tests can refer to built-ins by identity.
    public static let youTube1080pID = Self.stableID(1)
    public static let youTube4KID = Self.stableID(2)
    public static let square1080ID = Self.stableID(3)
    public static let vertical916ID = Self.stableID(4)
    /// ProRes 422 mezzanine / archive delivery (display name: "ProRes 422 Master").
    public static let proRes422MezzanineID = Self.stableID(5)

    /// All built-in presets in picker order.
    ///
    /// Construction uses only compile-time-valid numeric rates; failure is treated as empty so
    /// callers still get a typed array without trapping in library load.
    public static var all: [ExportPreset] {
        [
            youTube1080p,
            youTube4K,
            square1080,
            vertical916,
            proRes422Mezzanine
        ].compactMap { $0 }
    }

    /// YouTube-oriented 1080p H.264 / AAC in MP4.
    public static var youTube1080p: ExportPreset? {
        makeBuiltIn(BuiltInSpec(
            id: youTube1080pID,
            name: "YouTube 1080p",
            container: .mp4,
            videoCodec: .h264,
            resolution: PixelDimensions(width: 1_920, height: 1_080),
            averageBitRate: 12_000_000,
            audio: .aac(bitRate: 192_000)
        ))
    }

    /// YouTube-oriented 4K H.264 / AAC in MP4.
    public static var youTube4K: ExportPreset? {
        makeBuiltIn(BuiltInSpec(
            id: youTube4KID,
            name: "YouTube 4K",
            container: .mp4,
            videoCodec: .h264,
            resolution: PixelDimensions(width: 3_840, height: 2_160),
            averageBitRate: 45_000_000,
            audio: .aac(bitRate: 192_000)
        ))
    }

    /// Square 1080×1080 social crop.
    public static var square1080: ExportPreset? {
        makeBuiltIn(BuiltInSpec(
            id: square1080ID,
            name: "Square 1080",
            container: .mp4,
            videoCodec: .h264,
            resolution: PixelDimensions(width: 1_080, height: 1_080),
            averageBitRate: 10_000_000,
            audio: .aac(bitRate: 192_000)
        ))
    }

    /// Vertical 9:16 1080×1920.
    public static var vertical916: ExportPreset? {
        makeBuiltIn(BuiltInSpec(
            id: vertical916ID,
            name: "Vertical 9:16",
            container: .mp4,
            videoCodec: .h264,
            resolution: PixelDimensions(width: 1_080, height: 1_920),
            averageBitRate: 12_000_000,
            audio: .aac(bitRate: 192_000)
        ))
    }

    /// ProRes 422 mezzanine (MOV + Float32 PCM). Display name keeps industry "Master" wording.
    public static var proRes422Mezzanine: ExportPreset? {
        makeBuiltIn(BuiltInSpec(
            id: proRes422MezzanineID,
            name: "ProRes 422 Master",
            container: .mov,
            videoCodec: .proRes422,
            resolution: PixelDimensions(width: 1_920, height: 1_080),
            averageBitRate: nil,
            audio: .linearPCM
        ))
    }

    private enum BuiltInAudio {
        case aac(bitRate: Int)
        case linearPCM
    }

    private struct BuiltInSpec {
        let id: UUID
        let name: String
        let container: ExportContainer
        let videoCodec: ExportVideoCodec
        let resolution: PixelDimensions
        let averageBitRate: Int?
        let audio: BuiltInAudio
    }

    private static func stableID(_ index: UInt8) -> UUID {
        UUID(uuid: (
            0xA1, 0x00, 0x00, 0x01,
            0x00, 0x00,
            0x40, 0x00,
            0x80, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, index
        ))
    }

    private static func makeBuiltIn(_ spec: BuiltInSpec) -> ExportPreset? {
        guard let frameRate = try? FrameRate(frames: 30) else {
            return nil
        }
        guard let audio = try? audioSettings(for: spec.audio) else {
            return nil
        }
        let preset = ExportPreset(
            id: spec.id,
            name: spec.name,
            isBuiltIn: true,
            container: spec.container,
            videoCodec: spec.videoCodec,
            resolution: spec.resolution,
            frameRate: frameRate,
            averageBitRate: spec.averageBitRate,
            quality: nil,
            colorSpace: .rec709,
            audio: audio
        )
        // Reject any built-in that would not pass ExportSettings validation.
        guard (try? preset.validate()) != nil else {
            return nil
        }
        return preset
    }

    private static func audioSettings(for audio: BuiltInAudio) throws -> ExportAudioSettings {
        switch audio {
        case .aac(let bitRate):
            return try ExportAudioSettings(
                codec: .aac,
                sampleRate: 48_000,
                channelCount: 2,
                bitRate: bitRate
            )
        case .linearPCM:
            return try ExportAudioSettings(
                codec: .linearPCM,
                sampleRate: 48_000,
                channelCount: 2
            )
        }
    }
}
