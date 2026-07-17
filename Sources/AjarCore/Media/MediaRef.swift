// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Availability of a referenced media source.
public enum MediaAvailability: String, Codable, Hashable, Sendable {
    /// The platform layer last reported the source as available.
    case available

    /// The source is missing or otherwise offline, but the project remains valid.
    case offline
}

/// What the relink workflow should do when a candidate's bytes do not match the stored hash.
public enum MediaRelinkMismatchPolicy: String, Codable, Hashable, Sendable {
    /// Return a typed warning without changing the media reference.
    case warn

    /// Explicitly accept the different bytes and store their new content hash.
    case override
}

/// How a relink candidate matched an existing media reference.
public enum MediaRelinkMatch: String, Codable, Hashable, Sendable {
    /// The content hash matched, so the media can be treated as the same source after a move.
    case contentHash

    /// The original filename matched when no content-hash match was available.
    case filename

    /// The caller explicitly accepted bytes that did not match the stored content hash.
    case overriddenContentHash
}

/// A possible replacement source considered by the relink workflow.
public struct MediaRelinkCandidate: Codable, Hashable, Sendable {
    /// Candidate source URL.
    public let sourceURL: URL

    /// Candidate content hash when available.
    public let contentHash: ContentHash?

    /// Security-scoped bookmark created for the candidate, when available.
    public let bookmark: Data?

    /// Creates a relink candidate.
    public init(sourceURL: URL, contentHash: ContentHash?, bookmark: Data? = nil) {
        self.sourceURL = sourceURL
        self.contentHash = contentHash
        self.bookmark = bookmark
    }
}

/// Why a relink candidate cannot be accepted without an explicit override.
public enum MediaRelinkWarningReason: Equatable, Sendable {
    /// Candidate bytes differ from the hash stored in the project.
    case contentHashMismatch(expected: ContentHash, actual: ContentHash)

    /// The project has no stored hash with which to verify the candidate.
    case storedContentHashUnavailable(actual: ContentHash)

    /// The platform layer did not provide a hash for the candidate.
    case candidateContentHashUnavailable
}

/// Non-blocking warning returned by a relink evaluation.
public struct MediaRelinkWarning: Equatable, Sendable {
    /// Stable media reference being relinked.
    public let mediaID: UUID

    /// Candidate URL whose bytes require confirmation.
    public let candidateURL: URL

    /// Typed reason explicit confirmation is required.
    public let reason: MediaRelinkWarningReason

    /// Creates a relink warning.
    public init(mediaID: UUID, candidateURL: URL, reason: MediaRelinkWarningReason) {
        self.mediaID = mediaID
        self.candidateURL = candidateURL
        self.reason = reason
    }
}

/// Pure `AjarCore` decision for a prepared relink candidate.
public enum MediaRelinkDecision: Equatable, Sendable {
    /// The candidate is accepted and the complete replacement reference is ready to edit in.
    case relinked(MediaRef, match: MediaRelinkMatch)

    /// A fallback import's original bytes matched and must be transcoded before relinking.
    case matchedOriginalRequiresTranscode(MediaRelinkCandidate)

    /// The candidate needs an explicit hash-mismatch override before it may be accepted.
    case warning(MediaRelinkWarning)
}

/// Original-source identity retained when import creates a native working transcode.
public struct MediaTranscodeProvenance: Codable, Hashable, Sendable {
    /// User-selected source before import-boundary transcoding.
    public let originalSourceURL: URL

    /// SHA-256 of the original bytes; this remains the deduplication identity.
    public let originalContentHash: ContentHash

    /// SHA-256 of the playable working transcode stored at `MediaRef.sourceURL`.
    ///
    /// Older projects do not contain this field. Readers deliberately treat that legacy state
    /// as an unknown working identity instead of comparing the transcode with the original hash.
    public let playableContentHash: ContentHash?

    private enum CodingKeys: String, CodingKey {
        case originalSourceURL
        case originalContentHash
        case playableContentHash
    }

    /// Creates durable import provenance.
    public init(
        originalSourceURL: URL,
        originalContentHash: ContentHash,
        playableContentHash: ContentHash? = nil
    ) {
        self.originalSourceURL = originalSourceURL
        self.originalContentHash = originalContentHash
        self.playableContentHash = playableContentHash
    }

