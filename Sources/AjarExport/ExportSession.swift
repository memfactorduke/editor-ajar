// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import CoreMedia
import CoreVideo
import Foundation

private struct PendingVideoFrame {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
}

/// Builds the immutable decoded-source lookup used by one export audio mix.
///
/// The requested range is always a bounded, monotonically increasing slice of the export.
/// Platform adapters decode only that slice while `AjarExport` remains independent of
/// AVFoundation decode modules (ADR-0019).
public typealias ExportAudioSourceProviderFactory =
    @Sendable (_ range: TimeRange) async throws -> any AudioSourceProvider

struct ExportAudioChunk {
    let buffer: RenderedAudioBuffer
    let presentationFrameOffset: Int
    var appendedFrameCount: Int
}

final class ExportAudioStream {
    let settings: ExportAudioSettings
    let totalFrameCount: Int
    var nextChunkFrameOffset: Int
    var currentChunk: ExportAudioChunk?
    var continuation = OfflineAudioRenderContinuation()

    init(
        settings: ExportAudioSettings,
        totalFrameCount: Int,
        firstChunk: ExportAudioChunk?
    ) {
        self.settings = settings
        self.totalFrameCount = totalFrameCount
        currentChunk = firstChunk
        nextChunkFrameOffset = firstChunk?.buffer.frameCount ?? 0
    }

    var hasPendingAudio: Bool {
        currentChunk != nil || nextChunkFrameOffset < totalFrameCount
    }
}

/// One-shot export lifecycle designed to be owned by the FR-EXP-005 background queue.
public final class ExportSession: @unchecked Sendable {
    /// Stable queue identity.
    public let id: UUID

    /// Immutable export inputs.
    public let request: ExportRequest

    /// Source-tier resolution policy (FR-EXP-007). Production uses ``ExportSourceSelectionPolicy/alwaysOriginal``.
    ///
    /// See `ExportSourceSelection.swift` and ADR-0019 "Proxy exclusion audit hook".
    public let sourceSelectionPolicy: ExportSourceSelectionPolicy

    /// Frame provider (module-internal so ``ExportSessionSupport`` can audit graph tiers).
    let frameProvider: any ExportVideoFrameProvider
    let audioSourceProvider: (any AudioSourceProvider)?
    let audioSourceProviderFactory: ExportAudioSourceProviderFactory?
    let writerFactory: ExportWriterFactory
    let beforePublish: (() -> Void)?
    let onFrameProgress: (@Sendable (ExportProgress) -> Void)?
    let stateLock = NSLock()
    var stateValue = ExportSessionState.ready
    var cancellationRequested = false
    var framesWrittenValue = Int64(0)
    var totalFramesValue = Int64(0)
    var activeWriter: (any ExportWriting)?
    var activeAudioProviderTask: Task<any AudioSourceProvider, Error>?
    var sourceSelectionRecordsValue: [ExportFrameSourceSelection] = []
    static let audioAppendFrameCount = 4_096
    static let audioRenderChunkDurationSeconds = 1

