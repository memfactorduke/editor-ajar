// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarExport

final class AnimatedGIFExportValidationTests: XCTestCase {
    func testFREXP006SettingsRejectRatesBelowOneAndOversizedRaster() throws {
        let halfFramePerSecond = try FrameRate(frames: 1, per: 2)
        XCTAssertThrowsError(
            try AnimatedGIFExportSettings(
                resolution: PixelDimensions(width: 16, height: 16),
                frameRate: halfFramePerSecond
            )
        ) { error in
            XCTAssertEqual(
                error as? AnimatedGIFExportSettingsValidationError,
                .frameRateOutOfRange(halfFramePerSecond)
            )
        }

        XCTAssertThrowsError(
            try AnimatedGIFExportSettings(
                resolution: PixelDimensions(width: 16_385, height: 16),
                frameRate: FrameRate(frames: 30)
            )
        ) { error in
            XCTAssertEqual(
                error as? AnimatedGIFExportSettingsValidationError,
                .resolutionOutOfRange(PixelDimensions(width: 16_385, height: 16))
            )
        }
    }

    func testFREXP006FrameRateBoundsUseExactRationalComparison() throws {
        let justUnderOne = try FrameRate(
            frames: 9_000_000_000_000_000_100,
            per: 9_000_000_000_000_000_101
        )
        let justOverOneHundred = try FrameRate(
            frames: 9_000_000_000_000_000_101,
            per: 90_000_000_000_000_001
        )

        for rate in [justUnderOne, justOverOneHundred] {
            XCTAssertThrowsError(
                try AnimatedGIFExportSettings(
                    resolution: PixelDimensions(width: 16, height: 16),
                    frameRate: rate
                )
            ) { error in
                XCTAssertEqual(
                    error as? AnimatedGIFExportSettingsValidationError,
                    .frameRateOutOfRange(rate)
                )
            }
        }
    }

    func testFREXP006SettingsRoundTripExplicitColorConversionPolicy() throws {
        let settings = try AnimatedGIFExportSettings(
            resolution: PixelDimensions(width: 31, height: 33),
            frameRate: FrameRate(frames: 24),
            sourceColorSpace: .displayP3,
            colorConversionPolicy: .convertToSRGB,
            loopPolicy: .playOnce
        )

        let decoded = try JSONDecoder().decode(
            AnimatedGIFExportSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.colorConversionPolicy, .convertToSRGB)
    }

    func testFREXP006RequestRejectsEmptyAndOutOfBoundsRanges() throws {
        let context = try AnimatedGIFValidationContext()
        let empty = try TimeRange(start: .zero, duration: .zero)
        XCTAssertThrowsError(try context.makeRequest(range: empty)) { error in
            XCTAssertEqual(error as? ExportError, .invalidRange(empty))
        }

        let outOfBounds = try TimeRange(
            start: context.sequenceDuration,
            duration: context.frameDuration
        )
        XCTAssertThrowsError(try context.makeRequest(range: outOfBounds)) { error in
            XCTAssertEqual(error as? ExportError, .invalidRange(outOfBounds))
        }
    }

    func testFREXP006RequestRejectsMismatchedColorAndRemoteDestination() throws {
        let context = try AnimatedGIFValidationContext()
        XCTAssertThrowsError(
            try context.makeRequest(sourceColorSpace: .displayP3)
        ) { error in
            XCTAssertEqual(
                error as? ExportError,
                .colorSpaceMismatch(project: .rec709, export: .displayP3)
            )
        }

        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/result.gif"))
        XCTAssertThrowsError(
            try context.makeRequest(destinationURL: remoteURL)
        ) { error in
            XCTAssertEqual(error as? ExportError, .destinationMustBeFileURL(remoteURL))
        }
    }

    func testFREXP006RequestAcceptsNativeSRGBProjectDelivery() throws {
        let context = try AnimatedGIFValidationContext(colorSpace: .sRGB)

        let request = try context.makeRequest(sourceColorSpace: .sRGB)

        XCTAssertEqual(request.project.settings.colorSpace, .sRGB)
        XCTAssertEqual(request.settings.sourceColorSpace, .sRGB)
    }

    func testFREXP006PartialFinalFrameRoundsCountUpAndClipsTotalDelay() throws {
        let context = try AnimatedGIFValidationContext()
        let partialDuration = try RationalTime(value: 1, timescale: 20)
        let request = try context.makeRequest(
            range: TimeRange(start: .zero, duration: partialDuration)
        )

        XCTAssertEqual(try request.frameCount(), 2)
        XCTAssertEqual(
            try (0..<2).map { try request.delayCentiseconds(forFrame: Int64($0)) },
            [3, 2]
        )
    }

    func testFREXP006ClippedFinalFrameKeepsPositiveCentisecondDelay() throws {
        let context = try AnimatedGIFValidationContext()
        let durationJustPastOneFrame = try RationalTime(value: 34, timescale: 1_000)
        let request = try context.makeRequest(
            range: TimeRange(start: .zero, duration: durationJustPastOneFrame)
        )

        XCTAssertEqual(try request.frameCount(), 2)
        XCTAssertEqual(
            try (0..<2).map { try request.delayCentiseconds(forFrame: Int64($0)) },
            [3, 1]
        )
    }
}

private struct AnimatedGIFValidationContext {
    let project: Project
    let sequence: Sequence
    let frameRate: FrameRate
    let frameDuration: RationalTime
    let sequenceDuration: RationalTime
    let destinationURL: URL

    init(colorSpace: MediaColorSpace = .rec709) throws {
        frameRate = try FrameRate(frames: 30)
        frameDuration = try frameRate.duration(ofFrames: 1)
        sequenceDuration = try frameRate.duration(ofFrames: 2)
        let sequenceRange = try TimeRange(start: .zero, duration: sequenceDuration)
        sequence = Sequence(
            id: UUID(),
            name: "GIF validation",
            videoTracks: [Track(id: UUID(), kind: .video, items: [.gap(sequenceRange)])],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 16, height: 16),
                colorSpace: colorSpace,
                audioSampleRate: 48_000
            ),
            mediaPool: [],
            sequences: [sequence]
        )
        destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-gif-validation-\(UUID().uuidString).gif"
        )
    }

    func makeRequest(
        range: TimeRange? = nil,
        destinationURL: URL? = nil,
        sourceColorSpace: ExportColorSpace = .rec709
    ) throws -> AnimatedGIFExportRequest {
        try AnimatedGIFExportRequest(
            project: project,
            sequenceID: sequence.id,
            range: range ?? TimeRange(start: .zero, duration: frameDuration),
            destinationURL: destinationURL ?? self.destinationURL,
            settings: AnimatedGIFExportSettings(
                resolution: PixelDimensions(width: 9, height: 7),
                frameRate: frameRate,
                sourceColorSpace: sourceColorSpace
            )
        )
    }
}
