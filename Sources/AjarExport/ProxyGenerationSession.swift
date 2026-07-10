// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreMedia
import CoreVideo
import Foundation

/// One-shot ProRes Proxy transcode of original media frames (FR-MED-004).
///
/// Pulls sequential frames from an injected ``ProxySourceFrameProvider`` (media decode path —
/// not the render graph) and writes ProRes 422 Proxy via the shared AVAssetWriter boundary.
public final class ProxyGenerationSession: @unchecked Sendable {
    /// Stable job identity.
    public let id: UUID

    /// Immutable request.
    public let request: ProxyGenerationRequest

    private let frameProvider: any ProxySourceFrameProvider
    private let writerFactory: ExportWriterFactory
    private let onFrameProgress: (@Sendable (ExportProgress) -> Void)?
    private let stateLock = NSLock()
    private var cancellationRequested = false
    private var activeWriter: (any ExportWriting)?

    /// Creates a session with the production AVAssetWriter factory.
    public convenience init(
        id: UUID = UUID(),
        request: ProxyGenerationRequest,
        frameProvider: any ProxySourceFrameProvider,
        onFrameProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) {
        self.init(
            id: id,
            request: request,
            frameProvider: frameProvider,
            writerFactory: { url, settings in
                try AVAssetExportWriter(outputURL: url, settings: settings)
            },
            onFrameProgress: onFrameProgress
        )
    }

    init(
        id: UUID = UUID(),
        request: ProxyGenerationRequest,
        frameProvider: any ProxySourceFrameProvider,
        writerFactory: @escaping ExportWriterFactory,
        onFrameProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) {
        self.id = id
        self.request = request
        self.frameProvider = frameProvider
        self.writerFactory = writerFactory
        self.onFrameProgress = onFrameProgress
    }

    /// Requests cooperative cancellation.
    public func cancel() {
        stateLock.lock()
        cancellationRequested = true
        let writer = activeWriter
        stateLock.unlock()
        writer?.cancel()
    }

    /// Runs the proxy transcode to completion or throws a typed ``ExportError``.
    public func run() async throws -> ProxyGenerationResult {
        try checkCancellation()
        let settings = try makeSettings()
        let transaction = try ExportOutputTransaction(destinationURL: request.destinationURL)
        let writer = try writerFactory(transaction.temporaryURL, settings)
        try installWriter(writer, transaction: transaction)
        do {
            try writer.start()
            try await writeAllFrames(using: writer)
            try checkCancellation()
            let endTime = try presentationTime(
                for: request.frameCount,
                frameRate: request.frameRate
            )
            try await writer.finish(at: endTime)
            try transaction.commit()
            clearWriter()
            return ProxyGenerationResult(
                mediaID: request.mediaID,
                destinationURL: request.destinationURL,
                relativePath: request.relativePath,
                videoFrameCount: request.frameCount
            )
        } catch {
            writer.cancel()
            try? transaction.cleanUp()
            clearWriter()
            throw mapRunError(error)
        }
    }

    private func makeSettings() throws -> ExportSettings {
        try ExportSettings(
            container: .mov,
            video: ExportVideoSettings(
                codec: .proRes422Proxy,
                resolution: request.resolution,
                frameRate: request.frameRate,
                colorSpace: request.colorSpace
            ),
            audio: nil
        )
    }

    private func installWriter(
        _ writer: any ExportWriting,
        transaction: ExportOutputTransaction
    ) throws {
        stateLock.lock()
        activeWriter = writer
        let cancelled = cancellationRequested
        stateLock.unlock()
        if cancelled {
            writer.cancel()
            try? transaction.cleanUp()
            throw ExportError.cancelled
        }
    }

    private func writeAllFrames(using writer: any ExportWriting) async throws {
        let total = request.frameCount
        onFrameProgress?(ExportProgress(framesWritten: 0, totalFrames: total))
        for index in Int64(0)..<total {
            try checkCancellation()
            let pixelBuffer = try writer.makeVideoPixelBuffer()
            try await frameProvider.provideFrame(index: index, into: pixelBuffer)
            let presentation = try presentationTime(for: index, frameRate: request.frameRate)
            try await appendVideo(pixelBuffer, at: presentation, writer: writer)
            onFrameProgress?(ExportProgress(framesWritten: index + 1, totalFrames: total))
        }
    }

    private func appendVideo(
        _ pixelBuffer: CVPixelBuffer,
        at presentation: CMTime,
        writer: any ExportWriting
    ) async throws {
        while true {
            try checkCancellation()
            try writer.checkForFailure()
            if try writer.appendVideoIfReady(pixelBuffer, at: presentation) {
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func clearWriter() {
        stateLock.lock()
        activeWriter = nil
        stateLock.unlock()
    }

    private func mapRunError(_ error: Error) -> ExportError {
        stateLock.lock()
        let cancelled = cancellationRequested || Task.isCancelled
        stateLock.unlock()
        if cancelled {
            return .cancelled
        }
        if let exportError = error as? ExportError {
            return exportError
        }
        return ExportErrorMapper.map(error, destinationURL: request.destinationURL)
    }

    private func checkCancellation() throws {
        stateLock.lock()
        let requested = cancellationRequested || Task.isCancelled
        stateLock.unlock()
        if requested {
            throw ExportError.cancelled
        }
    }

    private func presentationTime(for frameIndex: Int64, frameRate: FrameRate) throws -> CMTime {
        let time = try RationalTime.atFrame(frameIndex, frameRate: frameRate)
        return CMTime(
            value: time.value,
            timescale: CMTimeScale(time.timescale),
            flags: .valid,
            epoch: 0
        )
    }
}