    /// Decodes pre-working-hash projects without mistaking the original bytes for playable bytes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        originalSourceURL = try container.decode(URL.self, forKey: .originalSourceURL)
        originalContentHash = try container.decode(ContentHash.self, forKey: .originalContentHash)
        playableContentHash = try container.decodeIfPresent(
            ContentHash.self,
            forKey: .playableContentHash
        )
    }

    /// Encodes both the original identity and the optional playable working identity.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originalSourceURL, forKey: .originalSourceURL)
        try container.encode(originalContentHash, forKey: .originalContentHash)
        try container.encodeIfPresent(playableContentHash, forKey: .playableContentHash)
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

    /// Durable proxy lifecycle state (FR-MED-004). Generation progress is not stored here.
    public let proxyState: MediaProxyState

    /// Original identity when `sourceURL` is an import-boundary working transcode.
    public let transcodeProvenance: MediaTranscodeProvenance?

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceURL
        case bookmark
        case contentHash
        case metadata
        case availability
        case proxyState
        case transcodeProvenance
    }

    /// Creates a stable media reference.
    public init(
        id: UUID,
        sourceURL: URL?,
        bookmark: Data? = nil,
        contentHash: ContentHash?,
        metadata: MediaMetadata,
        availability: MediaAvailability = .available,
        proxyState: MediaProxyState = .none,
        transcodeProvenance: MediaTranscodeProvenance? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.bookmark = bookmark
        self.contentHash = contentHash
        self.metadata = metadata
        self.availability = availability
        self.proxyState = proxyState
        self.transcodeProvenance = transcodeProvenance
    }

    /// Decodes legacy references without availability / proxy keys as available / none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        contentHash = try container.decodeIfPresent(ContentHash.self, forKey: .contentHash)
        metadata = try container.decode(MediaMetadata.self, forKey: .metadata)
        availability =
            try container.decodeIfPresent(
                MediaAvailability.self,
                forKey: .availability
            ) ?? .available
        proxyState =
            try container.decodeIfPresent(MediaProxyState.self, forKey: .proxyState) ?? .none
        transcodeProvenance = try container.decodeIfPresent(
            MediaTranscodeProvenance.self,
            forKey: .transcodeProvenance
        )
    }

    /// Encodes all durable media-reference fields.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encodeIfPresent(bookmark, forKey: .bookmark)
        try container.encodeIfPresent(contentHash, forKey: .contentHash)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(availability, forKey: .availability)
        try container.encode(proxyState, forKey: .proxyState)
        try container.encodeIfPresent(transcodeProvenance, forKey: .transcodeProvenance)
    }

    /// Whether the source is currently offline.
    public var isOffline: Bool {
        availability == .offline
    }

    /// Durable SHA-256 identity for the playable bytes at `sourceURL`, when known.
    ///
    /// Ordinary references play their original bytes. Transcoded references instead play the
    /// working transcode, whose hash is unavailable in projects created before it was persisted.
    public var playableSourceContentHash: ContentHash? {
        guard let transcodeProvenance else {
            return contentHash
        }
        return transcodeProvenance.playableContentHash
    }

    /// Returns the relink match quality for `candidate`, if it can be matched.
    public func relinkMatch(for candidate: MediaRelinkCandidate) -> MediaRelinkMatch? {
        if let contentHash, let candidateHash = candidate.contentHash {
            return candidateHash == contentHash ? .contentHash : nil
        }

        guard sourceURL?.lastPathComponent == candidate.sourceURL.lastPathComponent else {
            return nil
        }

        return .filename
    }

    /// Returns a copy updated to point at the candidate source while preserving the stable ID.
    ///
    /// Relink deliberately preserves probed timeline metadata, including on an explicit hash
    /// override. Import owns metadata probing; relink changes where the existing project media is
    /// read from without silently changing clip duration, frame-rate, or color interpretation.
    public func relinked(to candidate: MediaRelinkCandidate) -> MediaRef {
        if let provenance = transcodeProvenance,
           candidate.contentHash == provenance.originalContentHash {
            // The original is not itself a playable replacement. The typed decision API sends
            // it through FFmpeg; direct callers remain safely unchanged.
            return self
        }
        // Relink invalidates any prior proxy of the old bytes; reset to `.none` so generation
        // re-runs against the new source (FR-MED-004 / FR-MED-007).
        return MediaRef(
            id: id,
            sourceURL: candidate.sourceURL,
            bookmark: candidate.bookmark,
            contentHash: candidate.contentHash ?? contentHash,
            metadata: metadata,
            availability: .available,
            proxyState: .none,
            transcodeProvenance: nil
        )
    }

    /// Returns a copy pointing at a same-bytes consolidated package-media destination.
    ///
    /// Unlike ``relinked(to:)``, **preserves** `proxyState`: consolidate copies hash-validated
    /// byte-identical media into `.ajar/media/`, so an existing ready proxy remains valid
    /// (FR-MED-004 / FR-MED-008). Genuine relink of different bytes still uses ``relinked(to:)``.
    public func consolidated(to candidate: MediaRelinkCandidate) -> MediaRef {
        MediaRef(
            id: id,
            sourceURL: candidate.sourceURL,
            bookmark: candidate.bookmark,
            contentHash: candidate.contentHash ?? contentHash,
            metadata: metadata,
            availability: .available,
            proxyState: proxyState,
            transcodeProvenance: transcodeProvenance
        )
    }

    /// Evaluates a prepared relink candidate without performing platform I/O.
    public func relinkDecision(
        for candidate: MediaRelinkCandidate,
        mismatchPolicy: MediaRelinkMismatchPolicy
    ) -> MediaRelinkDecision {
        guard let actualHash = candidate.contentHash else {
            return .warning(
                MediaRelinkWarning(
                    mediaID: id,
                    candidateURL: candidate.sourceURL,
                    reason: .candidateContentHashUnavailable
                )
            )
        }

        if let provenance = transcodeProvenance,
           provenance.originalContentHash == actualHash {
            return .matchedOriginalRequiresTranscode(candidate)
        }

        if let contentHash, contentHash == actualHash {
            return .relinked(relinked(to: candidate), match: .contentHash)
        }

        let warningReason: MediaRelinkWarningReason
        if let contentHash {
            warningReason = .contentHashMismatch(expected: contentHash, actual: actualHash)
        } else {
            warningReason = .storedContentHashUnavailable(actual: actualHash)
        }

        guard mismatchPolicy == .override else {
            return .warning(
                MediaRelinkWarning(
                    mediaID: id,
                    candidateURL: candidate.sourceURL,
                    reason: warningReason
                )
            )
        }

        return .relinked(relinked(to: candidate), match: .overriddenContentHash)
    }

    /// Returns a copy with a platform-reported availability state.
    public func withAvailability(_ availability: MediaAvailability) -> MediaRef {
        MediaRef(
            id: id,
            sourceURL: sourceURL,
            bookmark: bookmark,
            contentHash: contentHash,
            metadata: metadata,
            availability: availability,
            proxyState: proxyState,
            transcodeProvenance: transcodeProvenance
        )
    }

    /// Returns a copy with an updated durable proxy lifecycle state (FR-MED-004).
    public func withProxyState(_ proxyState: MediaProxyState) -> MediaRef {
        MediaRef(
            id: id,
            sourceURL: sourceURL,
            bookmark: bookmark,
            contentHash: contentHash,
            metadata: metadata,
            availability: availability,
            proxyState: proxyState,
            transcodeProvenance: transcodeProvenance
        )
    }
}

