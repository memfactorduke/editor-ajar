// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Darwin
import Foundation
import Metal

/// Shared cancellation/publication boundary for one disk-cache persist operation.
///
/// `cancel()` and the final atomic file commit use the same lock. Whichever reaches that lock
/// first wins: cancellation prevents publication, while a commit already in progress finishes
/// before cancellation returns. This makes project-generation invalidation linearizable instead
/// of leaving a check-then-write race.
public final class MetalDiskCacheWriteCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAttemptObserver: (@Sendable () -> Void)?
    private var cancellationRequested = false

    /// Creates an active persistence cancellation boundary.
    public init() {
        cancelAttemptObserver = nil
    }

    init(cancelAttemptObserverForTesting: @escaping @Sendable () -> Void) {
        cancelAttemptObserver = cancelAttemptObserverForTesting
    }

    /// Whether lifecycle invalidation has been requested.
    public var isCancelled: Bool {
        lock.withLock { cancellationRequested }
    }

    /// Synchronously invalidates the operation, waiting out a final commit that already won.
    public func cancel() {
        cancelAttemptObserver?()
        lock.withLock {
            cancellationRequested = true
        }
    }

    /// Throws when lifecycle or Swift-task cancellation has been requested.
    public func check() throws {
        let isCancelled = lock.withLock { cancellationRequested }
        if isCancelled || Task.isCancelled {
            throw CancellationError()
        }
    }

    /// Runs the final physical publication as one critical region with `cancel()`.
    func commit(_ operation: () throws -> Void) throws {
        try lock.withLock {
            if cancellationRequested || Task.isCancelled {
                throw CancellationError()
            }
            try operation()
        }
    }
}

/// Completed render state that is safe to hand to background disk persistence.
///
/// Metal textures are documented for cross-thread use after their producing command buffer has
/// completed. This deliberately excludes `RenderedFrame`'s command buffer, completion object, and
/// arbitrary retained objects from the unchecked sendability boundary.
public struct MetalDiskFrameCachePersistenceFrame: @unchecked Sendable {
    let texture: MTLTexture

    /// Content-addressed identity of the completed texture.
    public let contentHash: ContentHash

    fileprivate init(texture: MTLTexture, contentHash: ContentHash) {
        self.texture = texture
        self.contentHash = contentHash
    }
}

extension RenderedFrame {
    /// Waits for GPU completion and returns only the immutable state needed for disk persistence.
    public func diskCachePersistenceFrame() async throws -> MetalDiskFrameCachePersistenceFrame {
        try await waitForCompletion()
        try Task.checkCancellation()
        return MetalDiskFrameCachePersistenceFrame(
            texture: texture,
            contentHash: contentHash
        )
    }
}

extension MetalDiskFrameCache {
    static let writeStagingFilePrefix = ".ajar-write-"

