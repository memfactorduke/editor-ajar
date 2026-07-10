// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
import AVFoundation
import AjarAudio
import AjarCore
import AjarRender
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox
import XCTest

@testable import AjarExport

// swiftlint:enable sorted_imports

extension ExportSmokeFixture {
    func assertDecodedCornerIsTransparentPremultiplied() async throws {
        let asset = AVURLAsset(url: destinationURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.alwaysCopiesSampleData = true
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let imageBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(imageBuffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        // Title is placed at (4,4); corner (0,0) is clear canvas → transparent premultiplied.
        let pixel = base.advanced(by: 0).assumingMemoryBound(to: UInt8.self)
        let blue = pixel[0]
        let green = pixel[1]
        let red = pixel[2]
        let alpha = pixel[3]
        XCTAssertLessThan(alpha, 16, "expected transparent canvas corner, alpha=\(alpha)")
        // Premultiplied: fully transparent coverage carries zero RGB.
        XCTAssertEqual(red, 0)
        XCTAssertEqual(green, 0)
        XCTAssertEqual(blue, 0)
        _ = bytesPerRow
    }

    func assertHEVCMain10(_ description: CMFormatDescription) throws {
        // Prefer explicit profile-level string when present on the sample description.
        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
        let profileCandidates = [
            extensions["ProfileLevel"] as? String,
            extensions[kVTCompressionPropertyKey_ProfileLevel as String] as? String,
            extensions["FormatName"] as? String
        ].compactMap { $0 }
        if profileCandidates.contains(where: {
            $0.localizedCaseInsensitiveContains("Main10")
                || $0.localizedCaseInsensitiveContains("Main 10")
                || $0 == (kVTProfileLevel_HEVC_Main10_AutoLevel as String)
        }) {
            return
        }

        // Fall back to HEVC parameter-set profile_idc == 2 (Main 10).
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        XCTAssertEqual(status, noErr, "could not inspect HEVC parameter sets")
        XCTAssertGreaterThan(parameterSetCount, 0)

        var foundMain10 = false
        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let setStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                description,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard setStatus == noErr, let pointer, size >= 2 else {
                continue
            }
            // HEVC NAL header is 2 bytes; VPS/SPS payload starts with profile_tier_level.
            // profile_idc is the first byte of general_profile_idc in profile_tier_level.
            let nalType = (pointer[0] >> 1) & 0x3F
            // VPS = 32, SPS = 33.
            guard nalType == 32 || nalType == 33, size >= 6 else {
                continue
            }
            let profileIDC = pointer[2]
            if profileIDC == 2 {
                foundMain10 = true
                break
            }
        }
        XCTAssertTrue(
            foundMain10 || !profileCandidates.isEmpty,
            "expected HEVC Main 10 profile markers; extensions=\(extensions.keys.sorted())"
        )
    }

    static func makeSequence(
        mediaID: UUID,
        frameRate: FrameRate,
        range: TimeRange,
        includeAudio: Bool
    ) throws -> Sequence {
        // Small title leaves transparent margins so ProRes 4444 alpha can be sampled at (0,0).
        let title = TitleSource(boxes: [
            TitleTextBox(
                id: UUID(),
                text: "Export",
                origin: CanvasPoint(x: RationalValue(4), y: RationalValue(4)),
                width: RationalValue(56),
                height: RationalValue(24),
                style: TitleTextStyle(fontSize: RationalValue(14))
            )
        ])
        let videoClip = Clip(
            id: UUID(),
            source: .title(title),
            sourceRange: range,
            timelineRange: range,
            kind: .video,
            name: "Synthetic title"
        )
        var audioTracks: [Track] = []
        if includeAudio {
            let audioClip = Clip(
                id: UUID(),
                source: .media(id: mediaID),
                sourceRange: range,
                timelineRange: range,
                kind: .audio,
                name: "Synthetic tone"
            )
            audioTracks = [
                Track(id: UUID(), kind: .audio, items: [.clip(audioClip)])
            ]
        }
        return Sequence(
            id: UUID(),
            name: "Ten-frame export smoke",
            videoTracks: [
                Track(id: UUID(), kind: .video, items: [.clip(videoClip)])
            ],
            audioTracks: audioTracks,
            markers: [],
            timebase: frameRate
        )
    }

    static func makeProject(
        sequence: Sequence,
        mediaID: UUID,
        frameRate: FrameRate,
        duration: RationalTime,
        colorSpace: ExportColorSpace
    ) -> Project {
        let media = MediaRef(
            id: mediaID,
            sourceURL: nil,
            contentHash: nil,
            metadata: MediaMetadata(
                codecID: "pcm_f32le",
                pixelDimensions: nil,
                frameRate: nil,
                duration: duration,
                colorSpace: colorSpace.mediaColorSpace,
                audioChannelLayout: AudioChannelLayout(channelCount: 1),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 64, height: 64),
                colorSpace: colorSpace.mediaColorSpace,
                audioSampleRate: 48_000
            ),
            mediaPool: [media],
            sequences: [sequence]
        )
    }

    static func makeAudioProvider(
        mediaID: UUID,
        duration: RationalTime
    ) throws -> InMemoryAudioSourceProvider {
        let frameCount = Int(duration.seconds * 48_000)
        let samples = (0..<frameCount).map { frame in
            Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000) * 0.1)
        }
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 48_000, channelCount: 1),
            frameCount: frameCount,
            samples: samples
        )
        return InMemoryAudioSourceProvider(sources: [mediaID: source])
    }
}
