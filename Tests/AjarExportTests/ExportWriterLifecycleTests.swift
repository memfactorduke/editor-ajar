// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import CoreMedia
import Foundation
import XCTest

@testable import AjarExport

// swiftlint:disable:next type_body_length
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

    func testNFRSTAB002VacantPolicyRefusesFileThatAppearsBeforePublication() async throws {
        let fixture = try LifecycleFixture(
            frameCount: 1,
            destinationCollisionPolicy: .requireVacant
        )
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        let intruder = Data("appeared-after-selection".utf8)
        let session = fixture.session(
            frameProvider: LifecycleFrameProvider(),
            beforePublish: {
                try? intruder.write(to: fixture.destinationURL)
            },
            writerFactory: { _, _ in writer }
        )

        do {
            _ = try await session.run()
            XCTFail("an unconfirmed late destination must not be replaced")
        } catch let error as ExportError {
            XCTAssertEqual(
                error,
                .destinationRequiresOverwriteConfirmation(fixture.destinationURL)
            )
        }

        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), intruder)
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

    func testFREXP002AsyncAudioProviderFactoryIsAwaitedBeforeWriting() async throws {
        let fixture = try LifecycleFixture(frameCount: 3, includeAudio: true)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        writer.audioReady = true
        let probe = AudioProviderFactoryProbe()
        let session = fixture.session(
            frameProvider: LifecycleFrameProvider(),
            audioSourceProviderFactory: { _ in
                await probe.recordInvocation()
                return InMemoryAudioSourceProvider(sources: [:])
            },
            writerFactory: { _, _ in writer }
        )

        let result = try await session.run()
        let invocationCount = await probe.invocationCount

        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(result.audioFrameCount, 4_800)
        XCTAssertEqual(writer.appendedAudioRanges, [0..<4_096, 4_096..<4_800])
        XCTAssertTrue(writer.didStart)
    }

    func testFREXP002LongAudioPreparesAndRendersOnlyBoundedContiguousWindows() async throws {
        let duration = try RationalTime(value: 5, timescale: 2)
        let fixture = try LifecycleFixture(
            frameCount: 75,
            includeAudio: true,
            duration: duration
        )
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        writer.audioReady = true
        let probe = AudioProviderRangeProbe()
        let session = fixture.session(
            frameProvider: LifecycleFrameProvider(),
            audioSourceProviderFactory: { range in
                await probe.record(range)
                return InMemoryAudioSourceProvider(sources: [:])
            },
            writerFactory: { _, _ in writer }
        )

        let result = try await session.run()
        let ranges = await probe.ranges

        XCTAssertEqual(result.audioFrameCount, 120_000)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.map(\.start), [
            .zero,
            try RationalTime(value: 1, timescale: 1),
            try RationalTime(value: 2, timescale: 1)
        ])
        XCTAssertEqual(ranges.map(\.duration), [
            try RationalTime(value: 1, timescale: 1),
            try RationalTime(value: 1, timescale: 1),
            try RationalTime(value: 1, timescale: 2)
        ])
        XCTAssertLessThanOrEqual(writer.maximumAudioBufferFrameCount, 48_000)
        XCTAssertEqual(writer.appendedAudioRanges.first?.lowerBound, 0)
        XCTAssertEqual(writer.appendedAudioRanges.last?.upperBound, result.audioFrameCount)
        for pair in zip(writer.appendedAudioRanges, writer.appendedAudioRanges.dropFirst()) {
            XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound)
        }
    }

    func testFREXP005CancellationInterruptsAsyncAudioProviderPreparation() async throws {
        let fixture = try LifecycleFixture(frameCount: 3, includeAudio: true)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        let factoryStarted = expectation(description: "audio provider factory started")
        let session = fixture.session(
            frameProvider: LifecycleFrameProvider(),
            audioSourceProviderFactory: { _ in
                factoryStarted.fulfill()
                try await Task<Never, Never>.sleep(nanoseconds: 60_000_000_000)
                return InMemoryAudioSourceProvider(sources: [:])
            },
            writerFactory: { _, _ in writer }
        )

        let runTask = Task { try await session.run() }
        await fulfillment(of: [factoryStarted], timeout: 2)
        session.cancel()

        do {
            _ = try await runTask.value
            XCTFail("expected cancellation")
        } catch let error as ExportError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertEqual(session.state, .cancelled)
        XCTAssertFalse(writer.didStart)
        XCTAssertTrue(writer.didCancel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURL.path))
        try fixture.assertNoPartialFiles()
    }

    func testFREXP005CancellationInterruptsSynchronousCPUMixPromptly() async throws {
        let sampleRate = 192_000
        let fixture = try LifecycleFixture(
            frameCount: 30,
            includeAudio: true,
            duration: try RationalTime(value: 1, timescale: 1),
            audioSampleRate: sampleRate,
            audioTrackCount: 500
        )
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        let mixStarted = expectation(description: "synchronous mixer acquired its source")
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: sampleRate, channelCount: 1),
            frameCount: sampleRate,
            samples: [Float](repeating: 0.25, count: sampleRate)
        )
        let provider = MixStartSignallingProvider(source: source, started: mixStarted)
        let session = fixture.session(
            frameProvider: LifecycleFrameProvider(),
            audioSourceProvider: provider,
            writerFactory: { _, _ in writer }
        )

        let runTask = Task { try await session.run() }
        await fulfillment(of: [mixStarted], timeout: 2)

        let cancelInstant = ContinuousClock.now
        session.cancel()
        do {
            _ = try await runTask.value
            XCTFail("expected cancellation")
        } catch let error as ExportError {
            XCTAssertEqual(error, .cancelled)
        }
        let cancelLatency = cancelInstant.duration(to: .now)

        XCTAssertLessThan(cancelLatency, .seconds(1))
        XCTAssertEqual(session.state, .cancelled)
        XCTAssertFalse(writer.didStart)
        XCTAssertTrue(writer.didCancel)
        try fixture.assertNoPartialFiles()
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

    /// FR-EXP-007: last pending frame must be appended before finish; PTS and endTime aligned.
    ///
    /// Reproduces the golden-export last-frame shape headlessly via the stub writer: N appends,
    /// last PTS == (N-1)/fps, finish endTime == N/fps on the presentation-time timescale, and
    /// no append after finish.
    func testFREXP007LastPendingFrameIsAppendedBeforeFinishWithAlignedEndTime() async throws {
        let frameCount: Int64 = 12
        let frameRate = try FrameRate(frames: 30)
        let fixture = try LifecycleFixture(frameCount: frameCount, frameRate: frameRate)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        // Force not-ready polls so the pending-frame path is exercised before accepting.
        writer.videoNotReadyPollsRemaining = 2
        let session = fixture.session(frameProvider: LifecycleFrameProvider()) { _, _ in writer }

        let result = try await session.run()

        XCTAssertEqual(result.videoFrameCount, frameCount)
        XCTAssertEqual(writer.appendedVideoCount, Int(frameCount))
        XCTAssertEqual(writer.appendedVideoPresentationTimes.count, Int(frameCount))
        let lastPTS = try XCTUnwrap(writer.appendedVideoPresentationTimes.last)
        XCTAssertEqual(lastPTS, CMTime(value: frameCount - 1, timescale: 30))
        XCTAssertEqual(writer.finishedAt, CMTime(value: frameCount, timescale: 30))
        XCTAssertFalse(writer.appendedVideoAfterFinish)
        XCTAssertTrue(writer.didFinish)
        // Exclusive end is after the last sample PTS (non-zero last-sample duration).
        XCTAssertTrue(CMTimeCompare(lastPTS, try XCTUnwrap(writer.finishedAt)) < 0)
    }

    func testFREXP007FrameAlignedEndTimeUsesPresentationTimescale() throws {
        let frameRate = try FrameRate(frames: 30)
        let duration = try frameRate.duration(ofFrames: 12)
        // RationalTime normalizes 12/30 → 2/5; endTime must still stamp timescale 30.
        XCTAssertEqual(duration.value, 2)
        XCTAssertEqual(duration.timescale, 5)
        let end = try ExportTimeMapping.endTime(for: duration, frameRate: frameRate)
        XCTAssertEqual(end, CMTime(value: 12, timescale: 30))
        let lastPTS = try ExportTimeMapping.presentationTime(forFrame: 11, frameRate: frameRate)
        XCTAssertEqual(lastPTS, CMTime(value: 11, timescale: 30))
        XCTAssertTrue(CMTimeCompare(lastPTS, end) < 0)
    }
}

private actor AudioProviderFactoryProbe {
    private(set) var invocationCount = 0

    func recordInvocation() {
        invocationCount += 1
    }
}

private actor AudioProviderRangeProbe {
    private(set) var ranges: [TimeRange] = []

    func record(_ range: TimeRange) {
        ranges.append(range)
    }
}
