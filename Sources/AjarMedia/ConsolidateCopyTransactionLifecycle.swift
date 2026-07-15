// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

final class ConsolidateCopyTransaction {
    private let destinationURL: URL
    private let temporaryURL: URL
    private let fileOperations: any ConsolidateFileOperations
    private var committed = false
    private var temporaryIdentity: ConsolidateFileIdentity?

    var temporaryFileURL: URL { temporaryURL }

    init(destinationURL: URL, fileOperations: any ConsolidateFileOperations) {
        self.destinationURL = destinationURL
        self.fileOperations = fileOperations
        temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".ajar-partial-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
    }

    func copyAndCommit(
        from sourceURL: URL,
        expectedHash: ContentHash,
        hasher: any MediaFileHashing,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping (_ copiedByteCount: Int64, _ totalByteCount: Int64) -> Void
    ) throws {
        try fileOperations.copyItem(
            at: sourceURL,
            to: temporaryURL,
            isCancelled: isCancelled,
            didCreate: { temporaryIdentity = $0 },
            progress: progress
        )
        if isCancelled() {
            throw CancellationError()
        }
        guard try fileOperations.isRegularFile(at: temporaryURL) else {
            throw ConsolidateCopyFailureReason.temporaryNotRegularFile(temporaryURL)
        }
        let copiedHash = try hasher.contentHash(of: temporaryURL, isCancelled: isCancelled)
        guard copiedHash == expectedHash else {
            throw ConsolidateCopyFailureReason.copiedContentHashMismatch(
                expected: expectedHash,
                actual: copiedHash
            )
        }
        if isCancelled() {
            throw CancellationError()
        }
        try fileOperations.moveItem(at: temporaryURL, to: destinationURL)
        committed = true
        do {
            try fileOperations.synchronizeDirectory(
                at: destinationURL.deletingLastPathComponent()
            )
        } catch {
            throw ConsolidateCopyFailureReason.publicationSyncFailed(
                destinationURL: destinationURL,
                reason: String(describing: error)
            )
        }
    }

    func cleanUp() throws {
        guard !committed, fileOperations.fileExists(at: temporaryURL) else {
            return
        }
        guard let temporaryIdentity else {
            throw ConsolidateStalePartialRemovalError.ownershipUnavailable(temporaryURL)
        }
        let removed = try fileOperations.removeOwnedPartial(
            at: temporaryURL,
            expectedIdentity: temporaryIdentity,
            finalRemovalGuard: nil
        )
        guard removed else {
            throw ConsolidateStalePartialRemovalError.unsafeEntryChanged(temporaryURL)
        }
    }
}
