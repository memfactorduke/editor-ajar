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

final class ExportSmokeFixture {
    let directoryURL: URL
    let destinationURL: URL
    let project: Project
    let sequence: Sequence
    let range: TimeRange
    let settings: ExportSettings
    let audioProvider: InMemoryAudioSourceProvider?
    private let expectedFrameCount = Int64(10)
    private let colorSpace: ExportColorSpace

    init(
        container: ExportContainer,
        codec: ExportVideoCodec,
        audioCodec: ExportAudioCodec,
        colorSpace: ExportColorSpace,
        includeAudio: Bool = true
    ) throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on this runner")
        }
        self.colorSpace = colorSpace
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-export-smoke-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        destinationURL = directoryURL.appendingPathComponent("smoke.\(container.rawValue)")

        let frameRate = try FrameRate(frames: 30)
        let duration = try frameRate.duration(ofFrames: expectedFrameCount)
        range = try TimeRange(start: .zero, duration: duration)
        let mediaID = UUID()
        sequence = try Self.makeSequence(
            mediaID: mediaID,
            frameRate: frameRate,
            range: range,
            includeAudio: includeAudio
        )
        project = Self.makeProject(
            sequence: sequence,
            mediaID: mediaID,
            frameRate: frameRate,
            duration: duration,
            colorSpace: colorSpace
        )
        if includeAudio {
            audioProvider = try Self.makeAudioProvider(mediaID: mediaID, duration: duration)
        } else {
            audioProvider = nil
        }
        let audioSettings: ExportAudioSettings? =
            includeAudio
            ? try ExportAudioSettings(
                codec: audioCodec,
                sampleRate: 48_000,
                channelCount: 2,
                bitRate: audioCodec == .aac ? 64_000 : nil
            )
            : nil
        // H.264/HEVC: bit rate XOR quality (L6). Prefer quality for smoke variety on Main10.
        let averageBitRate: Int? = codec.isProRes ? nil : (codec == .hevc10Bit ? nil : 500_000)
        let quality: Double? = codec.isProRes ? nil : (codec == .hevc10Bit ? 0.75 : nil)
        settings = try ExportSettings(
            container: container,
            video: ExportVideoSettings(
                codec: codec,
                resolution: PixelDimensions(width: 64, height: 64),
                frameRate: frameRate,
                averageBitRate: averageBitRate,
                quality: quality,
                colorSpace: colorSpace
            ),
            audio: audioSettings
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func run() async throws {
        let request = try ExportRequest(
            project: project,
            sequenceID: sequence.id,
            range: range,
            destinationURL: destinationURL,
            settings: settings
        )
        let frameProvider = try RenderGraphExportFrameProvider(
            project: project,
            sequence: sequence,
            videoSettings: settings.video,
            sourceProvider: SourceLessExportProvider()
        )
        let session = ExportSession(
            request: request,
            frameProvider: frameProvider,
            audioSourceProvider: audioProvider
        )

        let result = try await session.run()
        XCTAssertEqual(result.videoFrameCount, expectedFrameCount)
        if audioProvider != nil {
            XCTAssertEqual(result.audioFrameCount, 16_000)
        } else {
            XCTAssertEqual(result.audioFrameCount, 0)
        }
        XCTAssertEqual(session.state, .completed)
    }

    func assertAsset(
        expectedVideoSubtype: FourCharCode,
        expectedPrimaries: String,
        requireHEVCMain10: Bool = false,
        requireAlphaChannel: Bool = false
    ) async throws {
        let asset = AVURLAsset(url: destinationURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        if audioProvider != nil {
            XCTAssertEqual(audioTracks.count, 1)
        } else {
            XCTAssertEqual(audioTracks.count, 0)
        }

        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, range.duration.seconds, accuracy: 1.0 / 600.0)
        let track = try XCTUnwrap(videoTracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), expectedVideoSubtype)
        let primaries = CMFormatDescriptionGetExtension(
            description,
            extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
        )
        XCTAssertEqual(primaries as? String, expectedPrimaries)

        if requireHEVCMain10 {
            try assertHEVCMain10(description)
        }
        if requireAlphaChannel {
            let containsAlpha = CMFormatDescriptionGetExtension(
                description,
                extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel
            ) as? Bool
            // Some OS versions only advertise alpha via sample description; decoded pixels are
            // the hard requirement (assertDecodedCornerIsTransparentPremultiplied).
            if let containsAlpha {
                XCTAssertTrue(containsAlpha)
            }
        }
    }
}
