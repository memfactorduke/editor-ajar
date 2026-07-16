// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// A lightweight filesystem revision used to avoid re-hashing unchanged playable media.
public struct MediaSourceRevision: Hashable, Sendable {
    /// Last reported file size.
    public let fileSize: UInt64?

    /// Last reported modification time.
    public let modificationDate: Date?

    /// Filesystem identity (inode on Darwin) when available.
    public let fileNumber: UInt64?

    /// Creates a source revision.
    public init(fileSize: UInt64?, modificationDate: Date?, fileNumber: UInt64?) {
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.fileNumber = fileNumber
    }
}

/// Stable evidence captured immediately before a media reader starts using a source.
public struct VerifiedMediaSource: Hashable, Sendable {
    /// Stable project media identity.
    public let mediaID: UUID

    /// Standardized playable file URL that was verified.
    public let sourceURL: URL

    /// Filesystem revision that was verified.
    public let sourceRevision: MediaSourceRevision

    /// Verified playable-byte identity when the project has one or needs a legacy baseline.
    public let playableContentHash: ContentHash?

}

/// Typed failures that prevent a decoder from trusting playable source bytes.
public enum MediaSourceIdentityVerificationError: Error, Equatable, Sendable {
    /// The reference has no playable URL.
    case missingSourceURL(mediaID: UUID)

    /// The reference is explicitly offline.
    case sourceOffline(mediaID: UUID, sourceURL: URL?)

    /// Only local files can be revision- and content-verified.
    case sourceMustBeFileURL(URL)

    /// The source does not currently exist as a readable file.
    case sourceUnavailable(URL)

    /// Streaming SHA-256 verification failed.
    case hashingFailed(url: URL, reason: String)

    /// Playable bytes no longer match the durable identity stored in the project.
    case playableContentHashMismatch(
        url: URL,
        expected: ContentHash,
        actual: ContentHash
    )

    /// The file revision changed while it was being verified or read.
    case sourceChangedDuringRead(URL)
}

