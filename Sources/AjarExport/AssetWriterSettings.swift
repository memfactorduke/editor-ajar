// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

enum AssetWriterSettings {
    static func videoOutput(for settings: ExportVideoSettings) -> [String: Any] {
        var output: [String: Any] = [
            AVVideoCodecKey: codecType(for: settings.codec),
            AVVideoWidthKey: settings.resolution.width,
            AVVideoHeightKey: settings.resolution.height
        ]
        // AVAssetWriter's high-bit-depth ProRes contract forbids color properties here.
        // Those codecs receive the same tags as propagating CVPixelBuffer attachments instead.
        if !settings.codec.isProRes {
            output[AVVideoColorPropertiesKey] = ExportColorTagging.videoProperties(
                for: settings.colorSpace
            )
            if settings.colorSpace == .displayP3 {
                output[AVVideoAllowWideColorKey] = true
            }
        }
        if settings.codec.requiresHardwareEncoder {
            output[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String:
                    true
            ]
        }
        if let compression = compressionProperties(for: settings), !compression.isEmpty {
            output[AVVideoCompressionPropertiesKey] = compression
        }
        return output
    }

    static func videoPixelBufferAttributes(
        for settings: ExportVideoSettings
    ) -> [String: Any] {
        var attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat(for: settings.codec),
            kCVPixelBufferWidthKey as String: settings.resolution.width,
            kCVPixelBufferHeightKey as String: settings.resolution.height
        ]
        // Apple's documented high-bit-depth RGB ProRes input (64ARGB) is ordinary-memory backed;
        // it is not an IOSurface/Metal pixel-buffer format. Delivery conversion is CPU-side
        // vImage into this pool (ADR-0019) — Metal compatibility is only requested for 8-bit paths.
        // ProRes 422 Proxy also takes 32BGRA, but its writer pool is ordinary-memory (no Metal /
        // IOSurface keys) — matching the high-bit-depth ProRes path avoids pool creation failures.
        if !settings.codec.isProRes {
            attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
            attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        }
        return attributes
    }

    static func audioOutput(for settings: ExportAudioSettings) -> [String: Any] {
        switch settings.codec {
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: settings.sampleRate,
                AVNumberOfChannelsKey: settings.channelCount,
                AVEncoderBitRateKey: settings.bitRate ?? 192_000
            ]
        case .linearPCM:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: settings.sampleRate,
                AVNumberOfChannelsKey: settings.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }

    static func fileType(for container: ExportContainer) -> AVFileType {
        switch container {
        case .mp4:
            .mp4
        case .mov:
            .mov
        }
    }

    static func pixelFormat(for codec: ExportVideoCodec) -> OSType {
        switch codec {
        case .h264, .hevc8Bit:
            kCVPixelFormatType_32BGRA
        case .hevc10Bit:
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .proRes422, .proRes422HQ, .proRes4444, .proRes422Proxy:
            // ProRes Proxy accepts several inputs; use the same documented 64ARGB path as other
            // ProRes profiles so the shared writer pool / delivery packing stay consistent.
            kCVPixelFormatType_64ARGB
        }
    }

    private static func codecType(for codec: ExportVideoCodec) -> AVVideoCodecType {
        switch codec {
        case .h264:
            .h264
        case .hevc8Bit, .hevc10Bit:
            .hevc
        case .proRes422:
            .proRes422
        case .proRes422HQ:
            .proRes422HQ
        case .proRes4444:
            .proRes4444
        case .proRes422Proxy:
            .proRes422Proxy
        }
    }

    private static func compressionProperties(
        for settings: ExportVideoSettings
    ) -> [String: Any]? {
        if settings.codec == .proRes4444 {
            return [
                kVTCompressionPropertyKey_PreserveAlphaChannel as String: true
            ]
        }
        guard !settings.codec.isProRes else {
            return nil
        }
        var properties: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey:
                Double(settings.frameRate.frames) / Double(settings.frameRate.seconds)
        ]
        if let averageBitRate = settings.averageBitRate {
            properties[AVVideoAverageBitRateKey] = averageBitRate
        }
        if let quality = settings.quality {
            properties[kVTCompressionPropertyKey_Quality as String] = quality
        }
        switch settings.codec {
        case .h264:
            properties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc8Bit:
            properties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel
        case .hevc10Bit:
            properties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
        case .proRes422, .proRes422HQ, .proRes4444, .proRes422Proxy:
            break
        }
        return properties
    }
}
