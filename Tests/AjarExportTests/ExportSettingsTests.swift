// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
import AVFoundation
import AjarAudio
import AjarCore
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import XCTest

@testable import AjarExport

// swiftlint:enable sorted_imports

final class ExportSettingsTests: XCTestCase {
    func testFREXP001AcceptsEveryRequiredVideoCodecAndBitDepth() throws {
        for codec in ExportVideoCodec.allCases {
            let settings = try ExportSettingsTestSupport.videoSettings(
                codec: codec,
                averageBitRate: codec.isProRes ? nil : 8_000_000
            )
            XCTAssertEqual(settings.codec, codec)
        }
    }

    func testFREXP001SettingsRoundTripCodable() throws {
        let original = try ExportSettings(
            container: .mp4,
            video: ExportSettingsTestSupport.videoSettings(
                codec: .hevc10Bit,
                averageBitRate: 12_000_000,
                colorSpace: .displayP3
            ),
            audio: ExportAudioSettings(
                codec: .aac,
                sampleRate: 48_000,
                channelCount: 2,
                bitRate: 192_000
            )
        )

        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self, from: data), original)
    }

    func testFREXP001ValidationRejectsInvalidResolutionBitRateAndQuality() throws {
        XCTAssertThrowsError(
            try ExportSettingsTestSupport.videoSettings(
                codec: .h264,
                width: 1,
                averageBitRate: 8_000_000
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportSettingsValidationError,
                .resolutionOutOfRange(PixelDimensions(width: 1, height: 1_080))
            )
        }
        XCTAssertThrowsError(
            try ExportSettingsTestSupport.videoSettings(
                codec: .h264,
                width: 1_919,
                averageBitRate: 8_000_000
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportSettingsValidationError,
                .resolutionMustBeEven(PixelDimensions(width: 1_919, height: 1_080))
            )
        }
        XCTAssertNoThrow(
            try ExportSettingsTestSupport.videoSettings(codec: .proRes422, width: 1_919)
        )
        XCTAssertThrowsError(
            try ExportSettingsTestSupport.videoSettings(codec: .h264, averageBitRate: 0)
        ) { error in
            XCTAssertEqual(
                error as? ExportSettingsValidationError,
                .videoBitRateOutOfRange(0)
            )
        }
        XCTAssertThrowsError(
            try ExportSettingsTestSupport.videoSettings(codec: .h264, quality: 1.01)
        ) { error in
            XCTAssertEqual(
                error as? ExportSettingsValidationError,
                .videoQualityOutOfRange(1.01)
            )
        }
        XCTAssertThrowsError(
            try ExportSettingsTestSupport.videoSettings(
                codec: .h264,
                averageBitRate: 8_000_000,
                quality: 0.8
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportSettingsValidationError,
                .rateControlsMutuallyExclusive
            )
        }
    }

    func testFREXP001ValidationRejectsUnsupportedRateControlsAndFrameRate() throws {
        XCTAssertThrowsError(
            try ExportSettingsTestSupport.videoSettings(
                codec: .proRes422,
                averageBitRate: 8_000_000
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportSettingsValidationError,
                .rateControlUnsupported(.proRes422)
            )
        }
        let frameRate = try FrameRate(frames: 241)
        XCTAssertThrowsError(
            try ExportVideoSettings(
                codec: .h264,
                resolution: PixelDimensions(width: 1_920, height: 1_080),
                frameRate: frameRate
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportSettingsValidationError,
                .frameRateOutOfRange(frameRate)
            )
        }
    }

    func testFREXP002ValidationRejectsIncompatibleContainerAndAudioPairs() throws {
        XCTAssertThrowsError(
            try ExportSettings(
                container: .mp4,
                video: ExportSettingsTestSupport.videoSettings(codec: .proRes422)
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportSettingsValidationError,
                .videoCodecUnsupportedInContainer(.proRes422, .mp4)
            )
        }
        XCTAssertThrowsError(
            try ExportSettings(
                container: .mp4,
                video: ExportSettingsTestSupport.videoSettings(codec: .h264),
                audio: ExportAudioSettings(
                    codec: .linearPCM,
                    sampleRate: 48_000,
                    channelCount: 2
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportSettingsValidationError,
                .audioCodecUnsupportedInContainer(.linearPCM, .mp4)
            )
        }
    }

    func testFREXP001InvalidDecodedSettingsAreRejected() throws {
        let settings = try ExportSettings(
            container: .mp4,
            video: ExportSettingsTestSupport.videoSettings(codec: .h264, averageBitRate: 8_000_000)
        )
        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var edited = object
        var video = try XCTUnwrap(edited["video"] as? [String: Any])
        video["averageBitRate"] = 0
        edited["video"] = video

        let invalidData = try JSONSerialization.data(withJSONObject: edited)
        XCTAssertThrowsError(try JSONDecoder().decode(ExportSettings.self, from: invalidData))
    }

    func testFREXP001HardwareAndMain10WriterSettingsAreExplicit() throws {
        let settings = try ExportSettingsTestSupport.videoSettings(
            codec: .hevc10Bit,
            quality: 0.75
        )
        let output = AssetWriterSettings.videoOutput(for: settings)
        let encoder = try XCTUnwrap(
            output[AVVideoEncoderSpecificationKey] as? [String: Bool]
        )
        XCTAssertEqual(
            encoder[
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String
            ],
            true
        )
        let compression = try XCTUnwrap(
            output[AVVideoCompressionPropertiesKey] as? [String: Any]
        )
        XCTAssertEqual(
            compression[kVTCompressionPropertyKey_Quality as String] as? Double,
            0.75
        )
        XCTAssertEqual(
            compression[AVVideoProfileLevelKey] as? String,
            kVTProfileLevel_HEVC_Main10_AutoLevel as String
        )
        XCTAssertEqual(
            AssetWriterSettings.pixelFormat(for: .hevc10Bit),
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
    }

    func testFREXP001WriterSettingsMapEveryRequiredCodec() throws {
        let expected: [(ExportVideoCodec, AVVideoCodecType)] = [
            (.h264, .h264),
            (.hevc8Bit, .hevc),
            (.hevc10Bit, .hevc),
            (.proRes422, .proRes422),
            (.proRes422HQ, .proRes422HQ),
            (.proRes4444, .proRes4444),
            (.proRes422Proxy, .proRes422Proxy)
        ]

        for (codec, expectedType) in expected {
            let settings = try ExportSettingsTestSupport.videoSettings(
                codec: codec,
                averageBitRate: codec.isProRes ? nil : 8_000_000
            )
            let output = AssetWriterSettings.videoOutput(for: settings)
            XCTAssertEqual(output[AVVideoCodecKey] as? AVVideoCodecType, expectedType)
            XCTAssertEqual(
                output[AVVideoEncoderSpecificationKey] != nil,
                codec.requiresHardwareEncoder
            )
        }
        XCTAssertEqual(
            AssetWriterSettings.pixelFormat(for: .proRes4444),
            kCVPixelFormatType_64ARGB
        )
        let alphaOutput = AssetWriterSettings.videoOutput(
            for: try ExportSettingsTestSupport.videoSettings(codec: .proRes4444)
        )
        XCTAssertNil(alphaOutput[AVVideoColorPropertiesKey])
        let alphaCompression = try XCTUnwrap(
            alphaOutput[AVVideoCompressionPropertiesKey] as? [String: Any]
        )
        XCTAssertEqual(
            alphaCompression[kVTCompressionPropertyKey_PreserveAlphaChannel as String] as? Bool,
            true
        )
        let alphaBufferAttributes = AssetWriterSettings.videoPixelBufferAttributes(
            for: try ExportSettingsTestSupport.videoSettings(codec: .proRes4444)
        )
        XCTAssertNil(alphaBufferAttributes[kCVPixelBufferMetalCompatibilityKey as String])
        XCTAssertNil(alphaBufferAttributes[kCVPixelBufferIOSurfacePropertiesKey as String])
    }

    func testFREXP002WriterSettingsMapAACAndFloatPCM() throws {
        let aac = try ExportAudioSettings(
            codec: .aac,
            sampleRate: 48_000,
            channelCount: 2,
            bitRate: 192_000
        )
        let pcm = try ExportAudioSettings(
            codec: .linearPCM,
            sampleRate: 48_000,
            channelCount: 2
        )

        XCTAssertEqual(
            AssetWriterSettings.audioOutput(for: aac)[AVFormatIDKey] as? UInt32,
            kAudioFormatMPEG4AAC
        )
        let pcmOutput = AssetWriterSettings.audioOutput(for: pcm)
        XCTAssertEqual(pcmOutput[AVFormatIDKey] as? UInt32, kAudioFormatLinearPCM)
        XCTAssertEqual(pcmOutput[AVLinearPCMIsFloatKey] as? Bool, true)
        XCTAssertEqual(pcmOutput[AVLinearPCMBitDepthKey] as? Int, 32)
    }

    func testFREXP002FloatPCMPackagingKeepsFrameCountAndTimestamp() throws {
        let rendered = try RenderedAudioBuffer(
            format: AudioRenderFormat(sampleRate: 48_000, channelCount: 2),
            frameCount: 4,
            samples: [0, 0, 0.1, -0.1, 0.2, -0.2, 0.3, -0.3]
        )
        let factory = try AudioSampleBufferFactory(sampleRate: 48_000, channelCount: 2)

        let sampleBuffer = try factory.makeSampleBuffer(
            from: rendered,
            frames: 2..<4,
            presentationFrameOffset: 48_000
        )

        XCTAssertEqual(CMSampleBufferGetNumSamples(sampleBuffer), 2)
        XCTAssertEqual(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            CMTime(value: 48_002, timescale: 48_000)
        )
    }
}
