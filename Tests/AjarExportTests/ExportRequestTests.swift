// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarExport

final class ExportRequestTests: XCTestCase {
    func testFREXP001RejectsRangeOutsideCapturedSequence() throws {
        let fixture = try RequestFixture()
        let outsideRange = try TimeRange(
            start: .zero,
            duration: RationalTime(value: 2, timescale: 1)
        )

        XCTAssertThrowsError(
            try fixture.request(range: outsideRange, settings: fixture.settings())
        ) { error in
            XCTAssertEqual(error as? ExportError, .invalidRange(outsideRange))
        }
    }

    func testFREXP002RejectsMismatchedGraphAndOutputColorTags() throws {
        let fixture = try RequestFixture()
        let settings = try fixture.settings(colorSpace: .displayP3)

        XCTAssertThrowsError(try fixture.request(settings: settings)) { error in
            XCTAssertEqual(
                error as? ExportError,
                .colorSpaceMismatch(project: .rec709, export: .displayP3)
            )
        }
    }

    func testFREXP002RejectsAudioRateDifferentFromOfflineMixer() throws {
        let fixture = try RequestFixture()
        let settings = try fixture.settings(audioSampleRate: 44_100)

        XCTAssertThrowsError(try fixture.request(settings: settings)) { error in
            XCTAssertEqual(
                error as? ExportError,
                .audioSampleRateMismatch(project: 48_000, export: 44_100)
            )
        }
    }
}

private struct RequestFixture {
    let project: Project
    let sequence: Sequence
    let range: TimeRange
    let destinationURL: URL

    init() throws {
        let frameRate = try FrameRate(frames: 30)
        range = try TimeRange(start: .zero, duration: RationalTime(value: 1, timescale: 1))
        sequence = Sequence(
            id: UUID(),
            name: "Request validation",
            videoTracks: [Track(id: UUID(), kind: .video, items: [.gap(range)])],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 64, height: 64),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [],
            sequences: [sequence]
        )
        destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "request-validation-\(UUID().uuidString).mp4"
        )
    }

    func request(
        range requestedRange: TimeRange? = nil,
        settings: ExportSettings
    ) throws -> ExportRequest {
        try ExportRequest(
            project: project,
            sequenceID: sequence.id,
            range: requestedRange ?? range,
            destinationURL: destinationURL,
            settings: settings
        )
    }

    func settings(
        colorSpace: ExportColorSpace = .rec709,
        audioSampleRate: Int? = nil
    ) throws -> ExportSettings {
        let audio = try audioSampleRate.map { sampleRate in
            try ExportAudioSettings(
                codec: .aac,
                sampleRate: sampleRate,
                channelCount: 2,
                bitRate: 64_000
            )
        }
        return try ExportSettings(
            container: .mp4,
            video: ExportVideoSettings(
                codec: .h264,
                resolution: PixelDimensions(width: 64, height: 64),
                frameRate: FrameRate(frames: 30),
                averageBitRate: 500_000,
                colorSpace: colorSpace
            ),
            audio: audio
        )
    }
}
