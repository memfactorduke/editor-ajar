// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Darwin
import Foundation
import XCTest

@testable import AjarMedia

final class MediaConsolidateProtectedSourceRaceTests: XCTestCase {
    func testFRMED008InitiallyMissingAliasRetargetCannotAuthorizeCandidateDeletion() throws {
        let root = try temporaryDirectory(named: "consolidate-protected-initially-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        let candidate = mediaDirectory.appendingPathComponent(
            ".ajar-partial-10101010-2020-3030-4040-505050505050"
        )
        let candidateBytes = Data("missing alias retarget candidate".utf8)
        try candidateBytes.write(to: candidate)
        let initiallyMissingAlias = root.appendingPathComponent("missing-alias.mov")
        let media = try makeMediaRef(
            sourceURL: initiallyMissingAlias,
            contentHash: ContentHash.sha256(data: candidateBytes)
        )
        let bookmarks = ProtectedSourceRaceBookmarkStore()
        var reachedQuarantine = false
        let operations = ProtectedSourceRaceOperations { _, _ in
            reachedQuarantine = true
        }
        let command = MediaConsolidateCommand(
            resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: bookmarks,
            fileOperations: operations,
            protectedSourceIdentity: { url in
                XCTAssertEqual(url, initiallyMissingAlias)
                try FileManager.default.createSymbolicLink(
                    at: initiallyMissingAlias,
                    withDestinationURL: candidate
                )
                return nil
            }
        )

        XCTAssertThrowsError(
            try command.prepare(
                project: try makeProject(media: [media]),
                openMode: .editable,
                projectPackageURL: package
            )
        ) { error in
            guard
                case .protectedSourceUnavailable(let mediaID, let url, _) =
                    error as? MediaConsolidateCommandError
            else {
                return XCTFail("expected missing-identity refusal, received \(error)")
            }
            XCTAssertEqual(mediaID, media.id)
            XCTAssertEqual(url, initiallyMissingAlias)
        }
        XCTAssertFalse(reachedQuarantine)
        XCTAssertEqual(try Data(contentsOf: candidate), candidateBytes)
        XCTAssertEqual(try Data(contentsOf: initiallyMissingAlias), candidateBytes)
    }

    func testFRMED008UnresolvedBookmarkOnlyReferenceStopsBeforeStaleSweep() throws {
        let root = try temporaryDirectory(named: "consolidate-protected-unresolved-bookmark")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        let candidate = mediaDirectory.appendingPathComponent(
            ".ajar-partial-60606060-7070-8080-9090-a0a0a0a0a0a0"
        )
        let candidateBytes = Data("bookmark-only protected candidate".utf8)
        try candidateBytes.write(to: candidate)
        let bookmarkedMedia = try makeMediaRef(
            sourceURL: root.appendingPathComponent("unavailable-last-known.mov"),
            contentHash: ContentHash.sha256(data: candidateBytes),
            bookmark: Data("unresolvable bookmark".utf8)
        )
        let media = MediaRef(
            id: bookmarkedMedia.id,
            sourceURL: nil,
            bookmark: bookmarkedMedia.bookmark,
            contentHash: bookmarkedMedia.contentHash,
            metadata: bookmarkedMedia.metadata,
            availability: .offline,
            proxyState: bookmarkedMedia.proxyState,
            transcodeProvenance: bookmarkedMedia.transcodeProvenance
        )
        let bookmarks = UnresolvedProtectedSourceBookmarkStore()
        var reachedQuarantine = false
        let command = MediaConsolidateCommand(
            resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: bookmarks,
            fileOperations: ProtectedSourceRaceOperations { _, _ in
                reachedQuarantine = true
            }
        )

        XCTAssertThrowsError(
            try command.prepare(
                project: try makeProject(media: [media]),
                openMode: .editable,
                projectPackageURL: package
            )
        ) { error in
            guard
                case .protectedSourceUnavailable(let mediaID, let url, _) =
                    error as? MediaConsolidateCommandError
            else {
                return XCTFail("expected unresolved-bookmark refusal, received \(error)")
            }
            XCTAssertEqual(mediaID, media.id)
            XCTAssertNil(url)
        }
        XCTAssertFalse(reachedQuarantine)
        XCTAssertEqual(try Data(contentsOf: candidate), candidateBytes)
    }

