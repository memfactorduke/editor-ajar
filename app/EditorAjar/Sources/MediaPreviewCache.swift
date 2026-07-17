// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import AjarMedia
import Foundation

enum MediaPreviewKind: String, Hashable, Sendable {
    case thumbnail = "thumbnail.png"
    case waveform = "waveform.json"
}

enum MediaPreviewCacheError: Error, Equatable, Sendable {
    case missingPackage
    case missingHash
    case missingSourceURL
    case contentIdentityMismatch
    case imageConversionFailed
    case unsupportedAudio
    case invalidCachedData
}

/// The playable bytes represented by a durable preview cache entry.
///
/// Imported working transcodes use their own playable hash rather than the original source hash.
/// Older projects that predate that hash use the exact playable file revision observed for the
/// request, so replacing the working file cannot reuse a stale thumbnail or waveform.
enum MediaPreviewContentIdentity: Hashable, Sendable {
    case durable(ContentHash)
    case legacyTranscode(sourceURL: URL, revision: MediaSourceRevision)
}

/// Synchronous SwiftUI task identity for one project media reference.
///
/// This deliberately contains no filesystem state. The cache captures a legacy transcode's file
/// revision after the task starts, keeping file inspection out of SwiftUI body evaluation.
struct MediaPreviewTaskIdentity: Hashable, Sendable {
    let mediaID: UUID
    let sourceURL: URL?
    let availability: MediaAvailability
    let playableContentHash: ContentHash?
    let isLegacyTranscode: Bool

    init(media: MediaRef) {
        mediaID = media.id
        sourceURL = media.sourceURL.map(Self.standardizedSourceURL)
        availability = media.availability
        playableContentHash = media.playableSourceContentHash
        isLegacyTranscode =
            media.transcodeProvenance != nil
            && media.playableSourceContentHash == nil
    }

    private static func standardizedSourceURL(_ sourceURL: URL) -> URL {
        sourceURL.isFileURL ? sourceURL.standardizedFileURL : sourceURL.standardized
    }
}

/// Restarts a visible SwiftUI preview task when its source or package cache generation changes.
struct MediaPreviewViewTaskIdentity: Hashable, Sendable {
    let media: MediaPreviewTaskIdentity
    let cacheGeneration: UInt64
}

