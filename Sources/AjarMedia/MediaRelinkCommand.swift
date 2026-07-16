// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Typed preparation failures before a relink decision can be made.
public enum MediaRelinkCommandError: Error, Equatable, Sendable {
    /// The stable media ID is not present in the project manifest.
    case mediaReferenceNotFound(UUID)

    /// More than one manifest entry uses the requested stable ID.
    case duplicateMediaReferenceID(UUID)

    /// Relink candidates and batch roots must be local file URLs.
    case sourceMustBeFileURL(URL)

    /// A batch relink root does not exist as a readable directory.
    case folderUnavailable(URL)

    /// Candidate hashing failed.
    case hashingFailed(url: URL, reason: String)

    /// A newly accepted source could not receive a security-scoped bookmark.
    case bookmarkCreationFailed(url: URL, reason: String)

    /// Recursive folder enumeration could not be started.
    case folderEnumerationFailed(URL)

    /// The matched original needs FFmpeg before it can become a playable relink target.
    case retranscodeFailed(FFmpegTranscodeError)
}

/// Result of preparing one undoable relink edit.
public enum MediaRelinkPreparation: Equatable, Sendable {
    /// Hash validation (or explicit override) succeeded.
    case ready(command: EditCommand, match: MediaRelinkMatch)

    /// The candidate differs and must be resubmitted with `.override`.
    case warning(MediaRelinkWarning)
}

/// Result of recursively matching offline references by filename and content hash.
public struct MediaBatchRelinkResult: Equatable, Sendable {
    /// One undoable command for every match, or `nil` when nothing matched.
    public let command: EditCommand?

    /// Stable IDs resolved by this scan, in project-manifest order.
    public let relinkedMediaIDs: [UUID]

    /// Offline stable IDs for which no filename-and-hash match was found.
    public let unresolvedMediaIDs: [UUID]

    /// Creates a batch relink result.
    public init(
        command: EditCommand?,
        relinkedMediaIDs: [UUID],
        unresolvedMediaIDs: [UUID]
    ) {
        self.command = command
        self.relinkedMediaIDs = relinkedMediaIDs
        self.unresolvedMediaIDs = unresolvedMediaIDs
    }
}

/// Platform relink workflow: hash/bookmark first, then return a pure `AjarCore` command.
public struct MediaRelinkCommand {
    private let hasher: any MediaFileHashing
    private let bookmarkStore: any MediaBookmarkStore
    private let fileManager: FileManager
    private let ffmpegTranscoder: any FFmpegImportTranscoding

    /// Creates the production relink command.
    public init() {
        self.init(
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: SecurityScopedMediaBookmarkStore(),
            ffmpegTranscoder: SystemFFmpegImportTranscoder(),
            fileManager: .default
        )
    }

    /// Creates a relink command with injectable platform boundaries.
    public init(
        hasher: any MediaFileHashing,
        bookmarkStore: any MediaBookmarkStore,
        ffmpegTranscoder: any FFmpegImportTranscoding = SystemFFmpegImportTranscoder(),
        fileManager: FileManager = .default
    ) {
        self.hasher = hasher
        self.bookmarkStore = bookmarkStore
        self.ffmpegTranscoder = ffmpegTranscoder
        self.fileManager = fileManager
    }

