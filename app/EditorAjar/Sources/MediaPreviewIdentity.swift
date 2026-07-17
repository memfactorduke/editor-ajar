// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import Foundation

extension MediaPreviewCache {
    /// Resolves the playable source identity once, before a request is started.
    func contentIdentity(for media: MediaRef) async throws -> MediaPreviewContentIdentity {
        if let contentIdentityResolver {
            return try await contentIdentityResolver(media)
        }
        return try Self.resolveContentIdentity(for: media)
    }

    nonisolated static func resolveContentIdentity(
        for media: MediaRef
    ) throws -> MediaPreviewContentIdentity {
        if let contentHash = media.playableSourceContentHash {
            return .durable(contentHash)
        }
        guard media.transcodeProvenance != nil else {
            throw MediaPreviewCacheError.missingHash
        }
        guard let sourceURL = media.sourceURL else {
            throw MediaPreviewCacheError.missingSourceURL
        }
        guard !media.isOffline else {
            throw MediaSourceIdentityVerificationError.sourceOffline(
                mediaID: media.id,
                sourceURL: sourceURL
            )
        }
        let standardizedURL = standardizedSourceURL(sourceURL)
        let revision = try MediaSourceIdentityVerifier.sourceRevision(for: standardizedURL)
        return .legacyTranscode(sourceURL: standardizedURL, revision: revision)
    }

    func validate(
        identity: MediaPreviewContentIdentity,
        for media: MediaRef
    ) throws {
        try Self.validate(identity: identity, for: media)
    }

    /// Verifies that a durable cache identity still describes the bytes at this media's URL.
    ///
    /// Two references may legitimately share a content hash, but each URL must independently
    /// prove that it contains those bytes before it can reuse or join the shared cache request.
    func verifiedDurableSource(
        identity: MediaPreviewContentIdentity,
        for media: MediaRef
    ) async throws -> VerifiedMediaSource? {
        try Self.validate(identity: identity, for: media)
        guard case .durable(let expectedContentHash) = identity else { return nil }
        let verifiedSource = try await MediaSourceIdentityVerifier.shared.verifyBeforeReading(media)
        guard verifiedSource.playableContentHash == expectedContentHash else {
            throw MediaPreviewCacheError.contentIdentityMismatch
        }
        return verifiedSource
    }

    /// Refuses a cache result when its request's durable source changed while work was in flight.
    func validateDurableSourceAfterReading(
        _ verifiedSource: VerifiedMediaSource?
    ) async throws {
        guard let verifiedSource else { return }
        try await MediaSourceIdentityVerifier.shared.verifyAfterReading(verifiedSource)
    }

    nonisolated static func validate(
        identity: MediaPreviewContentIdentity,
        for media: MediaRef
    ) throws {
        switch identity {
        case .durable(let contentHash):
            guard media.playableSourceContentHash == contentHash else {
                throw MediaPreviewCacheError.contentIdentityMismatch
            }
        case .legacyTranscode(let sourceURL, let revision):
            guard media.transcodeProvenance != nil,
                media.playableSourceContentHash == nil,
                media.sourceURL.map(standardizedSourceURL) == sourceURL
            else {
                throw MediaPreviewCacheError.contentIdentityMismatch
            }
            let currentRevision = try MediaSourceIdentityVerifier.sourceRevision(for: sourceURL)
            guard currentRevision == revision else {
                throw MediaSourceIdentityVerificationError.sourceChangedDuringRead(sourceURL)
            }
        }
    }

    nonisolated static func standardizedSourceURL(_ sourceURL: URL) -> URL {
        sourceURL.isFileURL ? sourceURL.standardizedFileURL : sourceURL.standardized
    }
}
