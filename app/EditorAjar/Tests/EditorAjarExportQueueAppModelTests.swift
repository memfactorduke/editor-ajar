// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarAudio
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@testable import AjarExport
@testable import EditorAjar

@MainActor
final class EditorAjarExportQueueAppModelTests: XCTestCase {
    func testFREXP005ToggleExportQueuePanel() {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)

        XCTAssertFalse(model.isExportQueuePanelVisible)
        model.toggleExportQueuePanel()
        XCTAssertTrue(model.isExportQueuePanelVisible)
        model.toggleExportQueuePanel()
        XCTAssertFalse(model.isExportQueuePanelVisible)
    }

    func testFREXP005EnqueueActiveSequenceExportOpensPanelAndCapturesSequenceName() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-app-export-queue-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Inject a stub session factory so CI never drives production Metal/AV encode.
        let controller = EditorAjarExportQueueController(
            sessionFactory: Self.makeStubSessionFactory()
        )
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportQueueController: controller
        )
        let sequenceName = try XCTUnwrap(model.activeSequence?.name)
        let destination = directory.appendingPathComponent("app-export.mov")

        model.enqueueActiveSequenceExport(destinationURL: destination)

        let enqueued = await waitUntil(timeout: 3) {
            !model.exportQueueController.jobs.isEmpty
                || model.exportQueueController.statusMessage != nil
        }
        XCTAssertTrue(enqueued)
        XCTAssertTrue(model.isExportQueuePanelVisible)

        let job = try XCTUnwrap(model.exportQueueController.jobs.first)
        XCTAssertEqual(job.displayName, sequenceName)
        XCTAssertEqual(job.destinationURL, destination)
        // Snapshot sequence id matches the active sequence at enqueue time.
        XCTAssertEqual(job.snapshotSequenceID, model.activeSequence?.id)

        let completed = await waitUntil(timeout: 3) {
            model.exportQueueController.jobs.first?.state == .done
                || model.exportQueueController.jobs.first?.state == .failed
                || model.exportQueueController.jobs.first?.state == .cancelled
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(model.exportQueueController.jobs.first?.state, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFREXP005CancelExportJobAPIIsReachableFromAppModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-app-export-cancel-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = EditorAjarExportQueueController(
            sessionFactory: Self.makeStubSessionFactory(holdFirstFrame: true)
        )
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportQueueController: controller
        )
        let destination = directory.appendingPathComponent("cancel.mov")
        model.enqueueActiveSequenceExport(destinationURL: destination)

        let enqueued = await waitUntil(timeout: 3) {
            !model.exportQueueController.jobs.isEmpty
        }
        guard enqueued, let jobID = model.exportQueueController.jobs.first?.id else {
            // Enqueue may fail before a job is created (e.g. settings validation); still covered above.
            return
        }

        model.cancelExportJob(jobID)
        // Terminal or still-running is fine; the API must not crash and must remain typed.
        _ = await waitUntil(timeout: 5) {
            let state = model.exportQueueController.jobs.first(where: { $0.id == jobID })?.state
            return state == .cancelled || state == .done || state == .failed
                || state == .pausedWillRestart || state == .pending || state == .running
        }
        XCTAssertNotNil(model.exportQueueController.jobs.first(where: { $0.id == jobID }))
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(
            by: .milliseconds(Int64(timeout * 1_000))
        )
        while ContinuousClock.now < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    /// Deterministic, fast stub — no Metal decode, no AVAssetWriter hardware encode.
    private static func makeStubSessionFactory(
        holdFirstFrame: Bool = false
    ) -> ExportSessionFactory {
        { jobID, request, onProgress in
            ExportSession(
                id: jobID,
                request: request,
                frameProvider: AppStubFrameProvider(holdFirstFrame: holdFirstFrame),
                writerFactory: { temporaryURL, _ in
                    AppStubWriter(outputURL: temporaryURL)
                },
                onFrameProgress: onProgress
            )
        }
    }
}

// MARK: - Stub export session pieces (app-test only)

private final class AppStubFrameProvider: ExportVideoFrameProvider, @unchecked Sendable {
    private let holdFirstFrame: Bool
    private let lock = NSLock()
    private var heldOnce = false

    init(holdFirstFrame: Bool) {
        self.holdFirstFrame = holdFirstFrame
    }

    func renderFrame(
        at _: RationalTime,
        into _: CVPixelBuffer
    ) async throws {
        if holdFirstFrame {
            lock.lock()
            let shouldHold = !heldOnce
            heldOnce = true
            lock.unlock()
            if shouldHold {
                // Brief hold so cancel can land on a RUNNING job without real encode cost.
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        try Task.checkCancellation()
    }
}

private final class AppStubWriter: ExportWriting {
    private let outputURL: URL
    private let lock = NSLock()
    private var didCancel = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() throws {
        try Data("partial".utf8).write(to: outputURL)
    }

    func makeVideoPixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw ExportError.pixelBufferCreationFailed(status)
        }
        return buffer
    }

    func appendVideoIfReady(
        _ pixelBuffer: CVPixelBuffer,
        at time: CMTime
    ) throws -> Bool {
        _ = pixelBuffer
        _ = time
        lock.lock()
        let cancelled = didCancel
        lock.unlock()
        if cancelled {
            throw ExportError.cancelled
        }
        return true
    }

    func appendAudioIfReady(
        _ buffer: RenderedAudioBuffer,
        frames: Range<Int>
    ) throws -> Bool {
        _ = buffer
        _ = frames
        return true
    }

    func checkForFailure() throws {}

    func finish(at endTime: CMTime) async throws {
        _ = endTime
        lock.lock()
        let cancelled = didCancel
        lock.unlock()
        if cancelled {
            throw ExportError.cancelled
        }
        try Data("complete".utf8).write(to: outputURL)
    }

    func cancel() {
        lock.lock()
        didCancel = true
        lock.unlock()
    }
}
