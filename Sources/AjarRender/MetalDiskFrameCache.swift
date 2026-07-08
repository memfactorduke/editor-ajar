// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal

/// Errors produced by the disk-backed frame cache.
public enum MetalDiskFrameCacheError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The cache directory could not be created or scanned.
    case cacheDirectoryUnavailable(String)

    /// The output pixel format has no supported disk representation.
    case unsupportedPixelFormat(UInt)

    /// The frame texture does not match the output descriptor it was rendered for.
    case outputDescriptorMismatch

    /// GPU readback of the frame texture failed.
    case readbackFailed(String)

    /// The encoded entry could not be written to the cache directory.
    case entryWriteFailed(String)

    /// A human-readable description of the failure.
    public var description: String {
        switch self {
        case .cacheDirectoryUnavailable(let message):
            "frame cache directory unavailable: \(message)"
        case .unsupportedPixelFormat(let rawValue):
            "unsupported frame cache pixel format (raw value \(rawValue))"
        case .outputDescriptorMismatch:
            "frame texture does not match the output descriptor"
        case .readbackFailed(let message):
            "frame cache readback failed: \(message)"
        case .entryWriteFailed(let message):
            "frame cache entry write failed: \(message)"
        }
    }
}

/// Disk tier of the content-hash frame cache (FR-PLAY-005, FR-CMP-006, ADR-0009).
///
/// Entries are keyed by the same identity as the executor's RAM tier — content hash, color mode,
/// pixel format, and dimensions — and stored as versioned, checksummed files. The playback path
/// never touches this class synchronously: `scheduleLoad` only enqueues background work, and
/// population happens through `persist(frame:output:)`, which offline/background render routes
/// call after a frame completes (readback therefore never runs on the playback path, ADR-0012).
/// Corrupt, truncated, or mismatched entries read as misses and are quarantined (deleted).
/// Eviction is deterministic byte-budgeted LRU via `ByteBudgetedLRUIndex`.
public final class MetalDiskFrameCache {
    /// Default byte budget: roughly sixty warm 1080p BGRA frames (~8.3 MB each) or a dozen 4K
    /// frames, enough to keep restart scrubbing warm while staying far below typical free disk.
    public static let defaultByteBudget = 512 * 1024 * 1024

    /// Directory holding the cache entries.
    public let directoryURL: URL

    /// Maximum total entry bytes retained on disk.
    public let byteBudget: Int

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ioQueue = DispatchQueue(label: "org.editor-ajar.render.disk-frame-cache")
    private let stateLock = NSLock()
    private var index: ByteBudgetedLRUIndex<String>
    private var diskHitCountValue = 0
    private var diskMissCountValue = 0
    private var quarantinedEntryCountValue = 0