    /// Prepares one relink command from a stable ID and a new file URL.
    ///
    /// `mismatchPolicy` has no default: accepting different bytes must be explicit at every call
    /// site. An override retains the existing import-time metadata/timeline interpretation. The
    /// method performs no project mutation and never touches undo history directly.
    public func prepare(
        mediaReferenceID: UUID,
        newFileURL: URL,
        in project: Project,
        projectPackageURL: URL? = nil,
        mismatchPolicy: MediaRelinkMismatchPolicy
    ) async throws -> MediaRelinkPreparation {
        let matches = project.mediaPool.filter { $0.id == mediaReferenceID }
        guard let media = matches.first else {
            throw MediaRelinkCommandError.mediaReferenceNotFound(mediaReferenceID)
        }
        guard matches.count == 1 else {
            throw MediaRelinkCommandError.duplicateMediaReferenceID(mediaReferenceID)
        }
        guard newFileURL.isFileURL else {
            throw MediaRelinkCommandError.sourceMustBeFileURL(newFileURL)
        }
        let startedSecurityScope = newFileURL.startAccessingSecurityScopedResource()
        defer {
            if startedSecurityScope {
                newFileURL.stopAccessingSecurityScopedResource()
            }
        }

        let contentHash = try preparedContentHash(at: newFileURL)
        let unbookmarkedCandidate = MediaRelinkCandidate(
            sourceURL: newFileURL,
            contentHash: contentHash
        )
        switch media.relinkDecision(
            for: unbookmarkedCandidate,
            mismatchPolicy: mismatchPolicy
        ) {
        case .relinked:
            let bookmark = try preparedBookmark(at: newFileURL)
            let finalCandidate = MediaRelinkCandidate(
                sourceURL: newFileURL,
                contentHash: try preparedContentHash(at: newFileURL),
                bookmark: bookmark
            )
            switch media.relinkDecision(for: finalCandidate, mismatchPolicy: mismatchPolicy) {
            case .relinked(let replacement, let match):
                return .ready(
                    command: .updateMediaReferences(kind: .relink, replacements: [replacement]),
                    match: match
                )
            case .warning(let warning):
                return .warning(warning)
            case .matchedOriginalRequiresTranscode:
                return try await prepareRetranscodedRelink(
                    media: media,
                    originalURL: newFileURL,
                    originalHash: contentHash,
                    projectPackageURL: projectPackageURL
                )
            }
        case .matchedOriginalRequiresTranscode:
            return try await prepareRetranscodedRelink(
                media: media,
                originalURL: newFileURL,
                originalHash: contentHash,
                projectPackageURL: projectPackageURL
            )
        case .warning(let warning):
            return .warning(warning)
        }
    }

    private func prepareRetranscodedRelink(
        media: MediaRef,
        originalURL: URL,
        originalHash: ContentHash,
        projectPackageURL: URL?
    ) async throws -> MediaRelinkPreparation {
        let packageURL = projectPackageURL
            ?? media.sourceURL?.deletingLastPathComponent().deletingLastPathComponent()
        guard let packageURL else {
            throw MediaRelinkCommandError.retranscodeFailed(
                .transactionFailed(reason: "project package URL is unavailable")
            )
        }
        let result: FFmpegTranscodeResult
        do {
            result = try await ffmpegTranscoder.transcode(
                sourceURL: originalURL,
                originalHash: originalHash,
                projectPackageURL: packageURL,
                progress: { _ in }
            )
        } catch let error as FFmpegTranscodeError {
            throw MediaRelinkCommandError.retranscodeFailed(error)
        }
        let playableContentHash = try preparedContentHash(at: result.outputURL)
        let bookmark = try preparedBookmark(at: result.outputURL)
        let replacement = MediaRef(
            id: media.id,
            sourceURL: result.outputURL,
            bookmark: bookmark,
            contentHash: originalHash,
            metadata: media.metadata,
            availability: .available,
            proxyState: .none,
            transcodeProvenance: MediaTranscodeProvenance(
                originalSourceURL: originalURL,
                originalContentHash: originalHash,
                playableContentHash: playableContentHash
            )
        )
        return .ready(
            command: .updateMediaReferences(kind: .relink, replacements: [replacement]),
            match: .contentHash
        )
    }

