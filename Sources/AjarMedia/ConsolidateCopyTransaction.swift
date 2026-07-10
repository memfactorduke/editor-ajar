// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

protocol ConsolidateFileOperations {
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) throws -> Bool
    func isRegularFile(at url: URL) throws -> Bool
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func removeItem(at url: URL) throws
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

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSFilePathErrorKey: destinationURL.path]
            )
        }

        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? sourceHandle.close() }
        let destinationHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? destinationHandle.close() }
        while let bytes = try sourceHandle.read(upToCount: 1_024 * 1_024), !bytes.isEmpty {
            try destinationHandle.write(contentsOf: bytes)
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
    case sourceNotRegularFile(URL)
    case temporaryNotRegularFile(URL)
    case copiedContentHashMismatch(expected: ContentHash, actual: ContentHash)
    case operationFailed(String)
}

struct ConsolidateCopyFailure: Error {
    let destinationURL: URL
    let reason: ConsolidateCopyFailureReason
}

struct ConsolidatePublisher {
    let hasher: any MediaFileHashing
    let fileOperations: any ConsolidateFileOperations

    func publish(
        sourceURL: URL,
        mediaID: UUID,
        contentHash: ContentHash,
        mediaDirectory: URL
    ) throws -> URL {
        let started = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if started {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        return try publishOrReuse(
            sourceURL: sourceURL,
            mediaID: mediaID,
            contentHash: contentHash,
            mediaDirectory: mediaDirectory
        )
    }

    private func publishOrReuse(
        sourceURL: URL,
        mediaID: UUID,
        contentHash: ContentHash,
        mediaDirectory: URL
    ) throws -> URL {
        try validateRegularSource(sourceURL, mediaDirectory: mediaDirectory)
        if let existing = try existingConsolidatedSource(
            sourceURL,
            contentHash: contentHash,
            mediaDirectory: mediaDirectory
        ) {
            return existing
        }

        var collisionIndex = 0
        while true {
            let destinationURL = consolidatedURL(
                sourceURL: sourceURL,
                mediaID: mediaID,
                collisionIndex: collisionIndex,
                mediaDirectory: mediaDirectory
            )
            if fileOperations.fileExists(at: destinationURL) {
                if (try? fileOperations.isRegularFile(at: destinationURL)) == true,
                    (try? hasher.contentHash(of: destinationURL)) == contentHash {
                    return destinationURL
                }
                collisionIndex += 1
                continue
            }
            try publish(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                contentHash: contentHash
            )
            return destinationURL
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
        mediaDirectory: URL
    ) throws -> URL? {
        guard
            sourceURL.deletingLastPathComponent().standardizedFileURL
                == mediaDirectory.standardizedFileURL
        else {
            return nil
        }
        do {
            let actualHash = try hasher.contentHash(of: sourceURL)
            guard actualHash == contentHash else {
                throw ConsolidateCopyFailure(
                    destinationURL: sourceURL,
                    reason: .copiedContentHashMismatch(expected: contentHash, actual: actualHash)
                )
            }
            return sourceURL
        } catch let failure as ConsolidateCopyFailure {
            throw failure
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
        contentHash: ContentHash
    ) throws {
        let transaction = ConsolidateCopyTransaction(
            destinationURL: destinationURL,
            fileOperations: fileOperations
        )
        do {
            try transaction.copyAndCommit(
                from: sourceURL,
                expectedHash: contentHash,
                hasher: hasher
            )
        } catch let reason as ConsolidateCopyFailureReason {
            try? transaction.cleanUp()
            throw ConsolidateCopyFailure(destinationURL: destinationURL, reason: reason)
        } catch {
            try? transaction.cleanUp()
            throw ConsolidateCopyFailure(
                destinationURL: destinationURL,
                reason: .operationFailed(String(describing: error))
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

final class ConsolidateCopyTransaction {
    private let destinationURL: URL
    private let temporaryURL: URL
    private let fileOperations: any ConsolidateFileOperations
    private var committed = false

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
        hasher: any MediaFileHashing
    ) throws {
        try fileOperations.copyItem(at: sourceURL, to: temporaryURL)
        guard try fileOperations.isRegularFile(at: temporaryURL) else {
            throw ConsolidateCopyFailureReason.temporaryNotRegularFile(temporaryURL)
        }
        let copiedHash = try hasher.contentHash(of: temporaryURL)
        guard copiedHash == expectedHash else {
            throw ConsolidateCopyFailureReason.copiedContentHashMismatch(
                expected: expectedHash,
                actual: copiedHash
            )
        }
        try fileOperations.moveItem(at: temporaryURL, to: destinationURL)
        committed = true
    }

    func cleanUp() throws {
        guard !committed, fileOperations.fileExists(at: temporaryURL) else {
            return
        }
        try fileOperations.removeItem(at: temporaryURL)
    }
}