    /// Persists a completed rendered frame to the disk tier.
    ///
    /// This is the write-behind population route: only offline/background render paths call it,
    /// after `frame` has finished on the GPU, so the CPU readback it performs never runs on the
    /// playback path. The entry write happens on the cache's serial queue.
    public func persist(frame: RenderedFrame, output: RenderOutputDescriptor) async throws {
        let cancellation = MetalDiskCacheWriteCancellation()
        try await withTaskCancellationHandler {
            let persistenceFrame = try await frame.diskCachePersistenceFrame()
            try await persist(
                frame: persistenceFrame,
                output: output,
                cancellation: cancellation
            )
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Persists a completed frame with a lifecycle-generation cancellation boundary.
    ///
    /// The cancellation boundary is evaluated around GPU readback and shared with the final atomic
    /// publication. This lets a project/pipeline owner invalidate work synchronously even before
    /// Swift task cancellation reaches the process-wide coordinator.
    public func persist(
        frame: MetalDiskFrameCachePersistenceFrame,
        output: RenderOutputDescriptor,
        cancellation: MetalDiskCacheWriteCancellation
    ) async throws {
        try await withTaskCancellationHandler {
            try cancellation.check()
            let texture = frame.texture
            guard texture.width == output.pixelDimensions.width,
                  texture.height == output.pixelDimensions.height,
                  texture.pixelFormat == output.pixelFormat else {
                throw MetalDiskFrameCacheError.outputDescriptorMismatch
            }

            let bytesPerPixel = try Self.bytesPerPixel(for: output.pixelFormat)
            let payload = try await readbackPayload(
                texture: texture,
                bytesPerPixel: bytesPerPixel,
                cancellation: cancellation
            )
            try cancellation.check()
            let entry = RenderFrameDiskCacheEntry(
                identity: Self.identity(contentHash: frame.contentHash, output: output),
                bytesPerRow: texture.width * bytesPerPixel,
                payload: payload
            )
            try await write(entry: entry, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func readbackPayload(
        texture: MTLTexture,
        bytesPerPixel: Int,
        cancellation: MetalDiskCacheWriteCancellation
    ) async throws -> Data {
        try cancellation.check()
        let bytesPerRow = texture.width * bytesPerPixel
        let byteCount = bytesPerRow * texture.height
        guard byteCount > 0,
              let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw MetalDiskFrameCacheError.readbackFailed("could not allocate readback buffer")
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalDiskFrameCacheError.readbackFailed("could not create readback encoder")
        }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: byteCount
        )
        blitEncoder.endEncoding()

        let completion = RenderCompletion()
        completion.attach(to: commandBuffer)
        commandBuffer.commit()
        do {
            try await completion.wait()
        } catch {
            throw MetalDiskFrameCacheError.readbackFailed(String(describing: error))
        }
        try cancellation.check()
        return Data(bytes: buffer.contents(), count: byteCount)
    }
}

// MARK: - Final write path (serial queue)

extension MetalDiskFrameCache {
    func write(
        entry: RenderFrameDiskCacheEntry,
        cancellation: MetalDiskCacheWriteCancellation
    ) async throws {
        try cancellation.check()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: WriteContinuation) in
                noteWriteQueued()
                ioQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(
                            throwing: MetalDiskFrameCacheError.entryWriteFailed("cache released")
                        )
                        return
                    }
                    defer { self.noteWriteCompleted() }
                    do {
                        try self.performWrite(entry: entry, cancellation: cancellation)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private typealias WriteContinuation = CheckedContinuation<Void, Error>

    private func performWrite(
        entry: RenderFrameDiskCacheEntry,
        cancellation: MetalDiskCacheWriteCancellation
    ) throws {
        try cancellation.check()
        let fileName = entry.identity.entryFileName
        let fileURL = directoryURL.appendingPathComponent(fileName)
        let data = entry.encoded()
        try cancellation.check()
        let stagingURL = directoryURL.appendingPathComponent(Self.writeStagingFileName())
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        do {
            try data.write(to: stagingURL)
        } catch {
            throw MetalDiskFrameCacheError.entryWriteFailed(String(describing: error))
        }

        // The final same-directory rename and owner invalidation share one critical region.
        // Cancellation that wins removes only the private staging file; a commit that wins is
        // physically complete and indexed before synchronous invalidation returns.
        try cancellation.commit {
            try atomicRename(from: stagingURL, to: fileURL)
            stateLock.lock()
            let evictedFileNames = index.recordUse(of: fileName, byteCount: data.count)
            stateLock.unlock()
            removeEntryFiles(named: evictedFileNames)
        }
    }

    private func atomicRename(from sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            let code = errno
            throw MetalDiskFrameCacheError.entryWriteFailed(
                "atomic cache publication failed (POSIX error \(code))"
            )
        }
    }

    static func writeStagingFileName(ownerProcessID: pid_t = getpid()) -> String {
        "\(writeStagingFilePrefix)\(ownerProcessID)-\(UUID().uuidString).tmp"
    }

    func removeStaleWriteStagingFiles(
        from directoryEntries: [URL],
        fileManager: FileManager
    ) {
        let currentProcessID = getpid()
        for url in directoryEntries {
            guard let ownerProcessID = Self.writeStagingOwnerProcessID(url.lastPathComponent),
                  ownerProcessID != currentProcessID,
                  !Self.isProcessAlive(ownerProcessID) else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func writeStagingOwnerProcessID(_ fileName: String) -> pid_t? {
        guard fileName.hasPrefix(writeStagingFilePrefix), fileName.hasSuffix(".tmp") else {
            return nil
        }
        let ownerAndNonce = fileName.dropFirst(writeStagingFilePrefix.count)
        guard let separator = ownerAndNonce.firstIndex(of: "-"),
              let ownerProcessID = pid_t(ownerAndNonce[..<separator]),
              ownerProcessID > 0 else {
            return nil
        }
        return ownerProcessID
    }

    private static func isProcessAlive(_ processID: pid_t) -> Bool {
        if Darwin.kill(processID, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }
}
