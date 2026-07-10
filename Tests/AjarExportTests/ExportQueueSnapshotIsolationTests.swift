// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@testable import AjarExport

final class ExportQueueSnapshotIsolationTests: XCTestCase {
    func testFREXP005SnapshotIsolationIgnoresLiveProjectMutation() async throws {
        let directory = try makeSnapshotTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalSequenceName = "SnapshotOriginal"
        let liveSource = try makeLiveSource(
            destinationURL: directory.appendingPathComponent("out.mp4"),
            sequenceName: originalSequenceName
        )
        let originalSequenceID = try XCTUnwrap(liveSource.project.sequences.first?.id)
        let enqueuedRequest = try makeEnqueuedRequest(
            from: liveSource,
            destinationURL: directory.appendingPathComponent("out.mp4"),
            sequenceName: originalSequenceName
        )
        XCTAssertEqual(enqueuedRequest.sequence.name, originalSequenceName)

        let provider = ControllableFrameProvider(holdUntilRelease: true)
        let namesAtSessionStart = SequenceNameCapture()
        let namesAtFrameRender = SequenceNameCapture()
        let queue = makeSnapshotQueue(
            provider: provider,
            namesAtSessionStart: namesAtSessionStart,
            namesAtFrameRender: namesAtFrameRender
        )

        let jobID = await queue.enqueue(
            request: enqueuedRequest,
            displayName: originalSequenceName
        )
        let running = await ExportQueueFixtures.waitUntil {
            await queue.state(for: jobID) == .running
        }
        XCTAssertTrue(running)

        // Mutate the shared live source while the job is held open mid-encode.
        liveSource.mutateSequenceName("MutatedAfterEnqueue")
        XCTAssertEqual(liveSource.project.sequences.first?.name, "MutatedAfterEnqueue")

        provider.releaseAll()
        let done = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: jobID) == .done
        }
        XCTAssertTrue(done)

        let context = SnapshotAssertContext(
            originalSequenceName: originalSequenceName,
            originalSequenceID: originalSequenceID,
            destinationURL: enqueuedRequest.destinationURL,
            namesAtSessionStart: namesAtSessionStart,
            namesAtFrameRender: namesAtFrameRender,
            liveSource: liveSource
        )
        try await assertSnapshotPreserved(queue: queue, jobID: jobID, context: context)
    }

    private func makeSnapshotTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-export-queue-snap-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeLiveSource(
        destinationURL: URL,
        sequenceName: String
    ) throws -> MutableProjectSource {
        let seed = try ExportQueueFixtures.makeRequest(
            destinationURL: destinationURL,
            frameCount: 2,
            sequenceName: sequenceName
        )
        return MutableProjectSource(seed.project)
    }

    private func makeEnqueuedRequest(
        from liveSource: MutableProjectSource,
        destinationURL: URL,
        sequenceName: String
    ) throws -> ExportRequest {
        let template = try ExportQueueFixtures.makeRequest(
            destinationURL: destinationURL,
            frameCount: 2,
            sequenceName: sequenceName
        )
        let sequenceID = try XCTUnwrap(liveSource.project.sequences.first?.id)
        return try ExportRequest(
            project: liveSource.project,
            sequenceID: sequenceID,
            range: template.range,
            destinationURL: template.destinationURL,
            settings: template.settings
        )
    }

    private func makeSnapshotQueue(
        provider: ControllableFrameProvider,
        namesAtSessionStart: SequenceNameCapture,
        namesAtFrameRender: SequenceNameCapture
    ) -> ExportQueue {
        ExportQueue { jobID, jobRequest, onProgress in
            // Session factory must receive the enqueue-time snapshot, not a re-read of liveSource.
            namesAtSessionStart.record(jobRequest.sequence.name)
            let recordingProvider = SnapshotRecordingFrameProvider(
                inner: provider,
                sequenceName: jobRequest.sequence.name,
                namesSeen: namesAtFrameRender
            )
            return ExportSession(
                id: jobID,
                request: jobRequest,
                frameProvider: recordingProvider,
                writerFactory: { temporaryURL, _ in
                    SequenceNamedWriter(
                        outputURL: temporaryURL,
                        sequenceName: jobRequest.sequence.name
                    )
                },
                onFrameProgress: onProgress
            )
        }
    }

    private struct SnapshotAssertContext {
        let originalSequenceName: String
        let originalSequenceID: UUID
        let destinationURL: URL
        let namesAtSessionStart: SequenceNameCapture
        let namesAtFrameRender: SequenceNameCapture
        let liveSource: MutableProjectSource
    }

    private func assertSnapshotPreserved(
        queue: ExportQueue,
        jobID: UUID,
        context: SnapshotAssertContext
    ) async throws {
        let originalName = context.originalSequenceName
        let captured = await queue.request(for: jobID)
        XCTAssertEqual(captured?.sequence.name, originalName)
        XCTAssertEqual(captured?.sequenceID, context.originalSequenceID)
        XCTAssertEqual(captured?.project.sequences.first?.name, originalName)

        XCTAssertEqual(context.namesAtSessionStart.values(), [originalName])
        XCTAssertFalse(context.namesAtFrameRender.values().isEmpty)
        XCTAssertTrue(context.namesAtFrameRender.values().allSatisfy { $0 == originalName })
        XCTAssertFalse(context.namesAtFrameRender.values().contains("MutatedAfterEnqueue"))

        let outputBytes = try Data(contentsOf: context.destinationURL)
        let outputText = String(data: outputBytes, encoding: .utf8)
        XCTAssertEqual(outputText, "complete:\(originalName)")
        XCTAssertNotEqual(outputText, "complete:MutatedAfterEnqueue")

        let snap = await queue.snapshots().first
        XCTAssertEqual(snap?.snapshotSequenceID, context.originalSequenceID)
        XCTAssertEqual(snap?.displayName, originalName)
        XCTAssertEqual(context.liveSource.project.sequences.first?.name, "MutatedAfterEnqueue")
    }
}

