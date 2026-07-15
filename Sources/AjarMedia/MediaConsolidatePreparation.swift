// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

struct ConsolidatePreparationContext {
    let mediaDirectory: URL
    let completedFileCount: Int
    let totalFileCount: Int
    let progress: (any ConsolidateProgress)?
    let isCancelled: @Sendable () -> Bool
}

struct PreparedConsolidation {
    let reference: MediaRef
    let destinationURL: URL
    let byteCount: Int64
}

private struct ConsolidateProtectedSourceAlias {
    let mediaID: UUID
    let url: URL
    let objectIdentity: ConsolidateObjectIdentity
}

struct ConsolidateProtectedMediaSources {
    var urls = Set<URL>()
    var identities = Set<ConsolidateObjectIdentity>()
    private var aliases: [ConsolidateProtectedSourceAlias] = []
    private let identityProvider: (URL) throws -> ConsolidateFileIdentity?

    init(identityProvider: @escaping (URL) throws -> ConsolidateFileIdentity?) {
        self.identityProvider = identityProvider
    }

    mutating func addAlias(
        mediaID: UUID,
        url: URL,
        identity: ConsolidateFileIdentity
    ) {
        urls.insert(url.standardizedFileURL)
        identities.insert(identity.objectIdentity)
        aliases.append(
            ConsolidateProtectedSourceAlias(
                mediaID: mediaID,
                url: url,
                objectIdentity: identity.objectIdentity
            )
        )
    }

    func revalidateBeforeRemoving(_ candidate: ConsolidateFileIdentity) throws {
        for alias in aliases {
            let started = alias.url.startAccessingSecurityScopedResource()
            defer {
                if started {
                    alias.url.stopAccessingSecurityScopedResource()
                }
            }
            let current: ConsolidateFileIdentity?
            do {
                current = try identityProvider(alias.url)
            } catch {
                throw cleanupFailure(
                    for: alias,
                    reason: "protected source could not be revalidated: \(error)"
                )
            }
            guard let current else {
                throw cleanupFailure(
                    for: alias,
                    reason: "protected source disappeared during cleanup"
                )
            }
            if current.objectIdentity == candidate.objectIdentity {
                throw cleanupFailure(
                    for: alias,
                    reason: "stale candidate became a referenced source"
                )
            }
            guard current.objectIdentity == alias.objectIdentity else {
                throw cleanupFailure(
                    for: alias,
                    reason: "protected source changed during cleanup"
                )
            }
        }
    }

    private func cleanupFailure(
        for alias: ConsolidateProtectedSourceAlias,
        reason: String
    ) -> MediaConsolidateCommandError {
        .stalePartialCleanupFailed(
            url: alias.url,
            mediaID: alias.mediaID,
            reason: reason
        )
    }
}

private struct ResolvedConsolidation {
    let reference: MediaRef
    let sourceURL: URL
}

extension MediaConsolidateCommand {
    func firstDuplicateMediaReferenceID(in media: [MediaRef]) -> UUID? {
        var seen = Set<UUID>()
        for reference in media where !seen.insert(reference.id).inserted {
            return reference.id
        }
        return nil
    }

    func prepareMediaDirectory(
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
        do {
            try fileOperations.synchronizeDirectory(at: packageURL)
        } catch {
            throw MediaConsolidateCommandError.mediaDirectoryCreationFailed(
                url: mediaDirectory,
                reason: "project package synchronization failed: \(error)"
            )
        }
        return mediaDirectory
    }