    /// Creates a disk frame cache rooted at a directory, restoring any surviving entries.
    ///
    /// Existing entries are indexed least-recently-used first by file modification date (file
    /// name breaks ties deterministically) and trimmed to the byte budget immediately.
    public init(
        device: MTLDevice,
        directoryURL: URL,
        byteBudget: Int = MetalDiskFrameCache.defaultByteBudget
    ) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRenderError.commandQueueCreationFailed
        }
        self.device = device
        self.commandQueue = commandQueue
        self.directoryURL = directoryURL
        self.byteBudget = max(0, byteBudget)
        self.index = ByteBudgetedLRUIndex(byteBudget: self.byteBudget)
        try createDirectoryAndRestoreIndex()
    }

    /// Number of entries currently stored on disk.
    public var storedEntryCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return index.count
    }

    /// Total bytes currently stored on disk.
    public var storedByteCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return index.totalByteCount
    }

    /// Number of scheduled loads satisfied from disk.
    public var diskHitCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return diskHitCountValue
    }

    /// Number of scheduled loads that found no valid entry.
    public var diskMissCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return diskMissCountValue
    }

    /// Number of invalid entries that were quarantined (deleted) on read.
    public var quarantinedEntryCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return quarantinedEntryCountValue
    }

    /// Blocks the calling thread until all queued cache work has drained. Test/bench support;
    /// never call this from the playback path.
    public func waitUntilIdle() {
        ioQueue.sync {}
    }

    /// Test hook: pauses the serial cache queue so cross-thread orderings can be forced
    /// deterministically. Every `suspendIO` must be balanced by `resumeIO` before the cache is
    /// released. Never call from production code.
    func suspendIO() {
        ioQueue.suspend()
    }

    /// Test hook: resumes the serial cache queue after `suspendIO`.
    func resumeIO() {
        ioQueue.resume()
    }

    /// Persists a completed rendered frame to the disk tier.
    ///
    /// This is the write-behind population route: only offline/background render paths call it,
    /// after `frame` has finished on the GPU, so the CPU readback it performs never runs on the
    /// playback path. The entry write happens on the cache's serial queue.
    public func persist(frame: RenderedFrame, output: RenderOutputDescriptor) async throws {
        try await frame.waitForCompletion()
        let texture = frame.texture
        guard texture.width == output.pixelDimensions.width,
              texture.height == output.pixelDimensions.height,
              texture.pixelFormat == output.pixelFormat else {
            throw MetalDiskFrameCacheError.outputDescriptorMismatch
        }

        let bytesPerPixel = try Self.bytesPerPixel(for: output.pixelFormat)
        let payload = try await readbackPayload(texture: texture, bytesPerPixel: bytesPerPixel)
        let entry = RenderFrameDiskCacheEntry(
            identity: Self.identity(contentHash: frame.contentHash, output: output),
            bytesPerRow: texture.width * bytesPerPixel,
            payload: payload
        )
        try await write(entry: entry)
    }

    /// Enqueues a background disk lookup; the completion receives a GPU texture on a valid hit.
    ///
    /// Never blocks the caller: all file I/O and texture upload happen on the cache's serial
    /// queue. Invalid entries are quarantined and reported as a miss (`nil`).
    func scheduleLoad(
        for identity: RenderFrameCacheIdentity,
        completion: @escaping (MTLTexture?) -> Void
    ) {
        ioQueue.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            completion(self.performLoad(identity))
        }
    }

    /// Maps the executor cache key fields onto the tier-shared identity.
    static func identity(
        contentHash: ContentHash,
        output: RenderOutputDescriptor
    ) -> RenderFrameCacheIdentity {
        RenderFrameCacheIdentity(
            contentHash: contentHash,
            colorModeRawValue: output.colorMode.cacheIdentityRawValue,
            pixelFormatRawValue: UInt32(clamping: output.pixelFormat.rawValue),
            width: output.pixelDimensions.width,
            height: output.pixelDimensions.height
        )
    }

    static func bytesPerPixel(for pixelFormat: MTLPixelFormat) throws -> Int {
        switch pixelFormat {
        case .bgra8Unorm, .rgba8Unorm:
            return 4
        case .rgba16Float:
            return 8
        default:
            throw MetalDiskFrameCacheError.unsupportedPixelFormat(pixelFormat.rawValue)
        }
    }

    // MARK: - Load path (serial queue)

    private func performLoad(_ identity: RenderFrameCacheIdentity) -> MTLTexture? {
        let fileName = identity.entryFileName
        let fileURL = directoryURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            recordMiss()
            return nil
        }

        let entry: RenderFrameDiskCacheEntry
        do {
            entry = try RenderFrameDiskCacheEntry.decode(data, expecting: identity)
        } catch {
            quarantine(fileName: fileName)
            return nil
        }

        // A checksummed entry whose row stride is not the canonical stride for its format and
        // width would upload as garbled pixels; treat it exactly like corruption. A decodable
        // entry that fails texture upload is quarantined too, so a bad entry can never be
        // re-read in a loop.
        guard hasExpectedStride(entry), let texture = makeTexture(from: entry) else {
            quarantine(fileName: fileName)
            return nil
        }

        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )
        stateLock.lock()
        index.markUsed(fileName)
        diskHitCountValue += 1
        stateLock.unlock()
        return texture
    }

    /// Whether the entry's stored row stride is the canonical stride for its pixel format and
    /// width. The identity comparison alone cannot catch a re-strided payload, so this check is
    /// part of read-time integrity (a mismatch is quarantined, never uploaded).
    private func hasExpectedStride(_ entry: RenderFrameDiskCacheEntry) -> Bool {
        guard let pixelFormat = MTLPixelFormat(rawValue: UInt(entry.identity.pixelFormatRawValue)),
              let bytesPerPixel = try? Self.bytesPerPixel(for: pixelFormat) else {
            return false
        }
        return entry.bytesPerRow == entry.identity.width * bytesPerPixel
    }

    private func makeTexture(from entry: RenderFrameDiskCacheEntry) -> MTLTexture? {
        let identity = entry.identity
        guard let pixelFormat = MTLPixelFormat(rawValue: UInt(identity.pixelFormatRawValue)),
              identity.width > 0, identity.height > 0,
              entry.bytesPerRow > 0,
              entry.payload.count == entry.bytesPerRow * identity.height else {
            return nil
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: identity.width,
            height: identity.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = entry.payload.withUnsafeBytes({ rawBuffer in
                  rawBuffer.baseAddress.flatMap { baseAddress in
                      device.makeBuffer(
                          bytes: baseAddress,
                          length: entry.payload.count,
                          options: .storageModeShared
                      )
                  }
              }) else {
            return nil
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        blitEncoder.copy(
            from: buffer,
            sourceOffset: 0,
            sourceBytesPerRow: entry.bytesPerRow,
            sourceBytesPerImage: entry.payload.count,
            sourceSize: MTLSize(width: identity.width, height: identity.height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.error == nil else {
            return nil
        }
        return texture
    }

    private func recordMiss() {
        stateLock.lock()
        diskMissCountValue += 1
        stateLock.unlock()
    }

    private func quarantine(fileName: String) {
        try? FileManager.default.removeItem(
            at: directoryURL.appendingPathComponent(fileName)
        )
        stateLock.lock()
        index.remove(fileName)
        diskMissCountValue += 1
        quarantinedEntryCountValue += 1
        stateLock.unlock()
    }

    // MARK: - Write path (serial queue)

    private func write(entry: RenderFrameDiskCacheEntry) async throws {
        try await withCheckedThrowingContinuation { (continuation: WriteContinuation) in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(
                        throwing: MetalDiskFrameCacheError.entryWriteFailed("cache released")
                    )
                    return
                }
                do {
                    try self.performWrite(entry: entry)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private typealias WriteContinuation = CheckedContinuation<Void, Error>

    private func performWrite(entry: RenderFrameDiskCacheEntry) throws {
        let fileName = entry.identity.entryFileName
        let fileURL = directoryURL.appendingPathComponent(fileName)
        let data = entry.encoded()
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw MetalDiskFrameCacheError.entryWriteFailed(String(describing: error))
        }

        stateLock.lock()
        let evictedFileNames = index.recordUse(of: fileName, byteCount: data.count)
        stateLock.unlock()
        removeEntryFiles(named: evictedFileNames)
    }

    private func removeEntryFiles(named fileNames: [String]) {
        for fileName in fileNames {
            try? FileManager.default.removeItem(
                at: directoryURL.appendingPathComponent(fileName)
            )
        }
    }

}

// MARK: - Readback (offline/background route only) and startup restore

extension MetalDiskFrameCache {
    private func readbackPayload(texture: MTLTexture, bytesPerPixel: Int) async throws -> Data {
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
        return Data(bytes: buffer.contents(), count: byteCount)
    }

    private struct RestoredEntry {
        let fileName: String
        let byteCount: Int
        let modificationDate: Date
    }

    fileprivate func createDirectoryAndRestoreIndex() throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw MetalDiskFrameCacheError.cacheDirectoryUnavailable(String(describing: error))
        }

        let entryURLs: [URL]
        do {
            entryURLs = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )
        } catch {
            throw MetalDiskFrameCacheError.cacheDirectoryUnavailable(String(describing: error))
        }

        let restoredEntries = entryURLs
            .filter { $0.pathExtension == "ajarframe" }
            .map { url -> RestoredEntry in
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                )
                return RestoredEntry(
                    fileName: url.lastPathComponent,
                    byteCount: values?.fileSize ?? 0,
                    modificationDate: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { first, second in
                if first.modificationDate != second.modificationDate {
                    return first.modificationDate < second.modificationDate
                }
                return first.fileName < second.fileName
            }

        var evictedFileNames: [String] = []
        stateLock.lock()
        for entry in restoredEntries {
            evictedFileNames.append(
                contentsOf: index.recordUse(of: entry.fileName, byteCount: entry.byteCount)
            )
        }
        stateLock.unlock()
        removeEntryFiles(named: evictedFileNames)
    }
}

// Thread-safety: all mutable state (`index`, counters) is guarded by `stateLock`, and every
// file-system mutation is serialized on the private `ioQueue`; the Metal objects are immutable
// references. Hence the unchecked conformance.
extension MetalDiskFrameCache: @unchecked Sendable {}

extension RenderOutputColorMode {
    /// Stable raw value used by the tier-shared cache identity; never renumber existing cases.
    var cacheIdentityRawValue: UInt32 {
        switch self {
        case .presented:
            0
        case .linearWorking:
            1
        }
    }
}