public extension Project {
    /// Returns a project snapshot with platform-reported availability applied by stable ID.
    ///
    /// This is a pure state transition. Filesystem/bookmark probing remains in `AjarMedia`.
    func updatingMediaAvailability(
        _ availability: MediaAvailability,
        for mediaIDs: Set<UUID>
    ) -> Project {
        Project(
            schemaVersion: schemaVersion,
            schemaMinor: schemaMinor,
            settings: settings,
            mediaPool: mediaPool.map { media in
                mediaIDs.contains(media.id) ? media.withAvailability(availability) : media
            },
            sequences: sequences,
            looks: looks
        )
    }

    /// Returns a project snapshot with durable proxy state applied by stable ID (FR-MED-004).
    func updatingMediaProxyState(
        _ proxyState: MediaProxyState,
        for mediaIDs: Set<UUID>
    ) -> Project {
        Project(
            schemaVersion: schemaVersion,
            schemaMinor: schemaMinor,
            settings: settings,
            mediaPool: mediaPool.map { media in
                mediaIDs.contains(media.id) ? media.withProxyState(proxyState) : media
            },
            sequences: sequences,
            looks: looks
        )
    }

    /// Returns a project snapshot with the project-level proxy playback preference set.
    func updatingPreferProxyPlayback(_ preferProxyPlayback: Bool) -> Project {
        Project(
            schemaVersion: schemaVersion,
            schemaMinor: schemaMinor,
            settings: settings.withPreferProxyPlayback(preferProxyPlayback),
            mediaPool: mediaPool,
            sequences: sequences,
            looks: looks
        )
    }
}
