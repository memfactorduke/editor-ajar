// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@testable import AjarExport

final class ExportRangeTests: XCTestCase {
    func testFREXP004WholeTimelineResolvesToSequenceDuration() throws {
        let fixture = try RangeFixture(frameCount: 90)
        let range = try ExportRangeResolver.resolve(.wholeTimeline, sequence: fixture.sequence)
        XCTAssertEqual(range.start, .zero)
        XCTAssertEqual(range.duration, try fixture.frameRate.duration(ofFrames: 90))
    }

    func testFREXP004InOutMarksResolveHalfOpenRange() throws {
        let fixture = try RangeFixture(frameCount: 90)
        let inPoint = try RationalTime.atFrame(10, frameRate: fixture.frameRate)
        let outPoint = try RationalTime.atFrame(40, frameRate: fixture.frameRate)
        let range = try ExportRangeResolver.resolve(
            .inOut(inPoint: inPoint, outPoint: outPoint),
            sequence: fixture.sequence
        )
        XCTAssertEqual(range.start, inPoint)
        XCTAssertEqual(range.duration, try outPoint.subtracting(inPoint))
    }

    func testFREXP004EmptyOrInvertedInOutIsTypedError() throws {
        let fixture = try RangeFixture(frameCount: 90)
        let a = try RationalTime.atFrame(20, frameRate: fixture.frameRate)
        let b = try RationalTime.atFrame(10, frameRate: fixture.frameRate)

        XCTAssertThrowsError(
            try ExportRangeResolver.resolve(
                .inOut(inPoint: a, outPoint: a),
                sequence: fixture.sequence
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportError,
                .emptyOrInvertedRange(start: a, end: a)
            )
        }

        XCTAssertThrowsError(
            try ExportRangeResolver.resolve(
                .inOut(inPoint: a, outPoint: b),
                sequence: fixture.sequence
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportError,
                .emptyOrInvertedRange(start: a, end: b)
            )
        }
    }

    func testFREXP004EmptyTimelineIsTypedError() throws {
        let frameRate = try FrameRate(frames: 30)
        let sequence = Sequence(
            id: UUID(),
            name: "Empty",
            videoTracks: [],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        XCTAssertThrowsError(
            try ExportRangeResolver.resolve(.wholeTimeline, sequence: sequence)
        ) { error in
            XCTAssertEqual(
                error as? ExportError,
                .emptyOrInvertedRange(start: .zero, end: .zero)
            )
        }
    }

    func testFREXP004FramePullHonorsRangeFirstAndLastBoundaries() async throws {
        let fixture = try LifecycleFixture(frameCount: 30)
        // Re-request with a partial range: frames [5, 15) at 30fps → 10 frames.
        let frameRate = try FrameRate(frames: 30)
        let start = try RationalTime.atFrame(5, frameRate: frameRate)
        let duration = try frameRate.duration(ofFrames: 10)
        let partialRange = try TimeRange(start: start, duration: duration)

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-export-range-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let destinationURL = directoryURL.appendingPathComponent("partial.mp4")

        let sequence = fixture.request.sequence
        let project = fixture.request.project
        // Build a request whose sequence covers at least the partial range.
        let fullDuration = try frameRate.duration(ofFrames: 30)
        let fullRange = try TimeRange(start: .zero, duration: fullDuration)
        let fullSequence = Sequence(
            id: sequence.id,
            name: sequence.name,
            videoTracks: [Track(id: UUID(), kind: .video, items: [.gap(fullRange)])],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        let fullProject = Project(
            schemaVersion: project.schemaVersion,
            settings: project.settings,
            mediaPool: [],
            sequences: [fullSequence]
        )
        let request = try ExportRequest(
            project: fullProject,
            sequenceID: fullSequence.id,
            range: partialRange,
            destinationURL: destinationURL,
            settings: fixture.request.settings
        )

        let recorder = RecordingFrameProvider()
        let writer = LifecycleWriter(outputURL: destinationURL)
        let session = ExportSession(
            request: request,
            frameProvider: recorder,
            writerFactory: { temporaryURL, _ in
                writer.outputURL = temporaryURL
                return writer
            }
        )

        let result = try await session.run()
        XCTAssertEqual(result.videoFrameCount, 10)
        XCTAssertEqual(recorder.times.count, 10)

        let first = try XCTUnwrap(recorder.times.first)
        let last = try XCTUnwrap(recorder.times.last)
        XCTAssertEqual(first, start)
        // Last frame index 9 → start + 9 frames.
        let expectedLast = try start.adding(frameRate.duration(ofFrames: 9))
        XCTAssertEqual(last, expectedLast)
        // Exclusive end is not sampled.
        let exclusiveEnd = try start.adding(duration)
        XCTAssertTrue(last < exclusiveEnd)
    }
}

private final class RecordingFrameProvider: ExportVideoFrameProvider {
    private(set) var times: [RationalTime] = []

    func renderFrame(at timelineTime: RationalTime, into _: CVPixelBuffer) async throws {
        times.append(timelineTime)
    }
}

private struct RangeFixture {
    let frameRate: FrameRate
    let sequence: Sequence

    init(frameCount: Int64) throws {
        frameRate = try FrameRate(frames: 30)
        let duration = try frameRate.duration(ofFrames: frameCount)
        let range = try TimeRange(start: .zero, duration: duration)
        sequence = Sequence(
            id: UUID(),
            name: "Range",
            videoTracks: [Track(id: UUID(), kind: .video, items: [.gap(range)])],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
    }
}
