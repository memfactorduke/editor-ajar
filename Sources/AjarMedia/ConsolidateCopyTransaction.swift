// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Darwin
import Foundation

protocol ConsolidateFileOperations {
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) throws -> Bool
    func isRegularFile(at url: URL) throws -> Bool
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
    func copyItem(
        at sourceURL: URL,
        to destinationURL: URL,
        isCancelled: @escaping @Sendable () -> Bool,
        didCreate: (ConsolidateFileIdentity) -> Void,
        progress: @escaping (_ copiedByteCount: Int64, _ totalByteCount: Int64) -> Void
    ) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func synchronizeDirectory(at url: URL) throws
    func removeItem(at url: URL) throws
    func removeOwnedPartial(
        at url: URL,
        expectedIdentity: ConsolidateFileIdentity?,
        finalRemovalGuard: ((ConsolidateFileIdentity) throws -> Void)?
    ) throws -> Bool
}

extension ConsolidateFileOperations {
    func removeOwnedPartial(
        at url: URL,
        expectedIdentity: ConsolidateFileIdentity?,
        finalRemovalGuard: ((ConsolidateFileIdentity) throws -> Void)?
    ) throws -> Bool {
        try ConsolidateStalePartialRemover(finalRemovalGuard: finalRemovalGuard).removeRegularFile(
            at: url,
            expectedIdentity: expectedIdentity
        )
    }

    func synchronizeDirectory(at url: URL) throws {
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )
    }

    func copyItem(
        at sourceURL: URL,
        to destinationURL: URL,
        isCancelled: @escaping @Sendable () -> Bool,
        didCreate: (ConsolidateFileIdentity) -> Void,
        progress: @escaping (_ copiedByteCount: Int64, _ totalByteCount: Int64) -> Void
    ) throws {
        if isCancelled() {
            throw CancellationError()
        }
        try copyItem(at: sourceURL, to: destinationURL)
        let identity = try ConsolidateFileIdentity.withoutFollowingSymlinks(at: destinationURL)
        didCreate(identity)
        if isCancelled() {
            throw CancellationError()
        }
        progress(1, 1)
    }
}

struct DefaultConsolidateFileOperations: ConsolidateFileOperations {
    let fileManager: FileManager

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func isRegularFile(at url: URL) throws -> Bool {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    func isDirectory(at url: URL) throws -> Bool {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try copyItem(
            at: sourceURL,
            to: destinationURL,
            isCancelled: { false },
            didCreate: { _ in },
            progress: { _, _ in }
        )
    }

    func copyItem(
        at sourceURL: URL,
        to destinationURL: URL,
        isCancelled: @escaping @Sendable () -> Bool,
        didCreate: (ConsolidateFileIdentity) -> Void,
        progress: @escaping (_ copiedByteCount: Int64, _ totalByteCount: Int64) -> Void
    ) throws {
        let descriptor = destinationURL.path.withCString { path in
            Darwin.open(
                path,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: destinationURL.path]
            )
        }

        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        didCreate(ConsolidateFileIdentity(information))

        let destinationHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? destinationHandle.close() }
        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? sourceHandle.close() }
        let totalByteCount = Int64(try sourceHandle.seekToEnd())
        try sourceHandle.seek(toOffset: 0)
        var copiedByteCount: Int64 = 0
        progress(0, totalByteCount)
        if isCancelled() {
            throw CancellationError()
        }
        while true {
            if isCancelled() {
                throw CancellationError()
            }
            guard let bytes = try sourceHandle.read(upToCount: 1_024 * 1_024), !bytes.isEmpty else {
                break
            }
            if isCancelled() {
                throw CancellationError()
            }
            try destinationHandle.write(contentsOf: bytes)
            copiedByteCount += Int64(bytes.count)
            progress(copiedByteCount, totalByteCount)
        }
        if isCancelled() {
            throw CancellationError()
        }
        try destinationHandle.synchronize()
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}

enum ConsolidateCopyFailureReason: Error {
    case cancelled
    case partialCleanupFailed(url: URL, reason: String)
    case publicationSyncFailed(destinationURL: URL, reason: String)
    case sourceNotRegularFile(URL)
    case temporaryNotRegularFile(URL)
    case copiedContentHashMismatch(expected: ContentHash, actual: ContentHash)
    case operationFailed(String)
}

