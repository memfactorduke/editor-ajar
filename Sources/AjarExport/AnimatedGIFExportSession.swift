// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation

/// One-shot ImageIO export lifecycle used by the GIF engine and future heterogeneous queue.
public final class AnimatedGIFExportSession: @unchecked Sendable {
    /// Stable queue identity.
    public let id: UUID

    /// Immutable export inputs.
    public let request: AnimatedGIFExportRequest

    /// Source-tier policy; production remains pinned to originals (FR-EXP-007).
    public let sourceSelectionPolicy: ExportSourceSelectionPolicy

    let frameProvider: any ExportVideoFrameProvider
    let writerFactory: AnimatedGIFWriterFactory
    let beforePublish: (() -> Void)?
    let onFrameProgress: (@Sendable (ExportProgress) -> Void)?
    let stateLock = NSLock()
    var stateValue = ExportSessionState.ready
    var cancellationRequested = false
    var framesWrittenValue = Int64(0)
    var totalFramesValue = Int64(0)
    var sourceSelectionRecordsValue: [ExportFrameSourceSelection] = []

    /// Current lifecycle state, safe to poll from a queue or UI adapter.
    public var state: ExportSessionState {
        stateLock.withLock { stateValue }
    }

    /// Thread-safe sequential frame progress.
    public var progress: ExportProgress {
        stateLock.withLock {
            ExportProgress(
                framesWritten: framesWrittenValue,
                totalFrames: totalFramesValue
            )
        }
    }

    /// Per-frame source tiers observed during the render-graph pulls.
    public var sourceSelectionRecords: [ExportFrameSourceSelection] {
        stateLock.withLock { sourceSelectionRecordsValue }
    }

    /// Creates a session using the production ImageIO GIF writer.
    public convenience init(
        id: UUID = UUID(),
        request: AnimatedGIFExportRequest,
        frameProvider: any ExportVideoFrameProvider,
        sourceSelectionPolicy: ExportSourceSelectionPolicy = .alwaysOriginal,
        onFrameProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) {
        self.init(
            id: id,
            request: request,
            frameProvider: frameProvider,
            sourceSelectionPolicy: sourceSelectionPolicy,
            writerFactory: { url, frameCount, loopPolicy in
                try ImageIOAnimatedGIFWriter(
                    url: url,
                    expectedFrameCount: frameCount,
                    loopPolicy: loopPolicy
                )
            },
            beforePublish: nil,
            onFrameProgress: onFrameProgress
        )
    }

    init(
        id: UUID = UUID(),
        request: AnimatedGIFExportRequest,
        frameProvider: any ExportVideoFrameProvider,
        sourceSelectionPolicy: ExportSourceSelectionPolicy = .alwaysOriginal,
        writerFactory: @escaping AnimatedGIFWriterFactory,
        beforePublish: (() -> Void)? = nil,
        onFrameProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) {
        self.id = id
        self.request = request
        self.frameProvider = frameProvider
        self.sourceSelectionPolicy = sourceSelectionPolicy
        self.writerFactory = writerFactory
        self.beforePublish = beforePublish
        self.onFrameProgress = onFrameProgress
    }

    /// Requests cooperative cancellation; partial output is cleaned before `run()` returns.
    public func cancel() {
        stateLock.withLock {
            cancellationRequested = true
            switch stateValue {
            case .ready:
                stateValue = .cancelled
            case .preparing, .writing, .finishing:
                stateValue = .cancelling
            case .cancelling, .completed, .cancelled, .failed:
                break
            }
        }
    }

    /// Runs render, encode, finalize, and atomic publication exactly once.
    public func run() async throws -> ExportResult {
        try beginRun()
        return try await withTaskCancellationHandler {
            try await executeRun()
        } onCancel: {
            self.cancel()
        }
    }

    private func executeRun() async throws -> ExportResult {
        var transaction: ExportOutputTransaction?
        do {
            return try await performExport(transaction: &transaction)
        } catch {
            throw finalizeFailure(error, transaction: transaction)
        }
    }

