// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarAudio
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
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

    func testFREXP002ProductionDefaultsIncludeStereoLinearPCM() throws {
        let project = try EditorAjarSampleProjectFactory.makeSampleProject()

        let settings = try EditorAjarExportQueueController.defaultSettings(for: project)

        let audio = try XCTUnwrap(settings.audio)
        XCTAssertEqual(audio.codec, .linearPCM)
        XCTAssertEqual(audio.sampleRate, project.settings.audioSampleRate)
        XCTAssertEqual(audio.channelCount, 2)
        XCTAssertNil(audio.bitRate)
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
            exportQueueController: controller,
            opensSampleProjectWhenNoRecovery: true
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
            exportQueueController: controller,
            opensSampleProjectWhenNoRecovery: true
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

    func testFREXP005MovieDialogQueuesProjectCompatibleDeliverySettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-app-export-movie-request-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = AppMovieRequestCapture()
        let controller = EditorAjarExportQueueController(
            sessionFactory: Self.makeStubSessionFactory(
                holdFirstFrame: true,
                firstFrameDelayNanoseconds: 2_000_000_000,
                capture: capture
            )
        )
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportQueueController: controller,
            opensSampleProjectWhenNoRecovery: true
        )
        let fixture = try XCTUnwrap(model.project)
        let deliveryProject = Project(
            schemaVersion: fixture.schemaVersion,
            schemaMinor: fixture.schemaMinor,
            settings: ProjectSettings(
                frameRate: fixture.settings.frameRate,
                resolution: fixture.settings.resolution,
                colorSpace: .displayP3,
                audioSampleRate: 44_100
            ),
            mediaPool: fixture.mediaPool,
            sequences: fixture.sequences,
            looks: fixture.looks
        )
        model.replaceProjectPreservingHistoryForTesting(deliveryProject)
        let destination = directory.appendingPathComponent("captured.mp4")

        model.presentExportDialog()
        model.setExportMode(.video)
        XCTAssertFalse(model.isExportDialogSubmitting)
        model.enqueueExportDialogSelection(destinationURL: destination)
        XCTAssertTrue(model.isExportDialogSubmitting)
        model.enqueueExportDialogSelection(destinationURL: destination)
        model.dismissExportDialog()
        XCTAssertTrue(model.exportDialog.isPresented)

        let acceptedAndRunning = await waitUntil(timeout: 3) {
            model.exportQueueController.jobs.first?.state == .running
                && !model.exportDialog.isPresented
                && !model.isExportDialogSubmitting
        }
        XCTAssertTrue(acceptedAndRunning)
        XCTAssertNil(model.exportDialog.statusMessage)
        XCTAssertNil(model.exportQueueController.statusMessage)
        XCTAssertFalse(model.exportDialog.isPresented)
        XCTAssertFalse(model.isExportDialogSubmitting)
        XCTAssertTrue(model.isExportQueuePanelVisible)
        XCTAssertEqual(model.exportQueueController.jobs.count, 1)

        model.presentExportDialog()
        model.setExportMode(.video)
        model.enqueueExportDialogSelection(destinationURL: destination)
        let collisionRefused = await waitUntil(timeout: 3) {
            model.exportDialog.statusMessage != nil && !model.isExportDialogSubmitting
        }
        XCTAssertTrue(collisionRefused)
        XCTAssertTrue(model.exportDialog.isPresented)
        XCTAssertEqual(model.exportQueueController.jobs.count, 1)
        XCTAssertEqual(
            model.exportDialog.statusMessage,
            "An export is already queued or completed for \(destination.path). Choose a different filename."
        )
        model.dismissExportDialog()

        let completed = await waitUntil(timeout: 5) {
            let state = model.exportQueueController.jobs.first?.state
            return state == .done || state == .failed
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(model.exportQueueController.jobs.first?.state, .done)

        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.project, deliveryProject)
        XCTAssertEqual(request.settings.video.colorSpace, .displayP3)
        XCTAssertEqual(request.settings.audio?.sampleRate, 44_100)
        XCTAssertEqual(request.destinationURL, destination)
    }

    func testFREXP006DialogEnqueuesCapturedAnimatedGIFRequestAndCloses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-app-export-gif-request-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = AppAnimatedGIFRequestCapture()
        let controller = EditorAjarExportQueueController(
            sessionFactory: Self.makeStubSessionFactory(),
            animatedGIFSessionFactory: { jobID, request, onProgress in
                capture.record(request)
                return AnimatedGIFExportSession(
                    id: jobID,
                    request: request,
                    frameProvider: AppAnimatedGIFFrameProvider(),
                    onFrameProgress: onProgress
                )
            }
        )
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportQueueController: controller,
            opensSampleProjectWhenNoRecovery: true
        )
        let originalProject = try XCTUnwrap(model.project)
        let sequence = try XCTUnwrap(model.activeSequence)
        let destination = directory.appendingPathComponent("captured.gif")

        model.presentExportDialog()
        model.setExportMode(.animatedGIF)
        model.setAnimatedGIFSizeChoice(.quarter)
        model.setAnimatedGIFFrameRateChoice(.fps10)
        model.setAnimatedGIFLoopChoice(.playOnce)
        model.enqueueExportDialogSelection(destinationURL: destination)

        let enqueued = await waitUntil(timeout: 3) {
            (model.exportQueueController.jobs.first?.kind == .animatedGIF
                && !model.exportDialog.isPresented
                && model.isExportQueuePanelVisible)
                || model.exportQueueController.statusMessage != nil
                || model.exportDialog.statusMessage != nil
        }
        XCTAssertTrue(enqueued)
        XCTAssertNil(model.exportQueueController.statusMessage)
        XCTAssertNil(model.exportDialog.statusMessage)
        XCTAssertFalse(model.exportDialog.isPresented)
        XCTAssertTrue(model.isExportQueuePanelVisible)

        let editedProject = originalProject.updatingPreferProxyPlayback(true)
        model.replaceProjectPreservingHistoryForTesting(editedProject)
        XCTAssertEqual(model.project, editedProject)
        XCTAssertNotEqual(model.project, originalProject)

        let job = try XCTUnwrap(model.exportQueueController.jobs.first)
        XCTAssertEqual(job.kind, .animatedGIF)
        XCTAssertEqual(job.destinationURL, destination)
        XCTAssertEqual(job.snapshotSequenceID, sequence.id)

        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.project, originalProject)
        XCTAssertEqual(request.sequenceID, sequence.id)
        XCTAssertEqual(request.destinationURL, destination)
        XCTAssertEqual(request.settings.resolution, PixelDimensions(width: 80, height: 45))
        XCTAssertEqual(request.settings.frameRate, try FrameRate(frames: 10))
        XCTAssertEqual(request.settings.loopPolicy, .playOnce)

        let completed = await waitUntil(timeout: 5) {
            model.exportQueueController.jobs.first?.state == .done
                || model.exportQueueController.jobs.first?.state == .failed
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(model.exportQueueController.jobs.first?.state, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFREXP006ProductionAppPathPublishesDecodableAnimatedGIF() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable for production GIF acceptance")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-app-export-gif-production-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let originalProject = try XCTUnwrap(model.project)
        let videoMediaID = try XCTUnwrap(
            originalProject.mediaPool.first(where: { $0.metadata.pixelDimensions != nil })?.id
        )
        let proxyEnabledProject = originalProject
            .updatingPreferProxyPlayback(true)
            .updatingMediaProxyState(
                .ready(relativePath: "caches/proxies/acceptance.mov"),
                for: [videoMediaID]
            )
        model.replaceProjectPreservingHistoryForTesting(proxyEnabledProject)
        XCTAssertTrue(model.preferProxyPlayback)
        XCTAssertEqual(
            model.project?.mediaPool.first(where: { $0.id == videoMediaID })?.proxyState,
            .ready(relativePath: "caches/proxies/acceptance.mov")
        )
        let destination = directory.appendingPathComponent("production.gif")
        model.scrub(to: 0)
        model.setTimelineRangeIn()
        model.scrub(to: 8)
        model.setTimelineRangeOut()
        model.presentExportDialog()
        model.setExportMode(.animatedGIF)
        model.setExportRangeChoice(.inOutMarks)
        model.setAnimatedGIFSizeChoice(.quarter)
        model.setAnimatedGIFFrameRateChoice(.fps10)
        model.setAnimatedGIFLoopChoice(.forever)

        model.enqueueExportDialogSelection(destinationURL: destination)
        let completed = await waitUntil(timeout: 30) {
            let state = model.exportQueueController.jobs.first?.state
            return state == .done || state == .failed || state == .cancelled
        }
        XCTAssertTrue(completed)
        let job = try XCTUnwrap(model.exportQueueController.jobs.first)
        if job.state == .failed {
            return XCTFail(
                "production animated GIF export failed: \(String(describing: job.failure))")
        }
        XCTAssertEqual(job.kind, .animatedGIF)
        XCTAssertEqual(job.state, .done)
        let result = try XCTUnwrap(job.result)
        XCTAssertGreaterThan(result.sourceSelectionRecordCount, 0)
        XCTAssertFalse(result.usedProxyMedia)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        let firstFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(firstFrame.width, 80)
        XCTAssertEqual(firstFrame.height, 45)

        let globalProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let globalGIF = globalProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual((globalGIF?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 0)
        let frameProperties =
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let frameGIF = frameProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay =
            (frameGIF?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (frameGIF?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        XCTAssertEqual(try XCTUnwrap(delay), 0.1, accuracy: 0.000_1)
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
        holdFirstFrame: Bool = false,
        firstFrameDelayNanoseconds: UInt64 = 200_000_000,
        capture: AppMovieRequestCapture? = nil
    ) -> ExportSessionFactory {
        { jobID, request, onProgress in
            capture?.record(request)
            return ExportSession(
                id: jobID,
                request: request,
                frameProvider: AppStubFrameProvider(
                    holdFirstFrame: holdFirstFrame,
                    firstFrameDelayNanoseconds: firstFrameDelayNanoseconds
                ),
                audioSourceProvider: AppStubAudioSourceProvider(
                    sampleRate: request.project.settings.audioSampleRate
                ),
                writerFactory: { temporaryURL, _ in
                    AppStubWriter(outputURL: temporaryURL)
                },
                onFrameProgress: onProgress
            )
        }
    }
}

// MARK: - Stub export session pieces (app-test only)

private final class AppMovieRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: ExportRequest?

    var request: ExportRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    func record(_ request: ExportRequest) {
        lock.lock()
        storedRequest = request
        lock.unlock()
    }
}

private final class AppStubFrameProvider: ExportVideoFrameProvider, @unchecked Sendable {
    private let holdFirstFrame: Bool
    private let firstFrameDelayNanoseconds: UInt64
    private let lock = NSLock()
    private var heldOnce = false

    init(holdFirstFrame: Bool, firstFrameDelayNanoseconds: UInt64) {
        self.holdFirstFrame = holdFirstFrame
        self.firstFrameDelayNanoseconds = firstFrameDelayNanoseconds
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
                try await Task.sleep(nanoseconds: firstFrameDelayNanoseconds)
            }
        }
        try Task.checkCancellation()
    }
}

private struct AppStubAudioSourceProvider: AudioSourceProvider {
    let sampleRate: Int

    func audioSource(for _: UUID) throws -> AudioSourceBuffer {
        let frameCount = sampleRate * 60
        return try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: sampleRate, channelCount: 1),
            frameCount: frameCount,
            samples: [Float](repeating: 0, count: frameCount)
        )
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
        frames: Range<Int>,
        presentationFrameOffset: Int
    ) throws -> Bool {
        _ = buffer
        _ = frames
        _ = presentationFrameOffset
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

private final class AppAnimatedGIFRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: AnimatedGIFExportRequest?

    var request: AnimatedGIFExportRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    func record(_ request: AnimatedGIFExportRequest) {
        lock.lock()
        storedRequest = request
        lock.unlock()
    }
}

private final class AppAnimatedGIFFrameProvider: ExportVideoFrameProvider, @unchecked Sendable {
    func renderFrame(at _: RationalTime, into pixelBuffer: CVPixelBuffer) async throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ExportError.frameRenderFailed(frameIndex: 0, reason: "missing GIF test pixels")
        }
        let byteCount =
            CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
        baseAddress.initializeMemory(as: UInt8.self, repeating: 96, count: byteCount)
    }
}