struct ConsolidateCopyFailure: Error {
    let destinationURL: URL
    let reason: ConsolidateCopyFailureReason
}

struct ConsolidatePublishRequest {
    let sourceURL: URL
    let mediaID: UUID
    let contentHash: ContentHash
    let mediaDirectory: URL
    let isCancelled: @Sendable () -> Bool
    let copyProgress: (_ copiedByteCount: Int64, _ totalByteCount: Int64) -> Void
}

struct ConsolidatePublisher {
    let hasher: any MediaFileHashing
    let fileOperations: any ConsolidateFileOperations

    func publish(_ request: ConsolidatePublishRequest) throws -> URL {
        let started = request.sourceURL.startAccessingSecurityScopedResource()
        defer {
            if started {
                request.sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        return try publishOrReuse(request)
    }

    private func publishOrReuse(_ request: ConsolidatePublishRequest) throws -> URL {
        try validateRegularSource(request.sourceURL, mediaDirectory: request.mediaDirectory)
        if request.isCancelled() {
            throw ConsolidateCopyFailure(
                destinationURL: request.mediaDirectory,
                reason: .cancelled
            )
        }
        if let existing = try existingConsolidatedSource(
            request.sourceURL,
            contentHash: request.contentHash,
            mediaDirectory: request.mediaDirectory,
            isCancelled: request.isCancelled
        ) {
            try throwIfCancelled(request, destinationURL: existing)
            try synchronizeReusedDestination(existing, request: request)
            try throwIfCancelled(request, destinationURL: existing)
            return existing
        }

        var collisionIndex = 0
        while true {
            try throwIfCancelled(request, destinationURL: request.mediaDirectory)
            let destinationURL = consolidatedURL(
                sourceURL: request.sourceURL,
                mediaID: request.mediaID,
                collisionIndex: collisionIndex,
                mediaDirectory: request.mediaDirectory
            )
            if fileOperations.fileExists(at: destinationURL) {
                if try reusableCollision(at: destinationURL, request: request) {
                    try synchronizeReusedDestination(destinationURL, request: request)
                    try throwIfCancelled(request, destinationURL: destinationURL)
                    return destinationURL
                }
                collisionIndex += 1
                continue
            }
            try publish(
                sourceURL: request.sourceURL,
                destinationURL: destinationURL,
                contentHash: request.contentHash,
                isCancelled: request.isCancelled,
                copyProgress: request.copyProgress
            )
            return destinationURL
        }
    }

    private func reusableCollision(
        at destinationURL: URL,
        request: ConsolidatePublishRequest
    ) throws -> Bool {
        let isRegular: Bool
        do {
            isRegular = try fileOperations.isRegularFile(at: destinationURL)
        } catch {
            throw ConsolidateCopyFailure(
                destinationURL: destinationURL,
                reason: .operationFailed(String(describing: error))
            )
        }
        guard isRegular else { return false }

        let candidateHash: ContentHash
        do {
            candidateHash = try hasher.contentHash(
                of: destinationURL,
                isCancelled: request.isCancelled
            )
        } catch is CancellationError {
            throw ConsolidateCopyFailure(destinationURL: destinationURL, reason: .cancelled)
        } catch {
            throw ConsolidateCopyFailure(
                destinationURL: destinationURL,
                reason: .operationFailed(String(describing: error))
            )
        }
        try throwIfCancelled(request, destinationURL: destinationURL)
        return candidateHash == request.contentHash
    }

    private func throwIfCancelled(
        _ request: ConsolidatePublishRequest,
        destinationURL: URL
    ) throws {
        if request.isCancelled() {
            throw ConsolidateCopyFailure(destinationURL: destinationURL, reason: .cancelled)
        }
    }

    private func synchronizeReusedDestination(
        _ destinationURL: URL,
        request: ConsolidatePublishRequest
    ) throws {
        do {
            try fileOperations.synchronizeDirectory(at: request.mediaDirectory)
        } catch {
            throw ConsolidateCopyFailure(
                destinationURL: destinationURL,
                reason: .publicationSyncFailed(
                    destinationURL: destinationURL,
                    reason: String(describing: error)
                )
            )
        }
    }

    private func validateRegularSource(_ sourceURL: URL, mediaDirectory: URL) throws {
        do {
            guard try fileOperations.isRegularFile(at: sourceURL) else {
                throw ConsolidateCopyFailure(
                    destinationURL: mediaDirectory,
                    reason: .sourceNotRegularFile(sourceURL)
                )
            }
        } catch let failure as ConsolidateCopyFailure {
            throw failure
        } catch {
            throw ConsolidateCopyFailure(
                destinationURL: mediaDirectory,
                reason: .operationFailed(String(describing: error))
            )
        }
    }

    private func existingConsolidatedSource(
        _ sourceURL: URL,
        contentHash: ContentHash,
        mediaDirectory: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> URL? {
        guard
            sourceURL.deletingLastPathComponent().standardizedFileURL
                == mediaDirectory.standardizedFileURL
        else {
            return nil
        }
        do {
            let actualHash = try hasher.contentHash(
                of: sourceURL,
                isCancelled: isCancelled
            )
            if isCancelled() {
                throw CancellationError()
            }
            guard actualHash == contentHash else {
                throw ConsolidateCopyFailure(
                    destinationURL: sourceURL,
                    reason: .copiedContentHashMismatch(expected: contentHash, actual: actualHash)
                )
            }
            return sourceURL
        } catch let failure as ConsolidateCopyFailure {
            throw failure
        } catch is CancellationError {
            throw ConsolidateCopyFailure(destinationURL: sourceURL, reason: .cancelled)
        } catch {
            throw ConsolidateCopyFailure(
                destinationURL: sourceURL,
                reason: .operationFailed(String(describing: error))
            )
        }
    }

    private func publish(
        sourceURL: URL,
        destinationURL: URL,
        contentHash: ContentHash,
        isCancelled: @escaping @Sendable () -> Bool,
        copyProgress: @escaping (_ copiedByteCount: Int64, _ totalByteCount: Int64) -> Void
    ) throws {
        let transaction = ConsolidateCopyTransaction(
            destinationURL: destinationURL,
            fileOperations: fileOperations
        )
        do {
            try transaction.copyAndCommit(
                from: sourceURL,
                expectedHash: contentHash,
                hasher: hasher,
                isCancelled: isCancelled,
                progress: copyProgress
            )
        } catch is CancellationError {
            throw cleanupAwareFailure(
                transaction: transaction,
                destinationURL: destinationURL,
                reason: .cancelled
            )
        } catch let reason as ConsolidateCopyFailureReason {
            throw cleanupAwareFailure(
                transaction: transaction,
                destinationURL: destinationURL,
                reason: reason
            )
        } catch {
            throw cleanupAwareFailure(
                transaction: transaction,
                destinationURL: destinationURL,
                reason: .operationFailed(String(describing: error))
            )
        }
    }

    private func cleanupAwareFailure(
        transaction: ConsolidateCopyTransaction,
        destinationURL: URL,
        reason: ConsolidateCopyFailureReason
    ) -> ConsolidateCopyFailure {
        do {
            try transaction.cleanUp()
            return ConsolidateCopyFailure(destinationURL: destinationURL, reason: reason)
        } catch {
            return ConsolidateCopyFailure(
                destinationURL: destinationURL,
                reason: .partialCleanupFailed(
                    url: transaction.temporaryFileURL,
                    reason: String(describing: error)
                )
            )
        }
    }

    private func consolidatedURL(
        sourceURL: URL,
        mediaID: UUID,
        collisionIndex: Int,
        mediaDirectory: URL
    ) -> URL {
        let collisionSuffix = collisionIndex == 0 ? "" : "-\(collisionIndex)"
        let filename = "\(mediaID.uuidString.lowercased())\(collisionSuffix)"
            + safeExtensionSuffix(for: sourceURL)
        return mediaDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    private func safeExtensionSuffix(for sourceURL: URL) -> String {
        let candidate = sourceURL.pathExtension.lowercased()
        guard
            !candidate.isEmpty,
            candidate.utf8.count <= 16,
            candidate.unicodeScalars.allSatisfy({ scalar in
                scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
            })
        else {
            return ""
        }
        return ".\(candidate)"
    }
}
