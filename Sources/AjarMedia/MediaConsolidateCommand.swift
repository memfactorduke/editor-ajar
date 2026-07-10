// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// One progress update from media consolidation.
public struct ConsolidateProgressUpdate: Equatable, Sendable {
    /// Number of manifest entries successfully prepared so far.
    public let completedFileCount: Int

    /// Total number of manifest entries considered by this run.
    public let totalFileCount: Int

    /// Stable media ID most recently completed, absent for the initial zero update.
    public let mediaID: UUID?

    /// Published package URL most recently completed, absent for the initial zero update.
    public let destinationURL: URL?

    /// Creates a progress update.
    public init(
        completedFileCount: Int,
        totalFileCount: Int,
        mediaID: UUID?,
        destinationURL: URL?
    ) {
        self.completedFileCount = completedFileCount
        self.totalFileCount = totalFileCount
        self.mediaID = mediaID
        self.destinationURL = destinationURL
    }
}

/// Small callback surface designed for adoption by the future background queue (#216).
public protocol ConsolidateProgress: AnyObject {
    /// Called once at zero and after each successfully published/reference-ready file.
    func consolidateDidUpdate(_ progress: ConsolidateProgressUpdate)
}

/// Typed preflight failures that occur before any original is copied.
public enum MediaConsolidateCommandError: Error, Equatable, Sendable {
    /// Read-only projects cannot be changed; this is checked before package I/O begins.
    case projectOpenedReadOnly(AjarProjectReadOnlyReason)

    /// Consolidation refuses an ambiguous manifest before creating or copying anything.
    case duplicateMediaReferenceID(UUID)

    /// A `.ajar` package must be a local file URL.
    case packageMustBeFileURL(URL)

    /// The supplied package directory does not exist.
    case packageDirectoryUnavailable(URL)

    /// The package's `media/` directory could not be created.
    case mediaDirectoryCreationFailed(url: URL, reason: String)

    /// The package's `media` entry is not a real directory (for example, it is a symlink).
    case unsafeMediaDirectory(URL)
}

/// Why one original could not complete consolidation.
public enum MediaConsolidateFailureReason: Equatable, Sendable {
    /// The original was offline or otherwise unresolvable.
    case sourceResolutionFailed(MediaReferenceResolutionFailure)

    /// Source bytes changed since the project stored its identity hash.
    case sourceContentHashMismatch(expected: ContentHash, actual: ContentHash)

    /// Source hashing failed.
    case hashingFailed(url: URL, reason: String)

    /// Consolidation only accepts a real file, never a directory or symbolic link.
    case sourceNotRegularFile(URL)

    /// Copied bytes did not match the source identity and were not published.
    case copiedContentHashMismatch(expected: ContentHash, actual: ContentHash)

    /// Temp-copy or atomic publication failed.
    case copyFailed(sourceURL: URL, destinationURL: URL, reason: String)

    /// The copied file could not receive a new security-scoped bookmark.
    case bookmarkCreationFailed(url: URL, reason: String)
}

/// Per-file failure returned alongside any earlier successful publications.
public struct MediaConsolidateFailure: Error, Equatable, Sendable {
    /// Stable ID of the reference that failed.
    public let mediaID: UUID

    /// Typed failure reason.
    public let reason: MediaConsolidateFailureReason

    /// Creates a consolidation failure.
    public init(mediaID: UUID, reason: MediaConsolidateFailureReason) {
        self.mediaID = mediaID
        self.reason = reason
    }
}

/// Prepared consolidation outcome.
public struct MediaConsolidateResult: Equatable, Sendable {
    /// One undoable rewrite for every successfully prepared reference.
    ///
    /// On a partial failure, applying this command makes earlier published files the active
    /// references while the failed and unattempted entries remain unchanged.
    public let command: EditCommand?

    /// Package media URLs successfully published or safely reused.
    public let publishedFileURLs: [URL]

    /// Stable IDs corresponding to `publishedFileURLs`.
    public let consolidatedMediaIDs: [UUID]

    /// First per-file failure, if the batch stopped early.
    public let failure: MediaConsolidateFailure?

    /// Whether every referenced original completed.
    public var isComplete: Bool {
        failure == nil
    }

    /// Creates a consolidation result.
    public init(
        command: EditCommand?,
        publishedFileURLs: [URL],
        consolidatedMediaIDs: [UUID],
        failure: MediaConsolidateFailure?
    ) {
        self.command = command
        self.publishedFileURLs = publishedFileURLs
        self.consolidatedMediaIDs = consolidatedMediaIDs
        self.failure = failure
    }
}

/// Copies originals into `<project>.ajar/media/` and prepares one undoable reference rewrite.
public struct MediaConsolidateCommand {
    private let resolver: MediaReferenceResolver
    private let hasher: any MediaFileHashing
    private let bookmarkStore: any MediaBookmarkStore
    private let fileOperations: any ConsolidateFileOperations
    private let fileManager: FileManager