    private func performExport(
        transaction: inout ExportOutputTransaction?
    ) async throws -> ExportResult {
        try checkCancellation()
        let frameCount = try request.frameCount()
        let preparedTransaction = try ExportOutputTransaction(
            destinationURL: request.destinationURL,
            destinationCollisionPolicy: request.destinationCollisionPolicy
        )
        transaction = preparedTransaction
        let writer = try makeWriter(
            temporaryURL: preparedTransaction.temporaryURL,
            frameCount: frameCount
        )

        try transition(to: .writing)
        setTotalFrames(frameCount)
        try await appendFrames(count: frameCount, writer: writer)
        try finalize(writer: writer)
        beforePublish?()
        try publish(preparedTransaction)
        let sourceSelections = sourceSelectionRecords
        return ExportResult(
            destinationURL: request.destinationURL,
            duration: request.range.duration,
            videoFrameCount: frameCount,
            audioFrameCount: 0,
            sourceSelectionRecordCount: sourceSelections.count,
            usedProxyMedia: sourceSelections.contains { $0.tier == .proxy }
        )
    }

    private func makeWriter(
        temporaryURL: URL,
        frameCount: Int64
    ) throws -> any AnimatedGIFWriting {
        do {
            return try writerFactory(
                temporaryURL,
                Int(frameCount),
                request.settings.loopPolicy
            )
        } catch {
            if let infrastructureError = preservedWriterBoundaryError(error) {
                throw infrastructureError
            }
            throw ExportError.animatedGIFDestinationCreationFailed(String(describing: error))
        }
    }

    private func appendFrames(
        count: Int64,
        writer: any AnimatedGIFWriting
    ) async throws {
        for index in 0..<count {
            try checkCancellation()
            let pixelBuffer = try makePixelBuffer()
            try await renderFrame(index: index, into: pixelBuffer)
            recordSourceSelections(forFrame: index)
            try checkCancellation()
            try appendFrame(index: index, pixelBuffer: pixelBuffer, writer: writer)
            try checkCancellation()
            recordFrameWritten()
            await Task.yield()
        }
    }

    private func renderFrame(index: Int64, into pixelBuffer: CVPixelBuffer) async throws {
        do {
            try await frameProvider.renderFrame(
                at: request.timelineTime(forFrame: index),
                into: pixelBuffer
            )
        } catch is CancellationError {
            throw ExportError.cancelled
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.frameRenderFailed(
                frameIndex: index,
                reason: String(describing: error)
            )
        }
    }

    private func appendFrame(
        index: Int64,
        pixelBuffer: CVPixelBuffer,
        writer: any AnimatedGIFWriting
    ) throws {
        do {
            try writer.append(
                pixelBuffer: pixelBuffer,
                sourceColorSpace: request.settings.sourceColorSpace,
                colorConversionPolicy: request.settings.colorConversionPolicy,
                delayCentiseconds: try request.delayCentiseconds(forFrame: index)
            )
        } catch {
            if let infrastructureError = preservedWriterBoundaryError(error) {
                throw infrastructureError
            }
            throw ExportError.animatedGIFFrameWriteFailed(
                frameIndex: index,
                reason: String(describing: error)
            )
        }
    }

    private func finalize(writer: any AnimatedGIFWriting) throws {
        try checkCancellation()
        try transition(to: .finishing)
        do {
            try writer.finalize()
        } catch {
            if let infrastructureError = preservedWriterBoundaryError(error) {
                throw infrastructureError
            }
            throw ExportError.animatedGIFFinalizeFailed(String(describing: error))
        }
        try checkCancellation()
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            request.settings.resolution.width,
            request.settings.resolution.height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw ExportError.pixelBufferCreationFailed(status)
        }
        return buffer
    }

    private func preservedWriterBoundaryError(_ error: Error) -> ExportError? {
        if error is CancellationError {
            return .cancelled
        }
        if let exportError = error as? ExportError {
            return ExportErrorMapper.map(exportError, destinationURL: request.destinationURL)
        }
        let mapped = ExportErrorMapper.map(error, destinationURL: request.destinationURL)
        if case .diskFull = mapped {
            return mapped
        }
        return nil
    }
}
