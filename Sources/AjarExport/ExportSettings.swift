// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// File containers supported by the v1 export engine (FR-EXP-002).
public enum ExportContainer: String, Codable, CaseIterable, Equatable, Sendable {
    /// ISO base media file with an MPEG-4 extension.
    case mp4

    /// QuickTime movie file.
    case mov
}

/// Video codecs supported by the v1 export engine (FR-EXP-001).
public enum ExportVideoCodec: String, Codable, CaseIterable, Equatable, Sendable {
    /// Hardware-encoded H.264/AVC.
    case h264

    /// Hardware-encoded 8-bit HEVC Main profile.
    case hevc8Bit

    /// Hardware-encoded 10-bit HEVC Main 10 profile.
    case hevc10Bit

    /// Apple ProRes 422.
    case proRes422

    /// Apple ProRes 422 HQ.
    case proRes422HQ

    /// Apple ProRes 4444, preserving alpha.
    case proRes4444

    /// Apple ProRes 422 Proxy — optimized media / proxy generation (FR-MED-004).
    case proRes422Proxy
}

/// Audio codecs supported by the v1 export engine (FR-EXP-002).
public enum ExportAudioCodec: String, Codable, CaseIterable, Equatable, Sendable {
    /// MPEG-4 AAC-LC.
    case aac

    /// Interleaved 32-bit floating-point linear PCM.
    case linearPCM
}

/// Tagged SDR delivery spaces supported by v1 export (ADR-0010).
public enum ExportColorSpace: String, Codable, CaseIterable, Equatable, Sendable {
    /// ITU-R BT.709 primaries and transfer function.
    case rec709

    /// Display-P3 D65 primaries with the sRGB transfer function.
    case displayP3

    /// Matching render-graph color-space token.
    public var mediaColorSpace: MediaColorSpace {
        switch self {
        case .rec709:
            .rec709
        case .displayP3:
            .displayP3
        }
    }
}

/// Typed video settings for one export (FR-EXP-001/002).
public struct ExportVideoSettings: Codable, Equatable, Sendable {
    /// Output codec and bit depth/profile.
    public let codec: ExportVideoCodec

    /// Encoded frame dimensions.
    public let resolution: PixelDimensions

    /// Deterministic frame-pull rate.
    public let frameRate: FrameRate

    /// Optional average bit rate for H.264/HEVC, in bits per second.
    public let averageBitRate: Int?

    /// Optional normalized encoder quality for H.264/HEVC.
    public let quality: Double?

    /// Delivery-space conversion and output tag.
    public let colorSpace: ExportColorSpace

    /// Creates validated video settings.
    public init(
        codec: ExportVideoCodec,
        resolution: PixelDimensions,
        frameRate: FrameRate,
        averageBitRate: Int? = nil,
        quality: Double? = nil,
        colorSpace: ExportColorSpace = .rec709
    ) throws {
        self.codec = codec
        self.resolution = resolution
        self.frameRate = frameRate
        self.averageBitRate = averageBitRate
        self.quality = quality
        self.colorSpace = colorSpace
        try validate()
    }

    /// Decodes and validates untrusted persisted settings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            codec: container.decode(ExportVideoCodec.self, forKey: .codec),
            resolution: container.decode(PixelDimensions.self, forKey: .resolution),
            frameRate: container.decode(FrameRate.self, forKey: .frameRate),
            averageBitRate: container.decodeIfPresent(Int.self, forKey: .averageBitRate),
            quality: container.decodeIfPresent(Double.self, forKey: .quality),
            colorSpace: container.decode(ExportColorSpace.self, forKey: .colorSpace)
        )
    }
}

/// Typed audio settings for one export (FR-EXP-002).
public struct ExportAudioSettings: Codable, Equatable, Sendable {
    /// Output codec.
    public let codec: ExportAudioCodec

    /// Output sample rate in hertz.
    public let sampleRate: Int

    /// Interleaved output channel count.
    public let channelCount: Int

    /// AAC bit rate in bits per second; absent for linear PCM.
    public let bitRate: Int?

    /// Creates validated audio settings.
    public init(
        codec: ExportAudioCodec,
        sampleRate: Int,
        channelCount: Int,
        bitRate: Int? = nil
    ) throws {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitRate = bitRate
        try validate()
    }

    /// Decodes and validates untrusted persisted settings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            codec: container.decode(ExportAudioCodec.self, forKey: .codec),
            sampleRate: container.decode(Int.self, forKey: .sampleRate),
            channelCount: container.decode(Int.self, forKey: .channelCount),
            bitRate: container.decodeIfPresent(Int.self, forKey: .bitRate)
        )
    }
}

/// Complete, Codable settings for one video export.
public struct ExportSettings: Codable, Equatable, Sendable {
    /// Output file container.
    public let container: ExportContainer

    /// Required video settings.
    public let video: ExportVideoSettings

    /// Optional mixed audio track.
    public let audio: ExportAudioSettings?

    /// Creates and cross-validates export settings.
    public init(
        container: ExportContainer,
        video: ExportVideoSettings,
        audio: ExportAudioSettings? = nil
    ) throws {
        self.container = container
        self.video = video
        self.audio = audio
        try validate()
    }

    /// Decodes and validates untrusted persisted settings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            container: container.decode(ExportContainer.self, forKey: .container),
            video: container.decode(ExportVideoSettings.self, forKey: .video),
            audio: container.decodeIfPresent(ExportAudioSettings.self, forKey: .audio)
        )
    }
}
