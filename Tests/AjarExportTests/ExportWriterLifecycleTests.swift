// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import CoreMedia
import Foundation
import XCTest

@testable import AjarExport

final class ExportWriterLifecycleTests: XCTestCase {
    func testFREXP001StartAppendFinalizePublishesOnlyCompletedFile() async throws {
        let fixture = try LifecycleFixture(frameCount: 3)
        let frameProvider = LifecycleFrameProvider()
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        let session = fixture.session(frameProvider: frameProvider) { _, _ in writer }

        let result = try await session.run()

        XCTAssertEqual(session.state, .completed)
        XCTAssertEqual(result.videoFrameCount, 3)
        XCTAssertEqual(frameProvider.renderedFrameCount, 3)
        XCTAssertEqual(writer.appendedVideoCount, 3)
        XCTAssertTrue(writer.didStart)
        XCTAssertTrue(writer.didFinish)
        XCTAssertFalse(writer.didCancel)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), Data("complete".utf8))
        try fixture.assertNoPartialFiles()
    }

    func testFREXP005CancellationMidWriteLeavesNoPartialFile() async throws {
        let fixture = try LifecycleFixture(frameCount: 4)
        let frameProvider = LifecycleFrameProvider()
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        let sessionBox = WeakSessionBox()
        writer.onAppendVideo = {
            sessionBox.value?.cancel()
        }
        let created = fixture.session(frameProvider: frameProvider) { _, _ in writer }
        sessionBox.value = created

        do {
            _ = try await created.run()
            XCTFail("expected cancellation")
        } catch let error as ExportError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertEqual(created.state, .cancelled)
        XCTAssertEqual(writer.appendedVideoCount, 1)
        XCTAssertTrue(writer.didCancel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURL.path))
        try fixture.assertNoPartialFiles()
    }

    func testFREXP005CancellationDuringStartIsNotOverwrittenByWritingState() async throws {
        let fixture = try LifecycleFixture(frameCount: 2)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        let sessionBox = WeakSessionBox()
        writer.onStart = {
            sessionBox.value?.cancel()
        }
        let session = fixture.session(frameProvider: LifecycleFrameProvider()) { _, _ in writer }
        sessionBox.value = session

        do {
            _ = try await session.run()
            XCTFail("expected cancellation")
        } catch let error as ExportError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertEqual(session.state, .cancelled)
        XCTAssertEqual(writer.appendedVideoCount, 0)
        XCTAssertTrue(writer.didCancel)
        try fixture.assertNoPartialFiles()
    }

    func testFREXP005TaskCancellationInterruptsStalledFinalizeAndCleansUp() async throws {
        let fixture = try LifecycleFixture(frameCount: 1)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        let finishEntered = expectation(description: "writer entered finish")
        writer.suspendFinishUntilCancelled = true
        writer.onFinishEntered = {
            finishEntered.fulfill()
        }
        let session = fixture.session(frameProvider: LifecycleFrameProvider()) { _, _ in writer }

        let task = Task {
            try await session.run()
        }
        await fulfillment(of: [finishEntered], timeout: 2)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as ExportError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertEqual(session.state, .cancelled)
        XCTAssertTrue(writer.didCancel)
        try fixture.assertNoPartialFiles()
    }

    func testFREXP005CancellationBeforePublishPreservesExistingDestination() async throws {
        let fixture = try LifecycleFixture(frameCount: 1)
        try Data("original".utf8).write(to: fixture.destinationURL)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        let sessionBox = WeakSessionBox()
        let session = fixture.session(
            frameProvider: LifecycleFrameProvider(),
            beforePublish: {
                sessionBox.value?.cancel()
            },
            writerFactory: { _, _ in writer }
        )
        sessionBox.value = session

        do {
            _ = try await session.run()
            XCTFail("expected cancellation")
        } catch let error as ExportError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertTrue(writer.didFinish)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), Data("original".utf8))
        try fixture.assertNoPartialFiles()
    }

    func testNFRSTAB002DiskFullReturnsTypedErrorAndCleansUp() async throws {
        let fixture = try LifecycleFixture(frameCount: 2)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        writer.appendVideoError = .diskFull(
            fixture.directoryURL.appendingPathComponent("hidden.ajar-partial.mp4")
        )
        let session = fixture.session(frameProvider: LifecycleFrameProvider()) { _, _ in writer }

        do {
            _ = try await session.run()
            XCTFail("expected disk-full failure")
        } catch let error as ExportError {
            XCTAssertEqual(error, .diskFull(fixture.destinationURL))
        }

        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(writer.didCancel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURL.path))
        try fixture.assertNoPartialFiles()
    }

    func testNFRSTAB003EncoderRefusalReturnsTypedErrorAndCleansUp() async throws {
        let fixture = try LifecycleFixture(frameCount: 2)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        writer.startError = .encoderRefused(codec: .h264, reason: "hardware busy")
        let session = fixture.session(frameProvider: LifecycleFrameProvider()) { _, _ in writer }

        do {
            _ = try await session.run()
            XCTFail("expected encoder refusal")
        } catch let error as ExportError {
            XCTAssertEqual(
                error,
                .encoderRefused(codec: .h264, reason: "hardware busy")
            )
        }

        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(writer.didCancel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURL.path))
        try fixture.assertNoPartialFiles()
    }

    func testNFRSTAB002FailurePreservesExistingDestination() async throws {
        let fixture = try LifecycleFixture(frameCount: 2)
        try Data("original".utf8).write(to: fixture.destinationURL)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        writer.finishError = .writerFailed("mux failed")
        let session = fixture.session(frameProvider: LifecycleFrameProvider()) { _, _ in writer }

        do {
            _ = try await session.run()
            XCTFail("expected mux failure")
        } catch let error as ExportError {
            XCTAssertEqual(error, .writerFailed("mux failed"))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), Data("original".utf8))
        try fixture.assertNoPartialFiles()
    }

    func testNFRSTAB002SuccessfulFinalizeReplacesExistingDestination() async throws {
        let fixture = try LifecycleFixture(frameCount: 1)
        try Data("original".utf8).write(to: fixture.destinationURL)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        let session = fixture.session(frameProvider: LifecycleFrameProvider()) { _, _ in writer }

        _ = try await session.run()

        XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), Data("complete".utf8))
        try fixture.assertNoPartialFiles()
    }

    func testFREXP005SessionMayRunOnlyOnce() async throws {
        let fixture = try LifecycleFixture(frameCount: 1)
        let session = fixture.session(frameProvider: LifecycleFrameProvider()) { url, _ in
            LifecycleWriter(outputURL: url)
        }
        _ = try await session.run()

        do {
            _ = try await session.run()
            XCTFail("expected one-shot state rejection")
        } catch let error as ExportError {
            XCTAssertEqual(error, .invalidSessionState(.completed))
        }
    }

    func testFREXP002OfflineMixerSamplesAreAppendedInBoundedChunks() async throws {
        let fixture = try LifecycleFixture(frameCount: 3, includeAudio: true)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        writer.audioReady = true
        let session = fixture.session(
            frameProvider: LifecycleFrameProvider(),
            audioSourceProvider: InMemoryAudioSourceProvider(sources: [:])
        ) { _, _ in writer }

        let result = try await session.run()

        XCTAssertEqual(result.audioFrameCount, 4_800)
        XCTAssertEqual(writer.appendedAudioRanges, [0..<4_096, 4_096..<4_800])
    }

    func testFREXP001FinalizeUsesTheExactRequestedNonFrameAlignedEndTime() async throws {
        let frameRate = try FrameRate(frames: 30_000, per: 1_001)
        let duration = try RationalTime(value: 1, timescale: 10)
        let fixture = try LifecycleFixture(
            frameCount: 3,
            frameRate: frameRate,
            duration: duration
        )
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        let session = fixture.session(frameProvider: LifecycleFrameProvider()) { _, _ in writer }

        let result = try await session.run()

        XCTAssertEqual(result.duration, duration)
        XCTAssertEqual(result.videoFrameCount, 3)
        XCTAssertEqual(writer.finishedAt, CMTime(value: 1, timescale: 10))
    }
}