    /// Recursively matches offline references whose last-known filename **and** hash both match.
    public func prepareBatch(
        folderURL: URL,
        in project: Project
    ) throws -> MediaBatchRelinkResult {
        if let duplicateID = firstDuplicateMediaReferenceID(in: project.mediaPool) {
            throw MediaRelinkCommandError.duplicateMediaReferenceID(duplicateID)
        }
        guard folderURL.isFileURL else {
            throw MediaRelinkCommandError.sourceMustBeFileURL(folderURL)
        }
        let startedSecurityScope = folderURL.startAccessingSecurityScopedResource()
        defer {
            if startedSecurityScope {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        try validateBatchFolder(folderURL)

        let offline = project.mediaPool.filter(\.isOffline)
        let neededFilenames = Set(offline.compactMap { $0.sourceURL?.lastPathComponent })
        let candidates = try recursiveCandidates(
            in: folderURL,
            matchingFilenames: neededFilenames
        )
        let prepared = try preparedBatchRelinks(offline: offline, candidates: candidates)

        let command =
            prepared.replacements.isEmpty
            ? nil
            : EditCommand.updateMediaReferences(
                kind: .batchRelink,
                replacements: prepared.replacements
            )
        return MediaBatchRelinkResult(
            command: command,
            relinkedMediaIDs: prepared.relinkedIDs,
            unresolvedMediaIDs: prepared.unresolvedIDs
        )
    }

    private func preparedBatchRelinks(
        offline: [MediaRef],
        candidates: [String: [HashedCandidate]]
    ) throws -> PreparedBatchRelinks {
        var prepared = PreparedBatchRelinks()
        for media in offline {
            // Batch relink cannot synchronously rebuild fallback working media. Leave these
            // unresolved for the single-item relink flow, which safely re-runs FFmpeg first.
            guard media.transcodeProvenance == nil else {
                prepared.unresolvedIDs.append(media.id)
                continue
            }
            guard
                let filename = media.sourceURL?.lastPathComponent,
                let storedHash = media.contentHash,
                let match = candidates[filename]?.first(where: { candidate in
                    guard candidate.contentHash == storedHash else {
                        return false
                    }
                    return (try? hasher.contentHash(of: candidate.url)) == storedHash
                })
            else {
                prepared.unresolvedIDs.append(media.id)
                continue
            }

            let bookmark = try preparedBookmark(at: match.url)
            prepared.replacements.append(
                media.relinked(
                    to: MediaRelinkCandidate(
                        sourceURL: match.url,
                        contentHash: match.contentHash,
                        bookmark: bookmark
                    )
                )
            )
            prepared.relinkedIDs.append(media.id)
        }
        return prepared
    }

    private func firstDuplicateMediaReferenceID(in media: [MediaRef]) -> UUID? {
        var seen = Set<UUID>()
        for reference in media where !seen.insert(reference.id).inserted {
            return reference.id
        }
        return nil
    }

    private func validateBatchFolder(_ folderURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            fileManager.isReadableFile(atPath: folderURL.path)
        else {
            throw MediaRelinkCommandError.folderUnavailable(folderURL)
        }
    }

    private func preparedContentHash(at url: URL) throws -> ContentHash {
        let hash: ContentHash
        do {
            hash = try hasher.contentHash(of: url)
        } catch {
            throw MediaRelinkCommandError.hashingFailed(
                url: url,
                reason: String(describing: error)
            )
        }
        return hash
    }

    private func preparedBookmark(at url: URL) throws -> Data {
        do {
            return try bookmarkStore.createBookmark(for: url)
        } catch {
            throw MediaRelinkCommandError.bookmarkCreationFailed(
                url: url,
                reason: String(describing: error)
            )
        }
    }

    private struct HashedCandidate {
        let url: URL
        let contentHash: ContentHash
    }

    private struct PreparedBatchRelinks {
        var replacements: [MediaRef] = []
        var relinkedIDs: [UUID] = []
        var unresolvedIDs: [UUID] = []
    }

    private func recursiveCandidates(
        in folderURL: URL,
        matchingFilenames: Set<String>
    ) throws -> [String: [HashedCandidate]] {
        guard !matchingFilenames.isEmpty else {
            return [:]
        }
        guard
            let enumerator = fileManager.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw MediaRelinkCommandError.folderEnumerationFailed(folderURL)
        }

        var fileURLs: [URL] = []
        for case let url as URL in enumerator {
            guard matchingFilenames.contains(url.lastPathComponent) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                continue
            }
            fileURLs.append(url)
        }
        fileURLs.sort { $0.path < $1.path }

        var result: [String: [HashedCandidate]] = [:]
        for url in fileURLs {
            guard let hash = try? hasher.contentHash(of: url) else {
                continue
            }
            result[url.lastPathComponent, default: []].append(
                HashedCandidate(url: url, contentHash: hash)
            )
        }
        return result
    }
}
