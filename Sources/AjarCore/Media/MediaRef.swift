// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Availability of a referenced media source.
public enum MediaAvailability: String, Codable, Hashable, Sendable {
    /// The platform layer last reported the source as available.
    case available

    /// The source is missing or otherwise offline, but the project remains valid.
    case offline
}

/// How a relink candidate matched an existing media reference.
public enum MediaRelinkMatch: String, Codable, Hashable, Sendable {
    /// The content hash matched, so the media can be treated as the same source after a move.
    case contentHash

    /// The original filename matched when no content-hash match was available.
    case filename
}

/// A possible replacement source considered by the relink workflow.
public struct MediaRelinkCandidate: Codable, Hashable, Sendable {
    /// Candidate source URL.
    public let sourceURL: URL

    /// Candidate content hash when available.
    public let contentHash: ContentHash?

    /// Creates a relink candidate.
    public init(sourceURL: URL, contentHash: ContentHash?) {
        self.sourceURL = sourceURL
        self.contentHash = contentHash
    }
}

/// A stable reference to original media in a project.
///
/// `MediaRef` stores identity and metadata only. It does not probe files, read files, create
/// security-scoped bookmarks, or copy media; those are platform/module responsibilities.
public struct MediaRef: Codable, Hashable, Sendable {
    /// Stable ID used by clips, manifests, and relinking.
    public let id: UUID

    /// Last-known source URL. Media is referenced in place by default.
    public let sourceURL: URL?

    /// Opaque bookmark bytes created by a platform module, if available.
    public let bookmark: Data?

    /// Hash of the original media bytes when available.
    public let contentHash: ContentHash?

    /// Probed metadata for the source.
    public let metadata: MediaMetadata

    /// Current availability state as last reported by a platform module.
    public let availability: MediaAvailability

    /// Creates a stable media reference.
    public init(
        id: UUID,
        sourceURL: URL?,
        bookmark: Data? = nil,
        contentHash: ContentHash?,
        metadata: MediaMetadata,
        availability: MediaAvailability = .available
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.bookmark = bookmark
        self.contentHash = contentHash
        self.metadata = metadata
        self.availability = availability
    }

    /// Whether the source is currently offline.
    public var isOffline: Bool {
        availability == .offline
    }

    /// Returns the relink match quality for `candidate`, if it can be matched.
    public func relinkMatch(for candidate: MediaRelinkCandidate) -> MediaRelinkMatch? {
        if let contentHash, candidate.contentHash == contentHash {
            return .contentHash
        }

        guard sourceURL?.lastPathComponent == candidate.sourceURL.lastPathComponent else {
            return nil
        }

        return .filename
    }

    /// Returns a copy updated to point at the candidate source while preserving the stable ID.
    public func relinked(to candidate: MediaRelinkCandidate) -> MediaRef {
        MediaRef(
            id: id,
            sourceURL: candidate.sourceURL,
            bookmark: bookmark,
            contentHash: candidate.contentHash ?? contentHash,
            metadata: metadata,
            availability: .available
        )
    }
}