/// Bounded, coalescing scheduler for regeneratable media browser previews (FR-MED-009).
///
/// On-disk location is the package-top-level `thumbnails/` directory (ADR-0007). Content-hash
/// keys make entries regeneratable after relink. **No cache pruning yet** — files can accumulate
/// under `thumbnails/` until a future maintenance pass (L1 / future work).
actor MediaPreviewCache {
    typealias Extractor = @Sendable (MediaRef, MediaPreviewKind) async throws -> Data
    typealias HoverExtractor = @Sendable (MediaRef, RationalTime) async throws -> Data
    typealias ThumbnailDecoder = @Sendable (MediaRef, RationalTime) async throws -> Data
    typealias ContentIdentityResolver =
        @Sendable (MediaRef) async throws
        -> MediaPreviewContentIdentity
    typealias AudioChunkDecoder =
        @Sendable (MediaRef, TimeRange) async throws
        -> AudioSourceBuffer

    /// Four seconds keeps ordinary 48 kHz stereo PCM windows near 1.5 MiB. Sources with unusually
    /// large native formats are retried with successively smaller exact time ranges when the
    /// decoder reports its hard allocation ceiling.
    static let waveformDecodeChunkSeconds: Int64 = 4

    private struct RequestKey: Hashable, Sendable {
        let identity: MediaPreviewContentIdentity
        let kind: MediaPreviewKind
    }

    private struct RequestRecord {
        let generation: UUID
        let task: Task<Data, Error>
        var waiters: [UUID: CheckedContinuation<Data, Error>]
    }

    private let packageURL: URL
    let workerLimit: Int
    let contentIdentityResolver: ContentIdentityResolver?
    private let extractor: Extractor
    let hoverExtractor: HoverExtractor
    var activeWorkers = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    private var requests: [RequestKey: RequestRecord] = [:]

    init(
        packageURL: URL,
        workerLimit: Int = 2,
        contentIdentityResolver: ContentIdentityResolver? = nil,
        hoverExtractor: HoverExtractor? = nil,
        extractor: Extractor? = nil
    ) {
        self.packageURL = packageURL
        self.workerLimit = max(1, workerLimit)
        self.contentIdentityResolver = contentIdentityResolver
        self.extractor =
            extractor ?? { media, kind in
                try await Self.extract(media: media, kind: kind)
            }
        self.hoverExtractor =
            hoverExtractor ?? { media, time in
                try await Self.extractThumbnailPNG(media: media, at: time)
            }
    }

    /// Preserves the original trailing-extractor initializer at existing call sites.
    init(
        packageURL: URL,
        workerLimit: Int = 2,
        extractor: @escaping Extractor
    ) {
        self.init(
            packageURL: packageURL,
            workerLimit: workerLimit,
            contentIdentityResolver: nil,
            hoverExtractor: nil,
            extractor: extractor
        )
    }

    /// Directory for durable thumbnail/waveform files (ADR-0007 top-level `thumbnails/`).
    var thumbnailsDirectoryURL: URL {
        packageURL.appendingPathComponent("thumbnails", isDirectory: true)
    }

    func data(for media: MediaRef, kind: MediaPreviewKind) async throws -> Data {
        let identity = try await contentIdentity(for: media)
        return try await data(for: media, identity: identity, kind: kind)
    }

    /// Loads or creates a preview under an identity already captured by the caller.
    func data(
        for media: MediaRef,
        identity: MediaPreviewContentIdentity,
        kind: MediaPreviewKind
    ) async throws -> Data {
        try validate(identity: identity, for: media)
        let key = RequestKey(identity: identity, kind: kind)
        let destination = cacheURL(for: key)
        if let data = try? Data(contentsOf: destination), isValidCachedData(data, kind: kind) {
            // A legacy file can be replaced while its regeneratable cache survives. Recheck the
            // captured revision after reading and before returning those cached bytes.
            try validate(identity: identity, for: media)
            return data
        }

        return try await waitForRequest(
            key: key,
            media: media,
            identity: identity,
            kind: kind,
            destination: destination
        )
    }

    /// Administratively cancels all waiters for one exact content identity and preview kind.
    /// Ordinary per-waiter cancellation is propagated automatically by ``data(for:identity:kind:)``.
    func cancel(for identity: MediaPreviewContentIdentity, kind: MediaPreviewKind) {
        let key = RequestKey(identity: identity, kind: kind)
        guard let record = requests.removeValue(forKey: key) else { return }
        record.task.cancel()
        for continuation in record.waiters.values {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Cancels every in-flight durable extraction.
    func cancelAll() {
        let records = Array(requests.values)
        requests.removeAll()
        for record in records {
            record.task.cancel()
            for continuation in record.waiters.values {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func makeExtractionTask(
        media: MediaRef,
        identity: MediaPreviewContentIdentity,
        kind: MediaPreviewKind,
        destination: URL
    ) -> Task<Data, Error> {
        Task<Data, Error> {
            try Task.checkCancellation()
            return try await self.runBounded {
                try Task.checkCancellation()
                try Self.validate(identity: identity, for: media)
                let data = try await extractor(media, kind)
                try Task.checkCancellation()
                guard !data.isEmpty else {
                    throw MediaPreviewCacheError.invalidCachedData
                }
                // Refuse to publish under an obsolete legacy revision if its file changed while
                // extraction was in flight.
                try Self.validate(identity: identity, for: media)
                // mkdir -p packageRoot/thumbnails before atomic write. Required for both saved
                // packages (thumbnails/ may not exist yet) and the untitled autosave fallback
                // (package root may have been cleared of recovery while still hosting caches).
                try Self.ensureDirectory(for: destination)
                try data.write(to: destination, options: .atomic)
                do {
                    try Self.validate(identity: identity, for: media)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
                return data
            }
        }
    }

    private func observeCompletion(
        of task: Task<Data, Error>,
        for key: RequestKey,
        generation: UUID
    ) {
        Task {
            let result = await task.result
            completeRequest(result, for: key, generation: generation)
        }
    }

    private func waitForRequest(
        key: RequestKey,
        media: MediaRef,
        identity: MediaPreviewContentIdentity,
        kind: MediaPreviewKind,
        destination: URL
    ) async throws -> Data {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var record = requests[key] {
                    record.waiters[waiterID] = continuation
                    requests[key] = record
                } else {
                    let generation = UUID()
                    let task = makeExtractionTask(
                        media: media,
                        identity: identity,
                        kind: kind,
                        destination: destination
                    )
                    requests[key] = RequestRecord(
                        generation: generation,
                        task: task,
                        waiters: [waiterID: continuation]
                    )
                    // The first continuation is recorded before observation starts, so even an
                    // immediate extractor result has a waiter to resume.
                    observeCompletion(of: task, for: key, generation: generation)
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID, for: key)
            }
        }
    }

    private func completeRequest(
        _ result: Result<Data, Error>,
        for key: RequestKey,
        generation: UUID
    ) {
        guard let record = requests[key], record.generation == generation else { return }
        requests[key] = nil
        for continuation in record.waiters.values {
            continuation.resume(with: result)
        }
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        for key: RequestKey
    ) {
        guard var record = requests[key],
            let continuation = record.waiters.removeValue(forKey: waiterID)
        else { return }
        continuation.resume(throwing: CancellationError())
        if record.waiters.isEmpty {
            requests[key] = nil
            record.task.cancel()
        } else {
            requests[key] = record
        }
    }

    func cachedData(for media: MediaRef, kind: MediaPreviewKind) -> Data? {
        guard let identity = try? Self.resolveContentIdentity(for: media) else { return nil }
        let key = RequestKey(identity: identity, kind: kind)
        guard let data = try? Data(contentsOf: cacheURL(for: key)),
            isValidCachedData(data, kind: kind)
        else {
            return nil
        }
        guard (try? validate(identity: identity, for: media)) != nil else { return nil }
        return data
    }

    /// Test seam: number of callers currently sharing one exact extraction.
    func waiterCountForTesting(for media: MediaRef, kind: MediaPreviewKind) -> Int {
        guard let identity = try? Self.resolveContentIdentity(for: media) else { return 0 }
        return requests[RequestKey(identity: identity, kind: kind)]?.waiters.count ?? 0
    }

    private func cacheURL(for key: RequestKey) -> URL {
        let identityComponent: String
        switch key.identity {
        case .durable(let hash):
            identityComponent = "\(hash.algorithm.rawValue)-\(hash.digest)"
        case .legacyTranscode(let sourceURL, let revision):
            let encoding = Self.legacyIdentityEncoding(
                sourceURL: sourceURL,
                revision: revision
            )
            identityComponent = "legacy-\(ContentHash.sha256(data: encoding).digest)"
        }
        // ADR-0007: top-level thumbnails/, not caches/thumbnails/.
        return thumbnailsDirectoryURL.appendingPathComponent(
            "\(identityComponent)-\(key.kind.rawValue)"
        )
    }

    private static func legacyIdentityEncoding(
        sourceURL: URL,
        revision: MediaSourceRevision
    ) -> Data {
        let modificationBits =
            revision.modificationDate.map {
                String($0.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
            } ?? "nil"
        let fields = [
            "editor-ajar-media-preview-legacy-v1",
            sourceURL.absoluteString,
            revision.fileSize.map(String.init) ?? "nil",
            modificationBits,
            revision.fileNumber.map(String.init) ?? "nil"
        ]
        return Data(fields.joined(separator: "\u{0}").utf8)
    }

    /// Creates the destination's parent directory tree (`package/…/thumbnails/`) if needed.
    ///
    /// Foundation's atomic `Data.write` uses mktemp in the parent; a missing or non-directory
    /// parent surfaces as `NSCocoaErrorDomain` / errno `EINVAL` (22) rather than a clean ENOENT.
    private static func ensureDirectory(for fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else {
            throw MediaPreviewCacheError.missingPackage
        }
    }

    private func isValidCachedData(_ data: Data, kind: MediaPreviewKind) -> Bool {
        Self.isValidCachedData(data, kind: kind)
    }

}
