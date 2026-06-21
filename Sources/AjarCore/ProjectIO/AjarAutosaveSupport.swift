// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Errors from auto-save package persistence.
public enum AjarAutosaveStoreError: Error, Equatable, Sendable {
    /// A required package file was missing.
    case missingPackageFile(String)

    /// A package file could not be read.
    case fileReadFailed(path: String, reason: String)

    /// A package file could not be written atomically.
    case atomicWriteFailed(path: String, reason: String)

    /// A manifest or journal could not be encoded.
    case encodingFailed(String)

    /// A manifest could not be decoded.
    case malformedManifest(String)

    /// The atomic recovery snapshot could not be decoded.
    case malformedSnapshot(String)
}

/// Prepared temp-file replacement used to make durable writes explicit and testable.
public struct AjarAtomicWriteTransaction: Equatable, Sendable {
    /// Temporary file containing the new bytes.
    public let temporaryURL: URL

    /// Final destination to replace.
    public let destinationURL: URL

    /// Atomically commits the temporary file over the destination.
    public func commit(fileManager: FileManager = .default) throws {
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            throw AjarAutosaveStoreError.atomicWriteFailed(
                path: destinationURL.path,
                reason: String(describing: error)
            )
        }
    }

    /// Removes the temporary file without touching the destination.
    public func cancel(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            return
        }
        try fileManager.removeItem(at: temporaryURL)
    }
}

/// Low-level atomic file replacement.
public enum AjarAtomicFileWriter {
    /// Writes bytes to a temporary file next to `destinationURL` without replacing the destination.
    public static func prepareWrite(
        _ data: Data,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> AjarAtomicWriteTransaction {
        let directoryURL = destinationURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let temporaryURL = directoryURL.appendingPathComponent(
                ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
            )
            try data.write(to: temporaryURL)
            return AjarAtomicWriteTransaction(
                temporaryURL: temporaryURL,
                destinationURL: destinationURL
            )
        } catch let error as AjarAutosaveStoreError {
            throw error
        } catch {
            throw AjarAutosaveStoreError.atomicWriteFailed(
                path: destinationURL.path,
                reason: String(describing: error)
            )
        }
    }

    /// Writes bytes by preparing and committing a same-directory temporary replacement.
    public static func write(
        _ data: Data,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try prepareWrite(data, to: destinationURL, fileManager: fileManager)
            .commit(fileManager: fileManager)
    }
}

/// Codec for the append-only command journal.
public enum AjarAutosaveJournalCodec {
    /// Encodes journal entries as newline-delimited canonical JSON.
    public static func encode(_ entries: [AjarAutosaveJournalEntry]) throws -> Data {
        var data = Data()
        for entry in entries {
            data.append(try encodeLine(entry))
        }
        return data
    }

    /// Encodes one journal entry plus its trailing newline.
    public static func encodeLine(_ entry: AjarAutosaveJournalEntry) throws -> Data {
        do {
            var data = try encoder().encode(entry)
            data.append(0x0A)
            return data
        } catch {
            throw AjarAutosaveStoreError.encodingFailed(String(describing: error))
        }
    }

    static func decodeLine(_ lineData: Data) throws -> AjarAutosaveJournalEntry {
        try decoder().decode(AjarAutosaveJournalEntry.self, from: lineData)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