// MARK: - Snapshot isolation fixtures

/// App-model-style shared mutable project the request is built FROM.
final class MutableProjectSource: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Project

    init(_ project: Project) {
        storage = project
    }

    var project: Project {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mutateSequenceName(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let original = storage.sequences.first else {
            return
        }
        let mutated = Sequence(
            id: original.id,
            name: name,
            videoTracks: original.videoTracks,
            audioTracks: original.audioTracks,
            markers: original.markers,
            timebase: original.timebase
        )
        storage = Project(
            schemaVersion: storage.schemaVersion,
            schemaMinor: storage.schemaMinor,
            settings: storage.settings,
            mediaPool: storage.mediaPool,
            sequences: [mutated]
        )
    }
}

final class SequenceNameCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: [String] = []

    func record(_ name: String) {
        lock.lock()
        raw.append(name)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return raw
    }
}

/// Records the sequence name captured at session construction for each rendered frame.
final class SnapshotRecordingFrameProvider: ExportVideoFrameProvider, @unchecked Sendable {
    private let inner: ControllableFrameProvider
    private let sequenceName: String
    private let namesSeen: SequenceNameCapture

    init(
        inner: ControllableFrameProvider,
        sequenceName: String,
        namesSeen: SequenceNameCapture
    ) {
        self.inner = inner
        self.sequenceName = sequenceName
        self.namesSeen = namesSeen
    }

    func renderFrame(
        at timelineTime: RationalTime,
        into pixelBuffer: CVPixelBuffer
    ) async throws {
        namesSeen.record(sequenceName)
        try await inner.renderFrame(at: timelineTime, into: pixelBuffer)
    }
}

/// Writes the session-time sequence name into the published file body.
final class SequenceNamedWriter: ExportWriting {
    private let inner: LifecycleWriter
    private let sequenceName: String

    init(outputURL: URL, sequenceName: String) {
        inner = LifecycleWriter(outputURL: outputURL)
        self.sequenceName = sequenceName
    }

    func start() throws {
        try inner.start()
    }

    func makeVideoPixelBuffer() throws -> CVPixelBuffer {
        try inner.makeVideoPixelBuffer()
    }

    func appendVideoIfReady(
        _ pixelBuffer: CVPixelBuffer,
        at time: CMTime
    ) throws -> Bool {
        try inner.appendVideoIfReady(pixelBuffer, at: time)
    }

    func appendAudioIfReady(
        _ buffer: RenderedAudioBuffer,
        frames: Range<Int>
    ) throws -> Bool {
        try inner.appendAudioIfReady(buffer, frames: frames)
    }

    func checkForFailure() throws {
        try inner.checkForFailure()
    }

    func finish(at endTime: CMTime) async throws {
        try await inner.finish(at: endTime)
        try Data("complete:\(sequenceName)".utf8).write(to: inner.outputURL)
    }

    func cancel() {
        inner.cancel()
    }
}