    /// Current lifecycle state, safe to poll from a queue or UI adapter.
    public var state: ExportSessionState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateValue
    }

    /// Thread-safe frame progress (`framesWritten` / `totalFrames`) for the queue driver.
    public var progress: ExportProgress {
        stateLock.lock()
        defer { stateLock.unlock() }
        return ExportProgress(
            framesWritten: framesWrittenValue,
            totalFrames: totalFramesValue
        )
    }

    /// Per-frame media-tier resolutions recorded during `run()` (FR-EXP-007 proxy exclusion hook).
    ///
    /// Empty until the session starts writing frames. After a successful export, every row must
    /// be `.original` under the production policy; FR-MED-004 (#217) extends adapters while this
    /// audit stays the test surface.
    public var sourceSelectionRecords: [ExportFrameSourceSelection] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sourceSelectionRecordsValue
    }

    /// Creates a session using the production AVAssetWriter boundary.
    public convenience init(
        id: UUID = UUID(),
        request: ExportRequest,
        frameProvider: any ExportVideoFrameProvider,
        audioSourceProvider: (any AudioSourceProvider)? = nil,
        sourceSelectionPolicy: ExportSourceSelectionPolicy = .alwaysOriginal,
        onFrameProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) {
        self.init(
            id: id,
            request: request,
            frameProvider: frameProvider,
            audioSourceProvider: audioSourceProvider,
            audioSourceProviderFactory: nil,
            sourceSelectionPolicy: sourceSelectionPolicy,
            writerFactory: { url, settings in
                try AVAssetExportWriter(outputURL: url, settings: settings)
            },
            beforePublish: nil,
            onFrameProgress: onFrameProgress
        )
    }

    /// Creates a session whose platform audio sources are prepared asynchronously on demand.
    ///
    /// The factory is invoked only when the request carries audio settings. Its returned provider
    /// is immutable and used synchronously by the deterministic offline mixer.
    public convenience init(
        id: UUID = UUID(),
        request: ExportRequest,
        frameProvider: any ExportVideoFrameProvider,
        audioSourceProviderFactory: @escaping ExportAudioSourceProviderFactory,
        sourceSelectionPolicy: ExportSourceSelectionPolicy = .alwaysOriginal,
        onFrameProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) {
        self.init(
            id: id,
            request: request,
            frameProvider: frameProvider,
            audioSourceProvider: nil,
            audioSourceProviderFactory: audioSourceProviderFactory,
            sourceSelectionPolicy: sourceSelectionPolicy,
            writerFactory: { url, settings in
                try AVAssetExportWriter(outputURL: url, settings: settings)
            },
            beforePublish: nil,
            onFrameProgress: onFrameProgress
        )
    }

    init(
        id: UUID = UUID(),
        request: ExportRequest,
        frameProvider: any ExportVideoFrameProvider,
        audioSourceProvider: (any AudioSourceProvider)? = nil,
        audioSourceProviderFactory: ExportAudioSourceProviderFactory? = nil,
        sourceSelectionPolicy: ExportSourceSelectionPolicy = .alwaysOriginal,
        writerFactory: @escaping ExportWriterFactory,
        beforePublish: (() -> Void)? = nil,
        onFrameProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) {
        self.id = id
        self.request = request
        self.frameProvider = frameProvider
        self.audioSourceProvider = audioSourceProvider
        self.audioSourceProviderFactory = audioSourceProviderFactory
        self.sourceSelectionPolicy = sourceSelectionPolicy
        self.writerFactory = writerFactory
        self.beforePublish = beforePublish
        self.onFrameProgress = onFrameProgress
    }

    /// Requests cooperative cancellation. Cleanup completes before `run()` returns.
    public func cancel() {
        var writerToCancel: (any ExportWriting)?
        var audioTaskToCancel: Task<any AudioSourceProvider, Error>?
        stateLock.lock()
        switch stateValue {
        case .preparing, .writing, .finishing:
            cancellationRequested = true
            stateValue = .cancelling
            writerToCancel = activeWriter
            audioTaskToCancel = activeAudioProviderTask
        case .ready:
            cancellationRequested = true
            stateValue = .cancelled
        case .cancelling:
            writerToCancel = activeWriter
            audioTaskToCancel = activeAudioProviderTask
        case .completed, .cancelled, .failed:
            break
        }
        stateLock.unlock()
        audioTaskToCancel?.cancel()
        writerToCancel?.cancel()
    }

    /// Runs the complete start → append → finalize lifecycle exactly once.
    public func run() async throws -> ExportResult {
        try beginRun()
        return try await withTaskCancellationHandler {
            try await executeRun()
        } onCancel: {
            self.cancel()
        }
    }

    func appendMedia(
        writer: any ExportWriting,
        videoFrameCount: Int64,
        audioStream: ExportAudioStream?
    ) async throws {
        var videoFrameIndex = Int64(0)
        var pendingVideoFrame: PendingVideoFrame?

        while videoFrameIndex < videoFrameCount
            || pendingVideoFrame != nil
            || audioStream?.hasPendingAudio == true {
            try checkCancellation()
            try writer.checkForFailure()
            var madeProgress = false

            if let audioStream,
                audioStream.currentChunk == nil,
                audioStream.nextChunkFrameOffset < audioStream.totalFrameCount {
                try await renderNextAudioChunk(in: audioStream)
                madeProgress = true
            }

            if videoFrameIndex < videoFrameCount, pendingVideoFrame == nil {
                pendingVideoFrame = try await renderVideoFrame(
                    index: videoFrameIndex,
                    writer: writer
                )
            }
            if let frame = pendingVideoFrame,
                try writer.appendVideoIfReady(
                    frame.pixelBuffer,
                    at: frame.presentationTime
                ) {
                pendingVideoFrame = nil
                videoFrameIndex += 1
                recordFrameWritten()
                madeProgress = true
            }
            if let audioStream, var chunk = audioStream.currentChunk {
                let end = min(
                    chunk.appendedFrameCount + Self.audioAppendFrameCount,
                    chunk.buffer.frameCount
                )
                if try writer.appendAudioIfReady(
                    chunk.buffer,
                    frames: chunk.appendedFrameCount..<end,
                    presentationFrameOffset: chunk.presentationFrameOffset
                ) {
                    chunk.appendedFrameCount = end
                    audioStream.currentChunk =
                        end == chunk.buffer.frameCount ? nil : chunk
                    madeProgress = true
                }
            }

            if !madeProgress {
                try await Task<Never, Never>.sleep(nanoseconds: 1_000_000)
            } else {
                await Task.yield()
            }
        }
        // Structural guarantee: never call finish while a rendered frame is still pending append.
        // (videoFrameIndex tracks successful appends; pending is independent.)
        if pendingVideoFrame != nil || videoFrameIndex != videoFrameCount {
            throw ExportError.writerFailed(
                "export video drain incomplete: appended=\(videoFrameIndex) "
                    + "expected=\(videoFrameCount) pending=\(pendingVideoFrame != nil)"
            )
        }
    }

    private func renderVideoFrame(
        index: Int64,
        writer: any ExportWriting
    ) async throws -> PendingVideoFrame {
        let pixelBuffer = try writer.makeVideoPixelBuffer()
        let timelineTime = try request.timelineTime(forFrame: index)
        do {
            try await frameProvider.renderFrame(at: timelineTime, into: pixelBuffer)
        } catch is CancellationError {
            throw ExportError.cancelled
        } catch let error as ExportError {
            // Providers already emit typed ExportError (including frameRenderFailed); do not wrap.
            throw error
        } catch {
            throw ExportError.frameRenderFailed(
                frameIndex: index,
                reason: String(describing: error)
            )
        }
        recordSourceSelections(forFrame: index)
        try checkCancellation()
        let presentationTime = try ExportTimeMapping.presentationTime(
            forFrame: index,
            frameRate: request.settings.video.frameRate
        )
        return PendingVideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime
        )
    }
}
