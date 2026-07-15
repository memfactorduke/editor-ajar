// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Darwin
import Foundation
import XCTest

@testable import AjarMedia

final class MediaConsolidateRecoveryTests: XCTestCase {
    func testFRMED008BookmarkIsProtectedBeforeUnprobeableLastKnownSourceFailsTyped() throws {
        let root = try temporaryDirectory(named: "consolidate-protected-probe-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory, withIntermediateDirectories: true)
        let bookmarkURL = mediaDirectory.appendingPathComponent(
            ".ajar-partial-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        let bytes = Data("bookmark original".utf8)
        try bytes.write(to: bookmarkURL)
        let lastKnownURL = root.appendingPathComponent("unprobeable-last-known.mov")
        let media = try makeMediaRef(
            sourceURL: lastKnownURL,
            contentHash: ContentHash.sha256(data: bytes),
            bookmark: Data(bookmarkURL.path.utf8)
        )
        let bookmarks = RecoveryBookmarkStore()
        var probedURLs: [URL] = []
        let command = MediaConsolidateCommand(
            resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: bookmarks,
            fileOperations: DefaultConsolidateFileOperations(fileManager: .default),
            protectedSourceIdentity: { url in
                probedURLs.append(url)
                if url == lastKnownURL {
                    throw RecoveryInjectedError.unprobeable
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
                case .protectedSourceUnavailable(let mediaID, let url, _) =
                    error as? MediaConsolidateCommandError
            else {
                return XCTFail("expected typed protection failure, received \(error)")
            }
            XCTAssertEqual(url, lastKnownURL)
            XCTAssertEqual(mediaID, media.id)
        }
        XCTAssertEqual(probedURLs, [bookmarkURL, lastKnownURL])
        XCTAssertEqual(try Data(contentsOf: bookmarkURL), bytes)
    }

    func testFRMED008StaleSweepRefusesProtectedInodeSwapAfterInspection() throws {
        let root = try temporaryDirectory(named: "consolidate-protected-inode-swap")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory, withIntermediateDirectories: true)
        let candidate = mediaDirectory.appendingPathComponent(
            ".ajar-partial-11111111-2222-3333-4444-555555555555"
        )
        try Data("abandoned partial".utf8).write(to: candidate)
        let protectedURL = root.appendingPathComponent("referenced-original.mov")
        let protectedBytes = Data("protected original inode".utf8)
        try protectedBytes.write(to: protectedURL)
        let media = try makeMediaRef(
            sourceURL: protectedURL,
            contentHash: ContentHash.sha256(data: protectedBytes)
        )
        let operations = ProtectedInodeSwapOperations(protectedURL: protectedURL)

        XCTAssertThrowsError(
            try makeCommand(operations).prepare(
                project: try makeProject(media: [media]),
                openMode: .editable,
                projectPackageURL: package
            )
        ) { error in
            guard case .stalePartialCleanupFailed = error as? MediaConsolidateCommandError else {
                return XCTFail("expected identity refusal, received \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: protectedURL), protectedBytes)
        XCTAssertEqual(try Data(contentsOf: candidate), protectedBytes)
        XCTAssertEqual(
            try ConsolidateFileIdentity.withoutFollowingSymlinks(at: protectedURL),
            try ConsolidateFileIdentity.withoutFollowingSymlinks(at: candidate)
        )
    }

    func testFRMED008ActiveCleanupRefusesSubstitutedRegularFile() throws {
        let root = try temporaryDirectory(named: "consolidate-active-partial-substitution")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.mov")
        let sourceBytes = Data("source must remain".utf8)
        let replacementBytes = Data("replacement must not be removed".utf8)
        try sourceBytes.write(to: sourceURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: sourceBytes)
        )
        let operations = ActivePartialSubstitutionOperations(replacementBytes: replacementBytes)

        let result = try makeCommand(operations).prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package
        )

        guard case .partialCleanupFailed(let partialURL, _) = result.failure?.reason else {
            return XCTFail("expected identity-protected cleanup failure")
        }
        XCTAssertEqual(try Data(contentsOf: partialURL), replacementBytes)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
        XCTAssertNil(result.command)
    }

    func testFRMED008InterruptedQuarantineRestoresBeforeLaterProtectedSweep() throws {
        let fixture = try StaleRecoveryFixture(name: "interrupted")
        defer { fixture.remove() }
        let interrupting = QuarantineHookOperations { _, _ in
            throw RecoveryInjectedError.interrupted
        }

        XCTAssertThrowsError(
            try fixture.command(fileOperations: interrupting).prepare(
                project: try makeProject(media: []),
                openMode: .editable,
                projectPackageURL: fixture.package
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL.path))
        let quarantined = try fixture.quarantineEntries()
        XCTAssertEqual(quarantined.dataFiles.count, 1)
        XCTAssertEqual(quarantined.recordFiles.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(quarantined.dataFiles.first)),
            fixture.bytes
        )

        let media = try makeMediaRef(
            sourceURL: fixture.partialURL,
            contentHash: ContentHash.sha256(data: fixture.bytes)
        )
        let result = try fixture.command().prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: fixture.package
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.publishedFileURLs, [fixture.partialURL])
        XCTAssertEqual(try Data(contentsOf: fixture.partialURL), fixture.bytes)
        XCTAssertTrue(try fixture.quarantineEntries().all.isEmpty)
    }

    func testFRMED008PostRenameDirectorySyncFailureRetainsRecoverableRecord() throws {
        let fixture = try StaleRecoveryFixture(name: "post-rename-sync")
        defer { fixture.remove() }
        let failing = PostRenameSyncFailingOperations()

        XCTAssertThrowsError(
            try fixture.command(fileOperations: failing).prepare(
                project: try makeProject(media: []),
                openMode: .editable,
                projectPackageURL: fixture.package
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL.path))
        let interrupted = try fixture.quarantineEntries()
        XCTAssertEqual(interrupted.dataFiles.count, 1)
        XCTAssertEqual(interrupted.recordFiles.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(interrupted.dataFiles.first)),
            fixture.bytes
        )

        let media = try makeMediaRef(
            sourceURL: fixture.partialURL,
            contentHash: ContentHash.sha256(data: fixture.bytes)
        )
        let result = try fixture.command().prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: fixture.package
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.publishedFileURLs, [fixture.partialURL])
        XCTAssertEqual(try Data(contentsOf: fixture.partialURL), fixture.bytes)
        XCTAssertTrue(try fixture.quarantineEntries().all.isEmpty)
    }