    func testFRMED008FinalGuardPreservesReferencedCandidateAcrossChmodRace() throws {
        let root = try temporaryDirectory(named: "consolidate-protected-chmod-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        let candidate = mediaDirectory.appendingPathComponent(
            ".ajar-partial-11111111-2222-3333-4444-555555555555"
        )
        let candidateBytes = Data("candidate becomes referenced during final guard".utf8)
        try candidateBytes.write(to: candidate)
        let protectedURL = root.appendingPathComponent("protected.mov")
        let originalProtectedBytes = Data("original protected source".utf8)
        try originalProtectedBytes.write(to: protectedURL)
        let media = try makeMediaRef(
            sourceURL: protectedURL,
            contentHash: ContentHash.sha256(data: originalProtectedBytes)
        )
        var reachedFinalBoundary = false
        let operations = ProtectedSourceRaceOperations { _, quarantineURL in
            reachedFinalBoundary = true
            try FileManager.default.removeItem(at: protectedURL)
            try FileManager.default.linkItem(at: quarantineURL, to: protectedURL)
            let result = protectedURL.path.withCString { path in
                chmod(path, S_IRUSR | S_IWUSR)
            }
            XCTAssertEqual(result, 0)
        }

        XCTAssertThrowsError(
            try makeProtectedSourceRaceCommand(operations).prepare(
                project: try makeProject(media: [media]),
                openMode: .editable,
                projectPackageURL: package
            )
        ) { error in
            guard
                case .stalePartialCleanupFailed(let url, let mediaID, _) =
                    error as? MediaConsolidateCommandError
            else {
                return XCTFail("expected final protected-source refusal, received \(error)")
            }
            XCTAssertEqual(url, protectedURL)
            XCTAssertEqual(mediaID, media.id)
        }
        XCTAssertTrue(reachedFinalBoundary)
        XCTAssertEqual(try Data(contentsOf: protectedURL), candidateBytes)
        XCTAssertEqual(try Data(contentsOf: candidate), candidateBytes)
        XCTAssertEqual(
            try ConsolidateFileIdentity.withoutFollowingSymlinks(at: protectedURL).objectIdentity,
            try ConsolidateFileIdentity.withoutFollowingSymlinks(at: candidate).objectIdentity
        )
    }

