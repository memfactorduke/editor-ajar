// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Typed validation failures for persisted and programmatic export settings.
public enum ExportSettingsValidationError:
    Error, Equatable, Sendable, CustomStringConvertible {
    /// Width and height must be positive and within the supported raster limit.
    case resolutionOutOfRange(PixelDimensions)

    /// Chroma-subsampled encoders require even frame dimensions.
    case resolutionMustBeEven(PixelDimensions)

    /// Export frame rate must be in the supported 1...240 fps interval.
    case frameRateOutOfRange(FrameRate)

    /// An average video bit rate was zero, negative, or unreasonably large.
    case videoBitRateOutOfRange(Int)

    /// Encoder quality must be finite and normalized to 0...1.
    case videoQualityOutOfRange(Double)

    /// ProRes uses its fixed profile rate control and rejects H.264/HEVC controls.
    case rateControlUnsupported(ExportVideoCodec)

    /// H.264/HEVC accept either average bit rate or quality, not both.
    case rateControlsMutuallyExclusive

    /// ProRes is supported only in a QuickTime movie container.
    case videoCodecUnsupportedInContainer(ExportVideoCodec, ExportContainer)

    /// Audio sample rate is outside the supported interval.
    case audioSampleRateOutOfRange(Int)

    /// Audio channel count is outside the supported interval.
    case audioChannelCountOutOfRange(Int)

    /// AAC requires a usable bit rate.
    case audioBitRateRequired

    /// AAC bit rate is outside the supported interval.
    case audioBitRateOutOfRange(Int)

    /// Linear PCM has no lossy encoder bit-rate control.
    case audioBitRateUnsupported(ExportAudioCodec)

    /// Linear PCM is not supported in the MP4 container.
    case audioCodecUnsupportedInContainer(ExportAudioCodec, ExportContainer)

    /// Human-readable validation failure.
    public var description: String {
        switch self {
        case .resolutionOutOfRange(let resolution):
            "export resolution \(resolution.width)x\(resolution.height) is outside 2...16384"
        case .resolutionMustBeEven(let resolution):
            "export resolution \(resolution.width)x\(resolution.height) must be even"
        case .frameRateOutOfRange(let frameRate):
            "export frame rate \(frameRate) is outside 1...240 fps"
        case .videoBitRateOutOfRange(let value):
            "video average bit rate \(value) is outside 1...1000000000"
        case .videoQualityOutOfRange(let value):
            "video encoder quality \(value) is outside 0...1"
        case .rateControlUnsupported(let codec):
            "\(codec.rawValue) uses fixed profile rate control"
        case .rateControlsMutuallyExclusive:
            "video average bit rate and quality are mutually exclusive"
        case .videoCodecUnsupportedInContainer(let codec, let container):
            "\(codec.rawValue) is not supported in \(container.rawValue)"
        case .audioSampleRateOutOfRange(let value):
            "audio sample rate \(value) is outside 8000...192000 Hz"
        case .audioChannelCountOutOfRange(let value):
            "audio channel count \(value) is outside the v1 mono/stereo range"
        case .audioBitRateRequired:
            "AAC export requires a bit rate"
        case .audioBitRateOutOfRange(let value):
            "AAC bit rate \(value) is outside 16000...512000"
        case .audioBitRateUnsupported(let codec):
            "\(codec.rawValue) does not accept an encoder bit rate"
        case .audioCodecUnsupportedInContainer(let codec, let container):
            "\(codec.rawValue) is not supported in \(container.rawValue)"
        }
    }
}

public extension ExportVideoSettings {
    /// Validates all video fields without consulting hardware availability.
    func validate() throws {
        let validDimensionRange = 2...16_384
        guard
            validDimensionRange.contains(resolution.width),
            validDimensionRange.contains(resolution.height)
        else {
            throw ExportSettingsValidationError.resolutionOutOfRange(resolution)
        }
        // 4:2:0 H.264/HEVC require even dimensions; ProRes RGB/YUV-422 accepts odd rasters.
        if codec.requiresEvenDimensions {
            guard resolution.width.isMultiple(of: 2), resolution.height.isMultiple(of: 2) else {
                throw ExportSettingsValidationError.resolutionMustBeEven(resolution)
            }
        }

        let framesPerSecond = Double(frameRate.frames) / Double(frameRate.seconds)
        guard framesPerSecond.isFinite, (1...240).contains(framesPerSecond) else {
            throw ExportSettingsValidationError.frameRateOutOfRange(frameRate)
        }

        if let averageBitRate, !(1...1_000_000_000).contains(averageBitRate) {
            throw ExportSettingsValidationError.videoBitRateOutOfRange(averageBitRate)
        }
        if let quality, !quality.isFinite || !(0...1).contains(quality) {
            throw ExportSettingsValidationError.videoQualityOutOfRange(quality)
        }
        if codec.isProRes, averageBitRate != nil || quality != nil {
            throw ExportSettingsValidationError.rateControlUnsupported(codec)
        }
        if !codec.isProRes, averageBitRate != nil, quality != nil {
            throw ExportSettingsValidationError.rateControlsMutuallyExclusive
        }
    }
}

public extension ExportAudioSettings {
    /// Validates all audio fields without consulting hardware availability.
    func validate() throws {
        guard (8_000...192_000).contains(sampleRate) else {
            throw ExportSettingsValidationError.audioSampleRateOutOfRange(sampleRate)
        }
        // V1 deliberately supports layouts that AVAssetWriter can describe unambiguously
        // without a caller-supplied channel-layout model.
        guard (1...2).contains(channelCount) else {
            throw ExportSettingsValidationError.audioChannelCountOutOfRange(channelCount)
        }

        switch codec {
        case .aac:
            guard let bitRate else {
                throw ExportSettingsValidationError.audioBitRateRequired
            }
            guard (16_000...512_000).contains(bitRate) else {
                throw ExportSettingsValidationError.audioBitRateOutOfRange(bitRate)
            }
        case .linearPCM:
            if bitRate != nil {
                throw ExportSettingsValidationError.audioBitRateUnsupported(codec)
            }
        }
    }
}

public extension ExportSettings {
    /// Validates codec/container compatibility and all nested fields.
    func validate() throws {
        try video.validate()
        try audio?.validate()

        if video.codec.isProRes, container != .mov {
            throw ExportSettingsValidationError.videoCodecUnsupportedInContainer(
                video.codec,
                container
            )
        }
        if audio?.codec == .linearPCM, container != .mov {
            throw ExportSettingsValidationError.audioCodecUnsupportedInContainer(
                .linearPCM,
                container
            )
        }
    }
}

extension ExportVideoCodec {
    var isProRes: Bool {
        switch self {
        case .h264, .hevc8Bit, .hevc10Bit:
            false
        case .proRes422, .proRes422HQ, .proRes4444, .proRes422Proxy:
            true
        }
    }

    var requiresHardwareEncoder: Bool {
        !isProRes
    }

    /// H.264 and HEVC encode 4:2:0 chroma and therefore need even frame dimensions.
    var requiresEvenDimensions: Bool {
        switch self {
        case .h264, .hevc8Bit, .hevc10Bit:
            true
        case .proRes422, .proRes422HQ, .proRes4444, .proRes422Proxy:
            false
        }
    }
}