    func testFRMED008TruncatedTemporaryRecoveryObjectsAreIgnoredAndPreserved() throws {
        let fixture = try StaleRecoveryFixture(name: "temporary-records")
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.partialURL)
        let regular = fixture.mediaDirectory.appendingPathComponent(
            ".ajar-quarantine-record-11111111-2222-3333-4444-555555555555.tmp"
        )
        let directory = fixture.mediaDirectory.appendingPathComponent(
            ".ajar-quarantine-record-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.tmp",
            isDirectory: true
        )
        let symlink = fixture.mediaDirectory.appendingPathComponent(
            ".ajar-quarantine-record-99999999-8888-7777-6666-555555555555.tmp"
        )
        let external = fixture.root.appendingPathComponent("external-keep")
        let truncated = Data("{\"version\":".utf8)
        try truncated.write(to: regular)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("directory child".utf8).write(to: directory.appendingPathComponent("keep"))
        try Data("external target".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)

        let result = try fixture.command().prepare(
            project: try makeProject(media: []),
            openMode: .editable,
            projectPackageURL: fixture.package
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(try Data(contentsOf: regular), truncated)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("keep")),
            Data("directory child".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: external), Data("external target".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
    }

    func testFRMED008RecoveryCollisionPreservesOriginalAndQuarantine() throws {
        let fixture = try StaleRecoveryFixture(name: "restore-collision")
        defer { fixture.remove() }
        let collisionBytes = Data("new collision remains".utf8)
        let interrupting = QuarantineHookOperations { originalURL, _ in
            try collisionBytes.write(to: originalURL, options: .withoutOverwriting)
            throw RecoveryInjectedError.interrupted
        }

        XCTAssertThrowsError(
            try fixture.command(fileOperations: interrupting).prepare(
                project: try makeProject(media: []),
                openMode: .editable,
                projectPackageURL: fixture.package
            )
        )
        let quarantined = try fixture.quarantineEntries()
        XCTAssertEqual(quarantined.dataFiles.count, 1)
        XCTAssertEqual(quarantined.recordFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.partialURL), collisionBytes)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(quarantined.dataFiles.first)),
            fixture.bytes
        )

        XCTAssertThrowsError(
            try fixture.command().prepare(
                project: try makeProject(media: []),
                openMode: .editable,
                projectPackageURL: fixture.package
            )
        ) { error in
            guard case .stalePartialCleanupFailed = error as? MediaConsolidateCommandError else {
                return XCTFail("expected typed recovery collision, received \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.partialURL), collisionBytes)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(quarantined.dataFiles.first)),
            fixture.bytes
        )
        XCTAssertEqual(try fixture.quarantineEntries().all.count, 2)
    }
}