    func testFRMED008FinalGuardPreservesCandidateAfterProtectedSymlinkRetarget() throws {
        let root = try temporaryDirectory(named: "consolidate-protected-symlink-retarget")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        let candidate = mediaDirectory.appendingPathComponent(
            ".ajar-partial-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        let candidateBytes = Data("retargeted referenced candidate".utf8)
        try candidateBytes.write(to: candidate)
        let initialTarget = root.appendingPathComponent("initial.mov")
        try Data("initial target".utf8).write(to: initialTarget)
        let protectedAlias = root.appendingPathComponent("protected-alias.mov")
        try FileManager.default.createSymbolicLink(
            at: protectedAlias,
            withDestinationURL: initialTarget
        )
        let media = try makeMediaRef(
            sourceURL: protectedAlias,
            contentHash: ContentHash.sha256(data: Data("initial target".utf8))
        )
        var reachedFinalBoundary = false
        let operations = ProtectedSourceRaceOperations { _, _ in
            reachedFinalBoundary = true
            try FileManager.default.removeItem(at: protectedAlias)
            try FileManager.default.createSymbolicLink(
                at: protectedAlias,
                withDestinationURL: candidate
            )
        }

        XCTAssertThrowsError(
            try makeProtectedSourceRaceCommand(operations).prepare(
                project: try makeProject(media: [media]),
                openMode: .editable,
                projectPackageURL: package
            )
        ) { error in
            guard
                case .stalePartialCleanupFailed(let url, let mediaID, _) =
                    error as? MediaConsolidateCommandError
            else {
                return XCTFail("expected retarget refusal, received \(error)")
            }
            XCTAssertEqual(url, protectedAlias)
            XCTAssertEqual(mediaID, media.id)
        }
        XCTAssertTrue(reachedFinalBoundary)
        XCTAssertEqual(try Data(contentsOf: protectedAlias), candidateBytes)
        XCTAssertEqual(try Data(contentsOf: candidate), candidateBytes)
        XCTAssertEqual(try Data(contentsOf: initialTarget), Data("initial target".utf8))
    }

    func testFRMED008FinalGuardRestoresCandidateWhenProtectedSourceCannotBeReprobed() throws {
        let root = try temporaryDirectory(named: "consolidate-protected-final-probe-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        let candidate = mediaDirectory.appendingPathComponent(
            ".ajar-partial-99999999-8888-7777-6666-555555555555"
        )
        let candidateBytes = Data("candidate restored after final probe failure".utf8)
        try candidateBytes.write(to: candidate)
        let protectedURL = root.appendingPathComponent("protected.mov")
        let protectedBytes = Data("protected source remains unchanged".utf8)
        try protectedBytes.write(to: protectedURL)
        let media = try makeMediaRef(
            sourceURL: protectedURL,
            contentHash: ContentHash.sha256(data: protectedBytes)
        )
        let bookmarks = ProtectedSourceRaceBookmarkStore()
        var probeCount = 0
        var reachedFinalBoundary = false
        let operations = ProtectedSourceRaceOperations { _, _ in
            reachedFinalBoundary = true
        }
        let command = MediaConsolidateCommand(
            resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: bookmarks,
            fileOperations: operations,
            protectedSourceIdentity: { url in
                probeCount += 1
                if probeCount == 2 {
                    throw ProtectedSourceRaceError.unprobeable
                }
                return try ConsolidateFileIdentity.followingSymlinks(at: url)
            }
        )

        XCTAssertThrowsError(
            try command.prepare(
                project: try makeProject(media: [media]),
                openMode: .editable,
                projectPackageURL: package
            )
        ) { error in
            guard
                case .stalePartialCleanupFailed(let url, let mediaID, _) =
                    error as? MediaConsolidateCommandError
            else {
                return XCTFail("expected final probe refusal, received \(error)")
            }
            XCTAssertEqual(url, protectedURL)
            XCTAssertEqual(mediaID, media.id)
        }
        XCTAssertTrue(reachedFinalBoundary)
        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(try Data(contentsOf: candidate), candidateBytes)
        XCTAssertEqual(try Data(contentsOf: protectedURL), protectedBytes)
    }
}

private struct ProtectedSourceRaceBookmarkStore: MediaBookmarkStore {
    func createBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8) else {
            throw MediaBookmarkError.resolutionFailed(reason: "invalid test bookmark")
        }
        return MediaBookmarkResolution(url: URL(fileURLWithPath: path), isStale: false)
    }
}

private struct UnresolvedProtectedSourceBookmarkStore: MediaBookmarkStore {
    func createBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        throw MediaBookmarkError.resolutionFailed(reason: "injected unresolved bookmark")
    }
}

private func makeProtectedSourceRaceCommand(
    _ operations: any ConsolidateFileOperations
) -> MediaConsolidateCommand {
    let bookmarks = ProtectedSourceRaceBookmarkStore()
    return MediaConsolidateCommand(
        resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
        hasher: SHA256MediaFileHasher(),
        bookmarkStore: bookmarks,
        fileOperations: operations
    )
}

private enum ProtectedSourceRaceError: Error {
    case unprobeable
}

private final class ProtectedSourceRaceOperations: ConsolidateFileOperations {
    private let base = DefaultConsolidateFileOperations(fileManager: .default)
    private let hook: ConsolidateStalePartialRemover.QuarantineHook

    init(hook: @escaping ConsolidateStalePartialRemover.QuarantineHook) {
        self.hook = hook
    }

    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func isDirectory(at url: URL) throws -> Bool { try base.isDirectory(at: url) }
    func isRegularFile(at url: URL) throws -> Bool { try base.isRegularFile(at: url) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try base.copyItem(at: sourceURL, to: destinationURL)
    }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try base.moveItem(at: sourceURL, to: destinationURL)
    }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func removeOwnedPartial(
        at url: URL,
        expectedIdentity: ConsolidateFileIdentity?,
        finalRemovalGuard: ((ConsolidateFileIdentity) throws -> Void)?
    ) throws -> Bool {
        try ConsolidateStalePartialRemover(
            quarantineHook: hook,
            finalRemovalGuard: finalRemovalGuard
        ).removeRegularFile(
            at: url,
            expectedIdentity: expectedIdentity
        )
    }
}
