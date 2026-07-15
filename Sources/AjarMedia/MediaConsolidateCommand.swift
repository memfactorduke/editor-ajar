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

    /// Bytes copied for the file currently being prepared.
    public let copiedByteCount: Int64

    /// Exact source byte count for the file currently being prepared.
    public let totalByteCount: Int64

    /// Creates a progress update.
    public init(
        completedFileCount: Int,
        totalFileCount: Int,
        mediaID: UUID?,
        destinationURL: URL?,
        copiedByteCount: Int64 = 0,
        totalByteCount: Int64 = 0
    ) {
        self.completedFileCount = completedFileCount
        self.totalFileCount = totalFileCount
        self.mediaID = mediaID
        self.destinationURL = destinationURL
        self.copiedByteCount = copiedByteCount
        self.totalByteCount = totalByteCount
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

    /// A stale transaction file could not be removed safely before copying began.
    case stalePartialCleanupFailed(url: URL, mediaID: UUID?, reason: String)

    /// A referenced source or bookmark could not be identified safely before stale cleanup.
    case protectedSourceUnavailable(mediaID: UUID, url: URL?, reason: String)

    /// Another command or process is already consolidating this package.
    case packageBusy(URL)

    /// The package consolidation lock could not be opened safely.
    case packageLockFailed(url: URL, reason: String)
}

/// Why one original could not complete consolidation.
public enum MediaConsolidateFailureReason: Equatable, Sendable {
    /// The user cancelled before this file could be published.
    case cancelled

    /// An unpublished transaction file could not be removed after cancellation or failure.
    case partialCleanupFailed(url: URL, reason: String)
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

    /// The copy was atomically published, but its directory entry could not be made durable.
    case publicationSyncFailed(destinationURL: URL, reason: String)

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
    let resolver: MediaReferenceResolver
    let hasher: any MediaFileHashing
    let bookmarkStore: any MediaBookmarkStore
    let fileOperations: any ConsolidateFileOperations
    let fileManager: FileManager
    let packageLocking: any ConsolidatePackageLocking
    let protectedSourceIdentity: (URL) throws -> ConsolidateFileIdentity?

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
            fileManager: fileManager,
            packageLocking: POSIXConsolidatePackageLocking()
        )
    }

    /// Creates a command with an injected bookmark boundary and production filesystem safety.
    public init(
        bookmarkStore: any MediaBookmarkStore,
        hasher: any MediaFileHashing = SHA256MediaFileHasher()
    ) {
        let fileManager = FileManager.default
        self.init(
            resolver: MediaReferenceResolver(
                bookmarkStore: bookmarkStore,
                fileManager: fileManager
            ),
            hasher: hasher,
            bookmarkStore: bookmarkStore,
            fileOperations: DefaultConsolidateFileOperations(fileManager: fileManager),
            fileManager: fileManager,
            packageLocking: POSIXConsolidatePackageLocking()
        )
    }

    init(
        resolver: MediaReferenceResolver,
        hasher: any MediaFileHashing,
        bookmarkStore: any MediaBookmarkStore,
        fileOperations: any ConsolidateFileOperations,
        fileManager: FileManager = .default,
        packageLocking: any ConsolidatePackageLocking = POSIXConsolidatePackageLocking(),
        protectedSourceIdentity: @escaping (URL) throws -> ConsolidateFileIdentity? =
            ConsolidateFileIdentity.followingSymlinks
    ) {
        self.resolver = resolver
        self.hasher = hasher
        self.bookmarkStore = bookmarkStore
        self.fileOperations = fileOperations
        self.fileManager = fileManager
        self.packageLocking = packageLocking
        self.protectedSourceIdentity = protectedSourceIdentity
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
        progress: (any ConsolidateProgress)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> MediaConsolidateResult {
        try validateRequest(project, openMode: openMode, projectPackageURL: projectPackageURL)
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
        let packageLock = try acquirePackageLock(
            mediaDirectory: mediaDirectory,
            projectPackageURL: projectPackageURL
        )
        defer { packageLock.release() }
        try recoverInterruptedPartialCleanup(from: mediaDirectory)
        let protectedSources = try protectedMediaSources(in: project)
        try removeStalePartialFiles(
            from: mediaDirectory,
            protecting: protectedSources
        )
        let total = project.mediaPool.count
        reportInitialProgress(total: total, progress: progress)

        var prepared: [PreparedConsolidation] = []
        for media in project.mediaPool {
            if isCancelled() {
                return makeResult(
                    prepared: prepared,
                    failure: MediaConsolidateFailure(mediaID: media.id, reason: .cancelled)
                )
            }
            switch prepareMedia(
                media,
                context: ConsolidatePreparationContext(
                    mediaDirectory: mediaDirectory,
                    completedFileCount: prepared.count,
                    totalFileCount: total,
                    progress: progress,
                    isCancelled: isCancelled
                )
            ) {
            case .success(let item):
                prepared.append(item)
                progress?.consolidateDidUpdate(
                    ConsolidateProgressUpdate(
                        completedFileCount: prepared.count,
                        totalFileCount: total,
                        mediaID: media.id,
                        destinationURL: item.destinationURL,
                        copiedByteCount: item.byteCount,
                        totalByteCount: item.byteCount
                    )
                )
            case .failure(let failure):
                return makeResult(prepared: prepared, failure: failure)
            }
        }
        return makeResult(prepared: prepared, failure: nil)
    }

    private func acquirePackageLock(
        mediaDirectory: URL,
        projectPackageURL: URL
    ) throws -> any ConsolidatePackageLock {
        do {
            return try packageLocking.acquire(mediaDirectory: mediaDirectory)
        } catch ConsolidatePackageLockError.busy {
            throw MediaConsolidateCommandError.packageBusy(projectPackageURL)
        } catch {
            throw MediaConsolidateCommandError.packageLockFailed(
                url: projectPackageURL,
                reason: String(describing: error)
            )
        }
    }

    private func validateRequest(
        _ project: Project,
        openMode: AjarProjectOpenMode,
        projectPackageURL: URL
    ) throws {
        if let duplicateID = firstDuplicateMediaReferenceID(in: project.mediaPool) {
            throw MediaConsolidateCommandError.duplicateMediaReferenceID(duplicateID)
        }
        if case .readOnly(let reason) = openMode {
            throw MediaConsolidateCommandError.projectOpenedReadOnly(reason)
        }
        guard projectPackageURL.isFileURL else {
            throw MediaConsolidateCommandError.packageMustBeFileURL(projectPackageURL)
        }
    }

}
