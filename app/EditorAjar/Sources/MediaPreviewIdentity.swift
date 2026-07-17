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
