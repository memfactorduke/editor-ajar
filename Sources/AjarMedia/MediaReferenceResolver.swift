// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Typed reason a media reference could not be resolved without blocking project open.
public enum MediaReferenceResolutionFailure: Error, Equatable, Sendable {
    /// Neither a bookmark nor a last-known URL identifies an existing file.
    case sourceMissing(mediaID: UUID, lastKnownURL: URL?)

    /// Bookmark resolution failed and the last-known URL was not usable.
    case bookmarkResolutionFailed(mediaID: UUID)

    /// A source exists but is not readable by this process.
    case sourceUnreadable(mediaID: UUID, url: URL)
}

/// Non-throwing resolution result for one durable media reference.
public enum MediaReferenceResolution: Equatable, Sendable {
    /// A usable URL was found; the reference may include a refreshed bookmark.
    case resolved(reference: MediaRef, url: URL)

    /// Resolution failed; the returned reference carries `.offline` state.
    case offline(reference: MediaRef, failure: MediaReferenceResolutionFailure)

    /// Reference with its latest platform-reported availability.
    public var reference: MediaRef {
        switch self {
        case .resolved(let reference, _), .offline(let reference, _):
            return reference
        }
    }
}

/// Resolves security-scoped bookmarks first and falls back to last-known file URLs.
public struct MediaReferenceResolver {
    private let bookmarkStore: any MediaBookmarkStore
    private let fileManager: FileManager

    /// Creates the production resolver.
    public init() {
        self.init(
            bookmarkStore: SecurityScopedMediaBookmarkStore(),
            fileManager: .default
        )
    }

    /// Creates a resolver with injectable boundaries for deterministic tests.
    public init(
        bookmarkStore: any MediaBookmarkStore,
        fileManager: FileManager = .default
    ) {
        self.bookmarkStore = bookmarkStore
        self.fileManager = fileManager
    }

    /// Resolves one reference. Failures become typed offline values instead of thrown errors.
    public func resolve(_ media: MediaRef) -> MediaReferenceResolution {
        var bookmarkFailed = false
        if let bookmark = media.bookmark {
            do {
                let resolution = try bookmarkStore.resolveBookmark(bookmark)
                if let reference = resolvedReferenceIfUsable(
                    media,
                    at: resolution.url,
                    bookmark: {
                        guard resolution.isStale else {
                            return bookmark
                        }
                        return (try? bookmarkStore.createBookmark(for: resolution.url))
                            ?? bookmark
                    }
                ) {
                    return .resolved(reference: reference, url: resolution.url)
                }
                bookmarkFailed = true
            } catch {
                bookmarkFailed = true
            }
        }

        if let sourceURL = media.sourceURL {
            if let reference = resolvedReferenceIfUsable(
                media,
                at: sourceURL,
                bookmark: {
                    (try? bookmarkStore.createBookmark(for: sourceURL)) ?? media.bookmark
                }
            ) {
                return .resolved(reference: reference, url: sourceURL)
            }

            if fileManager.fileExists(atPath: sourceURL.path) {
                return .offline(
                    reference: media.withAvailability(.offline),
                    failure: .sourceUnreadable(mediaID: media.id, url: sourceURL)
                )
            }
        }

        if bookmarkFailed {
            return .offline(
                reference: media.withAvailability(.offline),
                failure: .bookmarkResolutionFailed(mediaID: media.id)
            )
        }
        return .offline(
            reference: media.withAvailability(.offline),
            failure: .sourceMissing(mediaID: media.id, lastKnownURL: media.sourceURL)
        )
    }

    /// Reconciles every manifest entry while preserving all project and stable media IDs.
    public func reconcile(_ project: Project) -> Project {
        Project(
            schemaVersion: project.schemaVersion,
            schemaMinor: project.schemaMinor,
            settings: project.settings,
            mediaPool: project.mediaPool.map { resolve($0).reference },
            sequences: project.sequences,
            looks: project.looks
        )
    }

    private func resolvedReferenceIfUsable(
        _ media: MediaRef,
        at url: URL,
        bookmark: () -> Data?
    ) -> MediaRef? {
        guard url.isFileURL else {
            return nil
        }
        let startedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if startedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue, fileManager.isReadableFile(atPath: url.path) else {
            return nil
        }
        // Resolution re-points the SAME media identity at its located file; it is not a genuine
        // relink to new bytes. `relinked(to:)` resets `proxyState` (FR-MED-004), so preserve the
        // durable proxy cache state here — otherwise reconcile-on-open would wipe every ready
        // proxy. Playback still re-probes the proxy file (path encodes the content hash), so a
        // truly changed source simply falls back and re-generates.
        return media.relinked(
            to: MediaRelinkCandidate(
                sourceURL: url,
                contentHash: media.contentHash,
                bookmark: bookmark()
            )
        ).withProxyState(media.proxyState)
    }
}