/// Revision-keyed verifier shared by playback and regeneratable waveform extraction.
///
/// New working transcodes carry a durable playable hash. A project written before that field
/// existed establishes a session-only baseline from its first stable revision; later revisions
/// must match that baseline. Ordinary references without any stored hash intentionally remain
/// revision-only, preserving the legacy nil-hash behavior until an explicit relink adds identity.
public actor MediaSourceIdentityVerifier {
    /// Process-wide verifier used by app read paths.
    public static let shared = MediaSourceIdentityVerifier()

    private static let maximumRevisionHashEntries = 256

    private typealias HashOperation = @Sendable (
        URL,
        @escaping @Sendable () -> Bool
    ) throws -> ContentHash

    private struct RevisionHashKey: Hashable, Sendable {
        let sourceURL: URL
        let revision: MediaSourceRevision
    }

    private struct RevisionHashEntry: Sendable {
        let contentHash: ContentHash
        var accessOrder: UInt64
    }

    private struct LegacyTranscodeKey: Hashable, Sendable {
        let mediaID: UUID
        let sourceURL: URL
        let originalContentHash: ContentHash
    }

    private enum ExpectedIdentity {
        case durable(ContentHash)
        case legacyTranscode(LegacyTranscodeKey)
        case revisionOnly
    }

    private let hashOperation: HashOperation
    private var revisionHashes: [RevisionHashKey: RevisionHashEntry] = [:]
    private var legacyTranscodeBaselines: [LegacyTranscodeKey: ContentHash] = [:]
    private var accessOrder: UInt64 = 0

    /// Creates the production verifier.
    public init() {
        let hasher = SHA256MediaFileHasher()
        hashOperation = { sourceURL, isCancelled in
            try hasher.contentHash(of: sourceURL, isCancelled: isCancelled)
        }
    }

    /// Creates a verifier with an injectable, sendable streaming hasher.
    public init<Hasher>(hasher: Hasher) where Hasher: MediaFileHashing & Sendable {
        hashOperation = { sourceURL, isCancelled in
            try hasher.contentHash(of: sourceURL, isCancelled: isCancelled)
        }
    }

    /// Verifies identity and captures the exact source revision a reader may consume.
    public func verifyBeforeReading(_ media: MediaRef) async throws -> VerifiedMediaSource {
        try Task.checkCancellation()
        guard let unstandardizedURL = media.sourceURL else {
            throw MediaSourceIdentityVerificationError.missingSourceURL(mediaID: media.id)
        }
        guard !media.isOffline else {
            throw MediaSourceIdentityVerificationError.sourceOffline(
                mediaID: media.id,
                sourceURL: media.sourceURL
            )
        }

        let sourceURL = unstandardizedURL.standardizedFileURL
        let revision = try Self.securityScopedRevision(for: sourceURL)
        let expectedIdentity = Self.expectedIdentity(for: media, sourceURL: sourceURL)
        let playableContentHash: ContentHash?

        switch expectedIdentity {
        case .revisionOnly:
            playableContentHash = nil
        case .durable(let expected):
            let actual = try await contentHash(for: sourceURL, revision: revision)
            try verifyStableRevision(revision, for: sourceURL)
            storeRevisionHash(actual, sourceURL: sourceURL, revision: revision)
            guard actual == expected else {
                throw MediaSourceIdentityVerificationError.playableContentHashMismatch(
                    url: sourceURL,
                    expected: expected,
                    actual: actual
                )
            }
            playableContentHash = actual
        case .legacyTranscode(let key):
            let actual = try await contentHash(for: sourceURL, revision: revision)
            try verifyStableRevision(revision, for: sourceURL)
            storeRevisionHash(actual, sourceURL: sourceURL, revision: revision)
            if let baseline = legacyTranscodeBaselines[key] {
                guard actual == baseline else {
                    throw MediaSourceIdentityVerificationError.playableContentHashMismatch(
                        url: sourceURL,
                        expected: baseline,
                        actual: actual
                    )
                }
            } else {
                // A legacy project never recorded its working transcode hash. Trust exactly the
                // first stable revision observed this session, never the unrelated original hash.
                legacyTranscodeBaselines[key] = actual
            }
            playableContentHash = actual
        }

        try Task.checkCancellation()
        return VerifiedMediaSource(
            mediaID: media.id,
            sourceURL: sourceURL,
            sourceRevision: revision,
            playableContentHash: playableContentHash
        )
    }

    /// Refuses results if the source changed after verification but before a reader completed.
    public func verifyAfterReading(_ verifiedSource: VerifiedMediaSource) throws {
        try Task.checkCancellation()
        try verifyStableRevision(
            verifiedSource.sourceRevision,
            for: verifiedSource.sourceURL
        )
    }

    /// Drops cached revisions and legacy session baselines. Primarily useful for isolated tests.
    public func resetSession() {
        revisionHashes.removeAll()
        legacyTranscodeBaselines.removeAll()
        accessOrder = 0
    }

    private static func expectedIdentity(
        for media: MediaRef,
        sourceURL: URL
    ) -> ExpectedIdentity {
        if let provenance = media.transcodeProvenance {
            if let playableContentHash = provenance.playableContentHash {
                return .durable(playableContentHash)
            }
            return .legacyTranscode(
                LegacyTranscodeKey(
                    mediaID: media.id,
                    sourceURL: sourceURL,
                    originalContentHash: provenance.originalContentHash
                )
            )
        }
        if let contentHash = media.contentHash {
            return .durable(contentHash)
        }
        return .revisionOnly
    }

    private func contentHash(
        for sourceURL: URL,
        revision: MediaSourceRevision
    ) async throws -> ContentHash {
        let key = RevisionHashKey(sourceURL: sourceURL, revision: revision)
        accessOrder &+= 1
        if var cached = revisionHashes[key] {
            cached.accessOrder = accessOrder
            revisionHashes[key] = cached
            return cached.contentHash
        }

        let operation = hashOperation
        let hashingTask = Task.detached(priority: .utility) {
            try operation(sourceURL, { Task.isCancelled })
        }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let hash = try await hashingTask.value
                try Task.checkCancellation()
                return hash
            } onCancel: {
                hashingTask.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MediaSourceIdentityVerificationError.hashingFailed(
                url: sourceURL,
                reason: String(describing: error)
            )
        }
    }

    private func storeRevisionHash(
        _ contentHash: ContentHash,
        sourceURL: URL,
        revision: MediaSourceRevision
    ) {
        let key = RevisionHashKey(sourceURL: sourceURL, revision: revision)
        accessOrder &+= 1
        revisionHashes[key] = RevisionHashEntry(
            contentHash: contentHash,
            accessOrder: accessOrder
        )
        while revisionHashes.count > Self.maximumRevisionHashEntries,
              let oldest = revisionHashes.min(by: {
                  $0.value.accessOrder < $1.value.accessOrder
              }) {
            revisionHashes.removeValue(forKey: oldest.key)
        }
    }

    private func verifyStableRevision(
        _ expectedRevision: MediaSourceRevision,
        for sourceURL: URL
    ) throws {
        let currentRevision: MediaSourceRevision
        do {
            currentRevision = try Self.securityScopedRevision(for: sourceURL)
        } catch {
            throw MediaSourceIdentityVerificationError.sourceChangedDuringRead(sourceURL)
        }
        guard currentRevision == expectedRevision else {
            throw MediaSourceIdentityVerificationError.sourceChangedDuringRead(sourceURL)
        }
    }

    private static func securityScopedRevision(for sourceURL: URL) throws -> MediaSourceRevision {
        guard sourceURL.isFileURL else {
            throw MediaSourceIdentityVerificationError.sourceMustBeFileURL(sourceURL)
        }
        let startedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw MediaSourceIdentityVerificationError.sourceUnavailable(sourceURL)
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        } catch {
            throw MediaSourceIdentityVerificationError.sourceUnavailable(sourceURL)
        }
        return MediaSourceRevision(
            fileSize: (attributes[.size] as? NSNumber)?.uint64Value,
            modificationDate: attributes[.modificationDate] as? Date,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}
