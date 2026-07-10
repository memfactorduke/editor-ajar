// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
import AVFoundation
import AjarCore
import Foundation
import Metal
import XCTest

@testable import AjarExport

// swiftlint:enable sorted_imports

/// FR-EXP-007: export twice, decode, hash **pixels** (not container bytes).
final class ExportDeterminismTests: XCTestCase {
    func testFREXP007ProResExportIsDeterministicOnDecodedPixels() async throws {
        try requireMetal()
        let fixture = try ExportGoldenFixture(frameCount: 12, includeAudio: true)
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let settings = try fixture.movieSettings(
            container: .mov,
            codec: .proRes422,
            audioCodec: .linearPCM
        )
        let firstURL = fixture.directoryURL.appendingPathComponent("a.mov")
        let secondURL = fixture.directoryURL.appendingPathComponent("b.mov")

        let first = try await fixture.exportMovie(to: firstURL, settings: settings)
        let second = try await fixture.exportMovie(to: secondURL, settings: settings)
        XCTAssertEqual(first.result.videoFrameCount, 12)
        XCTAssertEqual(second.result.videoFrameCount, 12)

        let firstFrames = try await ExportMovieDecoder.decodeBGRA8Frames(from: firstURL)
        let secondFrames = try await ExportMovieDecoder.decodeBGRA8Frames(from: secondURL)
        XCTAssertEqual(firstFrames.count, 12)
        XCTAssertEqual(
            ExportDecodedPixelHasher.hashFrames(firstFrames),
            ExportDecodedPixelHasher.hashFrames(secondFrames)
        )

        // Offline mixer is deterministic; decoded PCM hashes must match (WSOLA has its own tests).
        let firstAudio = try await ExportMovieDecoder.decodeInterleavedFloat32PCM(from: firstURL)
        let secondAudio = try await ExportMovieDecoder.decodeInterleavedFloat32PCM(from: secondURL)
        let audioA = try XCTUnwrap(firstAudio)
        let audioB = try XCTUnwrap(secondAudio)
        XCTAssertFalse(audioA.isEmpty)
        XCTAssertEqual(
            ExportDecodedPixelHasher.hashAudioPCM(audioA),
            ExportDecodedPixelHasher.hashAudioPCM(audioB)
        )

        XCTAssertEqual(first.session.sourceSelectionPolicy, .alwaysOriginal)
        XCTAssertFalse(first.session.sourceSelectionRecords.isEmpty)
        XCTAssertTrue(first.session.sourceSelectionRecords.allSatisfy { $0.tier == .original })
    }

    func testFREXP007H264ExportIsDeterministicWhenEncoderAvailable() async throws {
        try requireMetal()
        try await runLossyDeterminism(codec: .h264, container: .mp4, name: "H.264")
    }

    func testFREXP007HEVCExportIsDeterministicWhenEncoderAvailable() async throws {
        try requireMetal()
        try await runLossyDeterminism(codec: .hevc8Bit, container: .mp4, name: "HEVC")
    }

    func testFREXP007ProResDecodedFramesMatchRenderNearLosslessBand() async throws {
        try requireMetal()
        let fixture = try ExportGoldenFixture(frameCount: 12, includeAudio: false)
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let settings = try fixture.movieSettings(container: .mov, codec: .proRes422)
        let destinationURL = fixture.directoryURL.appendingPathComponent("roundtrip.mov")
        _ = try await fixture.exportMovie(to: destinationURL, settings: settings)

        let expected = try await fixture.renderExpectedBGRAFrames()
        let actual = try await ExportMovieDecoder.decodeBGRA8Frames(from: destinationURL)
        let comparison = ExportGoldenComparator.compareSequences(
            actual: actual,
            expected: expected,
            tolerance: .proRes422NearLossless
        )
        XCTAssertTrue(
            comparison.passed,
            "maxChΔ=\(comparison.maximumChannelDelta) mae=\(comparison.meanAbsoluteError) "
                + (comparison.diagnostic ?? "")
        )
    }

    private func runLossyDeterminism(
        codec: ExportVideoCodec,
        container: ExportContainer,
        name: String
    ) async throws {
        let fixture = try ExportGoldenFixture(frameCount: 12, includeAudio: false)
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let settings = try fixture.movieSettings(container: container, codec: codec)
        let firstURL = fixture.directoryURL.appendingPathComponent("a.\(container.rawValue)")
        let secondURL = fixture.directoryURL.appendingPathComponent("b.\(container.rawValue)")

        do {
            _ = try await fixture.exportMovie(to: firstURL, settings: settings)
            _ = try await fixture.exportMovie(to: secondURL, settings: settings)
        } catch let error as ExportError {
            guard error.isHardwareEncoderUnavailable(for: codec) else {
                throw error
            }
            throw XCTSkip("\(name) hardware encoder unavailable on this runner: \(error)")
        }

        let firstFrames = try await ExportMovieDecoder.decodeBGRA8Frames(from: firstURL)
        let secondFrames = try await ExportMovieDecoder.decodeBGRA8Frames(from: secondURL)
        XCTAssertEqual(
            ExportDecodedPixelHasher.hashFrames(firstFrames),
            ExportDecodedPixelHasher.hashFrames(secondFrames)
        )
    }

    private func requireMetal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on this runner")
        }
    }
}
