// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CryptoKit
import Foundation

/// Platform boundary for hashing source files without loading them wholly into memory.
public protocol MediaFileHashing {
    /// Computes the SHA-256 hash of a local file's bytes.
    func contentHash(of fileURL: URL) throws -> ContentHash

    /// Computes the hash while cooperatively checking for cancellation between 1 MiB reads.
    func contentHash(
        of fileURL: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> ContentHash
}

public extension MediaFileHashing {
    func contentHash(
        of fileURL: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> ContentHash {
        if isCancelled() {
            throw CancellationError()
        }
        let hash = try contentHash(of: fileURL)
        if isCancelled() {
            throw CancellationError()
        }
        return hash
    }
}

/// Typed file-hashing failures.
public enum MediaFileHashError: Error, Equatable, Sendable {
    /// The candidate is not a local file URL.
    case sourceMustBeFileURL(URL)

    /// The candidate cannot be opened or read.
    case readFailed(url: URL, reason: String)

    /// The platform digest could not be represented as an `AjarCore.ContentHash`.
    case invalidDigest(String)
}

/// Streaming SHA-256 implementation used by relink and consolidate.
public struct SHA256MediaFileHasher: MediaFileHashing, Sendable {
    private static let readChunkSize = 1_048_576

    /// Creates the production file hasher.
    public init() {}

    /// Streams the file into a SHA-256 digest.
    public func contentHash(of fileURL: URL) throws -> ContentHash {
        try contentHash(of: fileURL, isCancelled: { false })
    }

    /// Streams the file into a SHA-256 digest while checking for cooperative cancellation.
    public func contentHash(
        of fileURL: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> ContentHash {
        guard fileURL.isFileURL else {
            throw MediaFileHashError.sourceMustBeFileURL(fileURL)
        }
        let startedSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if startedSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw MediaFileHashError.readFailed(
                url: fileURL,
                reason: String(describing: error)
            )
        }

        defer {
            try? handle.close()
        }

        var digest = CryptoKit.SHA256()
        do {
            if isCancelled() {
                throw CancellationError()
            }
            while true {
                if isCancelled() {
                    throw CancellationError()
                }
                guard let data = try handle.read(upToCount: Self.readChunkSize), !data.isEmpty
                else {
                    break
                }
                if isCancelled() {
                    throw CancellationError()
                }
                digest.update(data: data)
            }
            if isCancelled() {
                throw CancellationError()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MediaFileHashError.readFailed(
                url: fileURL,
                reason: String(describing: error)
            )
        }

        let hexadecimal = digest.finalize().map { String(format: "%02x", $0) }.joined()
        do {
            return try ContentHash(digest: hexadecimal)
        } catch {
            throw MediaFileHashError.invalidDigest(hexadecimal)
        }
    }
}