    /// Creates the production consolidate command.
    public init() {
        let bookmarkStore = SecurityScopedMediaBookmarkStore()
        let fileManager = FileManager.default
        self.init(
            resolver: MediaReferenceResolver(
                bookmarkStore: bookmarkStore,
                fileManager: fileManager
            ),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: bookmarkStore,
            fileOperations: DefaultConsolidateFileOperations(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    init(
        resolver: MediaReferenceResolver,
        hasher: any MediaFileHashing,
        bookmarkStore: any MediaBookmarkStore,
        fileOperations: any ConsolidateFileOperations,
        fileManager: FileManager = .default
    ) {
        self.resolver = resolver
        self.hasher = hasher
        self.bookmarkStore = bookmarkStore
        self.fileOperations = fileOperations
        self.fileManager = fileManager
    }

    /// Copies each source through a same-directory temporary file, publishing atomically.
    ///
    /// Source files are only read. A partial failure leaves earlier copies in place and returns
    /// a command for those successful references; undo restores old references and never removes
    /// copied files.
    public func prepare(
        project: Project,
        openMode: AjarProjectOpenMode,
        projectPackageURL: URL,
        progress: (any ConsolidateProgress)? = nil
    ) throws -> MediaConsolidateResult {
        if let duplicateID = firstDuplicateMediaReferenceID(in: project.mediaPool) {
            throw MediaConsolidateCommandError.duplicateMediaReferenceID(duplicateID)
        }
        if case .readOnly(let reason) = openMode {
            throw MediaConsolidateCommandError.projectOpenedReadOnly(reason)
        }
        guard projectPackageURL.isFileURL else {
            throw MediaConsolidateCommandError.packageMustBeFileURL(projectPackageURL)
        }
        let startedPackageScope = projectPackageURL.startAccessingSecurityScopedResource()
        defer {
            if startedPackageScope {
                projectPackageURL.stopAccessingSecurityScopedResource()
            }
        }
        let mediaDirectory = try prepareMediaDirectory(
            packageURL: projectPackageURL,
            openMode: openMode
        )
        let total = project.mediaPool.count
        reportInitialProgress(total: total, progress: progress)

        var prepared: [PreparedConsolidation] = []
        for media in project.mediaPool {
            switch prepareMedia(media, mediaDirectory: mediaDirectory) {
            case .success(let item):
                prepared.append(item)
                progress?.consolidateDidUpdate(
                    ConsolidateProgressUpdate(
                        completedFileCount: prepared.count,
                        totalFileCount: total,
                        mediaID: media.id,
                        destinationURL: item.destinationURL
                    )
                )
            case .failure(let failure):
                return makeResult(prepared: prepared, failure: failure)
            }
        }
        return makeResult(prepared: prepared, failure: nil)
    }

    private func firstDuplicateMediaReferenceID(in media: [MediaRef]) -> UUID? {
        var seen = Set<UUID>()
        for reference in media where !seen.insert(reference.id).inserted {
            return reference.id
        }
        return nil
    }

    private func prepareMediaDirectory(
        packageURL: URL,
        openMode: AjarProjectOpenMode
    ) throws -> URL {
        if case .readOnly(let reason) = openMode {
            throw MediaConsolidateCommandError.projectOpenedReadOnly(reason)
        }
        guard packageURL.isFileURL else {
            throw MediaConsolidateCommandError.packageMustBeFileURL(packageURL)
        }
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw MediaConsolidateCommandError.packageDirectoryUnavailable(packageURL)
        }

        let mediaDirectory = packageURL.appendingPathComponent("media", isDirectory: true)
        do {
            try fileOperations.createDirectory(at: mediaDirectory)
        } catch {
            throw MediaConsolidateCommandError.mediaDirectoryCreationFailed(
                url: mediaDirectory,
                reason: String(describing: error)
            )
        }
        do {
            guard try fileOperations.isDirectory(at: mediaDirectory) else {
                throw MediaConsolidateCommandError.unsafeMediaDirectory(mediaDirectory)
            }
        } catch let error as MediaConsolidateCommandError {
            throw error
        } catch {
            throw MediaConsolidateCommandError.mediaDirectoryCreationFailed(
                url: mediaDirectory,
                reason: String(describing: error)
            )
        }
        return mediaDirectory
    }

    private func reportInitialProgress(
        total: Int,
        progress: (any ConsolidateProgress)?
    ) {
        progress?.consolidateDidUpdate(
            ConsolidateProgressUpdate(
                completedFileCount: 0,
                totalFileCount: total,
                mediaID: nil,
                destinationURL: nil
            )
        )
    }

    private func prepareMedia(
        _ media: MediaRef,
        mediaDirectory: URL
    ) -> Result<PreparedConsolidation, MediaConsolidateFailure> {
        do {
            return .success(try prepareMediaThrowing(media, mediaDirectory: mediaDirectory))
        } catch let failure as MediaConsolidateFailure {
            return .failure(failure)
        } catch {
            return .failure(missingSourceFailure(for: media))
        }
    }

    private func prepareMediaThrowing(
        _ media: MediaRef,
        mediaDirectory: URL
    ) throws -> PreparedConsolidation {
        let resolved = try resolvedMedia(media)
        let actualHash = try validatedHash(for: media, sourceURL: resolved.sourceURL)
        let destinationURL = try publishedDestination(
            for: media,
            sourceURL: resolved.sourceURL,
            contentHash: actualHash,
            mediaDirectory: mediaDirectory
        )
        let replacement = try bookmarkedReplacement(
            resolved.reference,
            mediaID: media.id,
            destinationURL: destinationURL,
            contentHash: actualHash
        )
        return PreparedConsolidation(reference: replacement, destinationURL: destinationURL)
    }

    private func resolvedMedia(_ media: MediaRef) throws -> ResolvedConsolidation {
        switch resolver.resolve(media) {
        case .resolved(let reference, let sourceURL):
            return ResolvedConsolidation(reference: reference, sourceURL: sourceURL)
        case .offline(_, let failure):
            throw MediaConsolidateFailure(
                mediaID: media.id,
                reason: .sourceResolutionFailed(failure)
            )
        }
    }

    private func validatedHash(
        for media: MediaRef,
        sourceURL: URL
    ) throws -> ContentHash {
        let actualHash: ContentHash
        do {
            actualHash = try hasher.contentHash(of: sourceURL)
        } catch {
            throw MediaConsolidateFailure(
                mediaID: media.id,
                reason: .hashingFailed(url: sourceURL, reason: String(describing: error))
            )
        }
        if let expected = media.contentHash, expected != actualHash {
            throw MediaConsolidateFailure(
                mediaID: media.id,
                reason: .sourceContentHashMismatch(expected: expected, actual: actualHash)
            )
        }
        return actualHash
    }

    private func publishedDestination(
        for media: MediaRef,
        sourceURL: URL,
        contentHash: ContentHash,
        mediaDirectory: URL
    ) throws -> URL {
        do {
            return try ConsolidatePublisher(
                hasher: hasher,
                fileOperations: fileOperations
            ).publish(
                sourceURL: sourceURL,
                mediaID: media.id,
                contentHash: contentHash,
                mediaDirectory: mediaDirectory
            )
        } catch let copyFailure as ConsolidateCopyFailure {
            let reason: MediaConsolidateFailureReason
            switch copyFailure.reason {
            case .sourceNotRegularFile(let url):
                reason = .sourceNotRegularFile(url)
            case .copiedContentHashMismatch(let expected, let actual):
                reason = .copiedContentHashMismatch(expected: expected, actual: actual)
            case .temporaryNotRegularFile, .operationFailed:
                reason = .copyFailed(
                    sourceURL: sourceURL,
                    destinationURL: copyFailure.destinationURL,
                    reason: String(describing: copyFailure.reason)
                )
            }
            throw MediaConsolidateFailure(
                mediaID: media.id,
                reason: reason
            )
        } catch {
            throw MediaConsolidateFailure(
                mediaID: media.id,
                reason: .copyFailed(
                    sourceURL: sourceURL,
                    destinationURL: mediaDirectory,
                    reason: String(describing: error)
                )
            )
        }
    }

    private func bookmarkedReplacement(
        _ resolved: MediaRef,
        mediaID: UUID,
        destinationURL: URL,
        contentHash: ContentHash
    ) throws -> MediaRef {
        do {
            let bookmark = try bookmarkStore.createBookmark(for: destinationURL)
            return resolved.relinked(
                to: MediaRelinkCandidate(
                    sourceURL: destinationURL,
                    contentHash: contentHash,
                    bookmark: bookmark
                )
            )
        } catch {
            throw MediaConsolidateFailure(
                mediaID: mediaID,
                reason: .bookmarkCreationFailed(
                    url: destinationURL,
                    reason: String(describing: error)
                )
            )
        }
    }

    private func missingSourceFailure(for media: MediaRef) -> MediaConsolidateFailure {
        return MediaConsolidateFailure(
            mediaID: media.id,
            reason: .sourceResolutionFailed(
                .sourceMissing(mediaID: media.id, lastKnownURL: media.sourceURL)
            )
        )
    }

    private func makeResult(
        prepared: [PreparedConsolidation],
        failure: MediaConsolidateFailure?
    ) -> MediaConsolidateResult {
        let replacements = prepared.map(\.reference)
        let command =
            prepared.isEmpty
            ? nil
            : EditCommand.updateMediaReferences(kind: .consolidate, replacements: replacements)
        return MediaConsolidateResult(
            command: command,
            publishedFileURLs: prepared.map(\.destinationURL),
            consolidatedMediaIDs: prepared.map(\.reference.id),
            failure: failure
        )
    }
}

private struct PreparedConsolidation {
    let reference: MediaRef
    let destinationURL: URL
}

private struct ResolvedConsolidation {
    let reference: MediaRef
    let sourceURL: URL
}
