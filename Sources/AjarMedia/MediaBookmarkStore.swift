// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A resolved security-scoped bookmark and its staleness flag.
public struct MediaBookmarkResolution: Equatable, Sendable {
    /// File URL recovered from the bookmark.
    public let url: URL

    /// Whether the bookmark should be recreated before the next save.
    public let isStale: Bool

    /// Creates a bookmark resolution value.
    public init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }
}

/// Platform boundary for creating and resolving media bookmarks.
public protocol MediaBookmarkStore {
    /// Creates security-scoped bookmark bytes for a file URL.
    func createBookmark(for url: URL) throws -> Data

    /// Resolves previously stored bookmark bytes.
    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution
}

/// Typed failures from the macOS bookmark boundary.
public enum MediaBookmarkError: Error, Equatable, Sendable {
    /// Only local file URLs can be stored as project media bookmarks.
    case sourceMustBeFileURL(URL)

    /// Foundation could not create bookmark bytes.
    case creationFailed(url: URL, reason: String)

    /// Foundation could not resolve bookmark bytes.
    case resolutionFailed(reason: String)
}

/// macOS security-scoped bookmark implementation required by ADR-0007.
public struct SecurityScopedMediaBookmarkStore: MediaBookmarkStore, Sendable {
    /// Creates the production bookmark store.
    public init() {}

    public func createBookmark(for url: URL) throws -> Data {
        guard url.isFileURL else {
            throw MediaBookmarkError.sourceMustBeFileURL(url)
        }

        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw MediaBookmarkError.creationFailed(
                url: url,
                reason: String(describing: error)
            )
        }
    }

    public func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return MediaBookmarkResolution(url: url, isStale: isStale)
        } catch {
            throw MediaBookmarkError.resolutionFailed(reason: String(describing: error))
        }
    }
}