private struct QuarantineEntries {
    let dataFiles: [URL]
    let recordFiles: [URL]
    let all: [URL]
}

private struct StaleRecoveryFixture {
    let root: URL
    let package: URL
    let mediaDirectory: URL
    let partialURL: URL
    let bytes = Data("original quarantine bytes".utf8)

    init(name: String) throws {
        root = try temporaryDirectory(named: "consolidate-recovery-\(name)")
        package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        partialURL = mediaDirectory.appendingPathComponent(
            ".ajar-partial-11111111-2222-3333-4444-555555555555"
        )
        try bytes.write(to: partialURL)
    }

    func command(
        fileOperations: any ConsolidateFileOperations =
            DefaultConsolidateFileOperations(fileManager: .default)
    ) -> MediaConsolidateCommand {
        makeCommand(fileOperations)
    }

    func quarantineEntries() throws -> QuarantineEntries {
        let all = try FileManager.default.contentsOfDirectory(
            at: mediaDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".ajar-quarantine-") }
        return QuarantineEntries(
            dataFiles: all.filter { $0.pathExtension == "data" },
            recordFiles: all.filter { $0.pathExtension == "json" },
            all: all
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct RecoveryBookmarkStore: MediaBookmarkStore {
    func createBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8) else {
            throw MediaBookmarkError.resolutionFailed(reason: "invalid test bookmark")
        }
        return MediaBookmarkResolution(url: URL(fileURLWithPath: path), isStale: false)
    }
}

private func makeCommand(_ operations: any ConsolidateFileOperations) -> MediaConsolidateCommand {
    let bookmarks = RecoveryBookmarkStore()
    return MediaConsolidateCommand(
        resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
        hasher: SHA256MediaFileHasher(),
        bookmarkStore: bookmarks,
        fileOperations: operations
    )
}

private enum RecoveryInjectedError: Error {
    case interrupted
    case unprobeable
}

private final class QuarantineHookOperations: ConsolidateFileOperations {
    private let base = DefaultConsolidateFileOperations(fileManager: .default)
    private let hook: ConsolidateStalePartialRemover.QuarantineHook

    init(hook: @escaping ConsolidateStalePartialRemover.QuarantineHook) { self.hook = hook }

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

private final class ActivePartialSubstitutionOperations: ConsolidateFileOperations {
    private let base = DefaultConsolidateFileOperations(fileManager: .default)
    private let replacementBytes: Data
    private var didSubstitute = false

    init(replacementBytes: Data) { self.replacementBytes = replacementBytes }

    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func isDirectory(at url: URL) throws -> Bool { try base.isDirectory(at: url) }
    func isRegularFile(at url: URL) throws -> Bool {
        if isOwnedConsolidatePartialFileName(url.lastPathComponent), !didSubstitute {
            didSubstitute = true
            try FileManager.default.removeItem(at: url)
            try replacementBytes.write(to: url, options: .withoutOverwriting)
        }
        return try base.isRegularFile(at: url)
    }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try base.copyItem(at: sourceURL, to: destinationURL)
    }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try base.moveItem(at: sourceURL, to: destinationURL)
    }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
}

private final class ProtectedInodeSwapOperations: ConsolidateFileOperations {
    private let base = DefaultConsolidateFileOperations(fileManager: .default)
    private let protectedURL: URL
    private var didSwap = false

    init(protectedURL: URL) { self.protectedURL = protectedURL }

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
        if !didSwap {
            didSwap = true
            try FileManager.default.removeItem(at: url)
            try FileManager.default.linkItem(at: protectedURL, to: url)
        }
        return try base.removeOwnedPartial(
            at: url,
            expectedIdentity: expectedIdentity,
            finalRemovalGuard: finalRemovalGuard
        )
    }
}

private final class PostRenameSyncFailingOperations: ConsolidateFileOperations {
    private let base = DefaultConsolidateFileOperations(fileManager: .default)
    private var syncCount = 0

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
            directorySync: { [weak self] descriptor, _ in
                guard let self else { throw RecoveryInjectedError.interrupted }
                syncCount += 1
                if syncCount == 2 {
                    throw RecoveryInjectedError.interrupted
                }
                guard fsync(descriptor) == 0 else {
                    throw RecoveryInjectedError.unprobeable
                }
            },
            finalRemovalGuard: finalRemovalGuard
        ).removeRegularFile(at: url, expectedIdentity: expectedIdentity)
    }
}