    func protectedMediaSources(in project: Project) throws -> ConsolidateProtectedMediaSources {
        var protected = ConsolidateProtectedMediaSources(
            identityProvider: protectedSourceIdentity
        )
        for media in project.mediaPool {
            var protectedURLCount = 0
            if let bookmark = media.bookmark {
                let resolvedURL: URL
                do {
                    resolvedURL = try bookmarkStore.resolveBookmark(bookmark).url
                } catch {
                    throw MediaConsolidateCommandError.protectedSourceUnavailable(
                        mediaID: media.id,
                        url: media.sourceURL,
                        reason: "bookmark URL could not be established: \(error)"
                    )
                }
                guard resolvedURL.isFileURL else {
                    throw MediaConsolidateCommandError.protectedSourceUnavailable(
                        mediaID: media.id,
                        url: resolvedURL,
                        reason: "bookmark did not resolve to a local file"
                    )
                }
                try protect(resolvedURL, mediaID: media.id, in: &protected)
                protectedURLCount += 1
            }
            if let sourceURL = media.sourceURL {
                guard sourceURL.isFileURL else {
                    throw MediaConsolidateCommandError.protectedSourceUnavailable(
                        mediaID: media.id,
                        url: sourceURL,
                        reason: "last-known source is not a local file"
                    )
                }
                try protect(sourceURL, mediaID: media.id, in: &protected)
                protectedURLCount += 1
            }
            guard protectedURLCount > 0 else {
                throw MediaConsolidateCommandError.protectedSourceUnavailable(
                    mediaID: media.id,
                    url: nil,
                    reason: "reference has no source URL or resolvable bookmark"
                )
            }
        }
        return protected
    }

    private func protect(
        _ url: URL,
        mediaID: UUID,
        in protected: inout ConsolidateProtectedMediaSources
    ) throws {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            guard let identity = try protectedSourceIdentity(url) else {
                throw MediaConsolidateCommandError.protectedSourceUnavailable(
                    mediaID: mediaID,
                    url: url,
                    reason: "referenced source identity could not be established"
                )
            }
            protected.addAlias(mediaID: mediaID, url: url, identity: identity)
        } catch let error as MediaConsolidateCommandError {
            throw error
        } catch {
            throw MediaConsolidateCommandError.protectedSourceUnavailable(
                mediaID: mediaID,
                url: url,
                reason: String(describing: error)
            )
        }
    }

    func removeStalePartialFiles(
        from mediaDirectory: URL,
        protecting protected: ConsolidateProtectedMediaSources
    ) throws {
        let candidates: [URL]
        do {
            candidates = try fileOperations.contentsOfDirectory(at: mediaDirectory)
        } catch {
            throw MediaConsolidateCommandError.stalePartialCleanupFailed(
                url: mediaDirectory,
                mediaID: nil,
                reason: String(describing: error)
            )
        }

        for candidate in candidates {
            guard isOwnedConsolidatePartialFileName(candidate.lastPathComponent) else { continue }
            guard !protected.urls.contains(candidate.standardizedFileURL) else { continue }
            let inspectedIdentity: ConsolidateFileIdentity
            do {
                inspectedIdentity = try ConsolidateFileIdentity.withoutFollowingSymlinks(
                    at: candidate
                )
                guard !protected.identities.contains(inspectedIdentity.objectIdentity) else {
                    continue
                }
            } catch {
                throw MediaConsolidateCommandError.stalePartialCleanupFailed(
                    url: candidate,
                    mediaID: nil,
                    reason: String(describing: error)
                )
            }
            do {
                _ = try fileOperations.removeOwnedPartial(
                    at: candidate,
                    expectedIdentity: inspectedIdentity,
                    finalRemovalGuard: protected.revalidateBeforeRemoving
                )
            } catch let error as MediaConsolidateCommandError {
                throw error
            } catch {
                throw MediaConsolidateCommandError.stalePartialCleanupFailed(
                    url: candidate,
                    mediaID: nil,
                    reason: String(describing: error)
                )
            }
        }
    }

    func recoverInterruptedPartialCleanup(from mediaDirectory: URL) throws {
        do {
            try ConsolidateStalePartialRemover().recoverInterruptedRemovals(
                in: mediaDirectory
            )
        } catch {
            throw MediaConsolidateCommandError.stalePartialCleanupFailed(
                url: (error as? ConsolidateStalePartialRemovalError)?.affectedURL
                    ?? mediaDirectory,
                mediaID: nil,
                reason: String(describing: error)
            )
        }
    }

    func reportInitialProgress(total: Int, progress: (any ConsolidateProgress)?) {
        progress?.consolidateDidUpdate(
            ConsolidateProgressUpdate(
                completedFileCount: 0,
                totalFileCount: total,
                mediaID: nil,
                destinationURL: nil
            )
        )
    }

    func prepareMedia(
        _ media: MediaRef,
        context: ConsolidatePreparationContext
    ) -> Result<PreparedConsolidation, MediaConsolidateFailure> {
        do {
            return .success(try prepareMediaThrowing(media, context: context))
        } catch let failure as MediaConsolidateFailure {
            return .failure(failure)
        } catch {
            return .failure(missingSourceFailure(for: media))
        }
    }

    private func prepareMediaThrowing(
        _ media: MediaRef,
        context: ConsolidatePreparationContext
    ) throws -> PreparedConsolidation {
        let resolved = try resolvedMedia(media)
        let actualHash = try validatedHash(
            for: media,
            sourceURL: resolved.sourceURL,
            isCancelled: context.isCancelled
        )
        var copiedByteCount: Int64 = 0
        var totalByteCount: Int64 = 0
        let publication = ConsolidatePublishRequest(
            sourceURL: resolved.sourceURL,
            mediaID: media.id,
            contentHash: actualHash,
            mediaDirectory: context.mediaDirectory,
            isCancelled: context.isCancelled,
            copyProgress: { copied, total in
                copiedByteCount = copied
                totalByteCount = total
                context.progress?.consolidateDidUpdate(
                    ConsolidateProgressUpdate(
                        completedFileCount: context.completedFileCount,
                        totalFileCount: context.totalFileCount,
                        mediaID: media.id,
                        destinationURL: nil,
                        copiedByteCount: copied,
                        totalByteCount: total
                    )
                )
            }
        )
        let destinationURL = try publishedDestination(for: media, request: publication)
        let replacement = try bookmarkedReplacement(
            resolved.reference,
            mediaID: media.id,
            destinationURL: destinationURL,
            contentHash: actualHash
        )
        return PreparedConsolidation(
            reference: replacement,
            destinationURL: destinationURL,
            byteCount: max(copiedByteCount, totalByteCount)
        )
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
        sourceURL: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> ContentHash {
        let actualHash: ContentHash
        do {
            actualHash = try hasher.contentHash(of: sourceURL, isCancelled: isCancelled)
        } catch is CancellationError {
            throw MediaConsolidateFailure(mediaID: media.id, reason: .cancelled)
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
        request: ConsolidatePublishRequest
    ) throws -> URL {
        do {
            return try ConsolidatePublisher(
                hasher: hasher,
                fileOperations: fileOperations
            ).publish(request)
        } catch let copyFailure as ConsolidateCopyFailure {
            throw MediaConsolidateFailure(
                mediaID: media.id,
                reason: copyFailureReason(copyFailure, sourceURL: request.sourceURL)
            )
        } catch {
            throw MediaConsolidateFailure(
                mediaID: media.id,
                reason: .copyFailed(
                    sourceURL: request.sourceURL,
                    destinationURL: request.mediaDirectory,
                    reason: String(describing: error)
                )
            )
        }
    }

    private func copyFailureReason(
        _ failure: ConsolidateCopyFailure,
        sourceURL: URL
    ) -> MediaConsolidateFailureReason {
        switch failure.reason {
        case .cancelled:
            return .cancelled
        case .partialCleanupFailed(let url, let reason):
            return .partialCleanupFailed(url: url, reason: reason)
        case .publicationSyncFailed(let destinationURL, let reason):
            return .publicationSyncFailed(
                destinationURL: destinationURL,
                reason: reason
            )
        case .sourceNotRegularFile(let url):
            return .sourceNotRegularFile(url)
        case .copiedContentHashMismatch(let expected, let actual):
            return .copiedContentHashMismatch(expected: expected, actual: actual)
        case .temporaryNotRegularFile, .operationFailed:
            return .copyFailed(
                sourceURL: sourceURL,
                destinationURL: failure.destinationURL,
                reason: String(describing: failure.reason)
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
            return resolved.consolidated(
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

}
