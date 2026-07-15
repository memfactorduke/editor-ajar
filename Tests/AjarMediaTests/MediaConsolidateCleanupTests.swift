// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarMedia

final class MediaConsolidateCleanupTests: XCTestCase {
    func testFRMED008RemovalFailureIsExplicitAndLeavesOriginalUntouched() throws {
        let root = try temporaryDirectory(named: "consolidate-cleanup-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.mov")
        let bytes = Data("original remains".utf8)
        try bytes.write(to: sourceURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )
        let operations = CleanupRemovalFailingOperations()
        let bookmarks = CleanupBookmarkStore()
        let command = MediaConsolidateCommand(
            resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: bookmarks,
            fileOperations: operations
        )

        let result = try command.prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package
        )

        guard case .partialCleanupFailed(let partialURL, let reason) = result.failure?.reason else {
            return XCTFail("expected an explicit partial cleanup failure")
        }
        XCTAssertTrue(partialURL.lastPathComponent.hasPrefix(".ajar-partial-"))
        XCTAssertTrue(reason.contains("injected cleanup refusal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialURL.path))
        XCTAssertNil(result.command)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
    }

    func testFRMED008LaterRunSweepsOnlyRegularTransactionPartialFiles() throws {
        let root = try temporaryDirectory(named: "consolidate-stale-sweep")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        let ownedID = try XCTUnwrap(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        let symlinkID = try XCTUnwrap(
            UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        )
        let ownedPartial = mediaDirectory.appendingPathComponent(
            ".ajar-partial-\(ownedID.uuidString.lowercased())"
        )
        let stalePartial = mediaDirectory.appendingPathComponent(".ajar-partial-stale")
        let extraSuffix = mediaDirectory.appendingPathComponent(
            ".ajar-partial-\(ownedID.uuidString)-extra"
        )
        let unrelated = mediaDirectory.appendingPathComponent(".ajar-partialish-keep")
        let external = root.appendingPathComponent("external-do-not-delete")
        let partialSymlink = mediaDirectory.appendingPathComponent(
            ".ajar-partial-\(symlinkID.uuidString.lowercased())"
        )
        try Data("owned stale transaction".utf8).write(to: ownedPartial)
        try Data("stale".utf8).write(to: stalePartial)
        try Data("extra suffix".utf8).write(to: extraSuffix)
        try Data("keep".utf8).write(to: unrelated)
        try Data("external".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: partialSymlink,
            withDestinationURL: external
        )

        let result = try MediaConsolidateCommand().prepare(
            project: try makeProject(media: []),
            openMode: .editable,
            projectPackageURL: package
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedPartial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stalePartial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extraSuffix.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialSymlink.path))
        XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
    }

    func testFRMED008SweepPreservesReferencedExactPatternSourceAndReusesIt() throws {
        let root = try temporaryDirectory(named: "consolidate-protected-partial-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        let sourceURL = mediaDirectory.appendingPathComponent(
            ".ajar-partial-11111111-2222-3333-4444-555555555555"
        )
        let bytes = Data("legitimate referenced source".utf8)
        try bytes.write(to: sourceURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )

        let bookmarks = CleanupBookmarkStore()
        let command = MediaConsolidateCommand(
            resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: bookmarks,
            fileOperations: DefaultConsolidateFileOperations(fileManager: .default)
        )
        let result = try command.prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.consolidatedMediaIDs, [media.id])
        XCTAssertEqual(result.publishedFileURLs, [sourceURL])
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
    }

    func testFRMED008SweepAlsoProtectsDifferentUsableBookmarkURL() throws {
        let root = try temporaryDirectory(named: "consolidate-protected-bookmark-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        let bookmarkURL = mediaDirectory.appendingPathComponent(
            ".ajar-partial-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        let bytes = Data("bookmark resolved source".utf8)
        try bytes.write(to: bookmarkURL)
        let lastKnownURL = root.appendingPathComponent("last-known.mov")
        try bytes.write(to: lastKnownURL)
        let media = try makeMediaRef(
            sourceURL: lastKnownURL,
            contentHash: ContentHash.sha256(data: bytes),
            bookmark: Data(bookmarkURL.path.utf8)
        )
        let bookmarks = CleanupBookmarkStore()
        let command = MediaConsolidateCommand(
            resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: bookmarks,
            fileOperations: DefaultConsolidateFileOperations(fileManager: .default)
        )

        let result = try command.prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.consolidatedMediaIDs, [media.id])
        XCTAssertEqual(result.publishedFileURLs, [bookmarkURL])
        XCTAssertEqual(try Data(contentsOf: bookmarkURL), bytes)
    }

    func testFRMED008SweepProtectsSourceThroughSymlinkedParentIdentity() throws {
        let fixture = try SymlinkedPartialFixture(name: "source-alias")
        defer { fixture.remove() }
        let media = try makeMediaRef(
            sourceURL: fixture.aliasedPartialURL,
            contentHash: ContentHash.sha256(data: fixture.bytes)
        )
        let command = makeCleanupCommand()

        let result = try command.prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: fixture.package
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(try Data(contentsOf: fixture.actualPartialURL), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.aliasedPartialURL), fixture.bytes)
    }

    func testFRMED008SweepProtectsBookmarkThroughSymlinkedParentIdentity() throws {
        let fixture = try SymlinkedPartialFixture(name: "bookmark-alias")
        defer { fixture.remove() }
        let lastKnownURL = fixture.root.appendingPathComponent("last-known.mov")
        try fixture.bytes.write(to: lastKnownURL)
        let media = try makeMediaRef(
            sourceURL: lastKnownURL,
            contentHash: ContentHash.sha256(data: fixture.bytes),
            bookmark: Data(fixture.aliasedPartialURL.path.utf8)
        )
        let command = makeCleanupCommand()

        let result = try command.prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: fixture.package
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(try Data(contentsOf: fixture.actualPartialURL), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.aliasedPartialURL), fixture.bytes)
    }

    // swiftlint:disable:next function_body_length
    func testFRMED008StaleSweepRefusesSymlinkOrDirectorySubstitution() throws {
        for substitution in CleanupPathSubstitution.allCases {
            let root = try temporaryDirectory(
                named: "consolidate-stale-substitution-\(substitution.rawValue)"
            )
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
            let protectedTarget = root.appendingPathComponent(
                "protected-\(substitution.rawValue)",
                isDirectory: substitution == .directory
            )
            if substitution == .directory {
                try FileManager.default.createDirectory(
                    at: protectedTarget,
                    withIntermediateDirectories: false
                )
                try Data("inside protected directory".utf8).write(
                    to: protectedTarget.appendingPathComponent("keep.txt")
                )
            } else {
                try Data("protected symlink target".utf8).write(to: protectedTarget)
            }
            try Data("inspected stale file".utf8).write(to: candidate)

            let bookmarks = CleanupBookmarkStore()
            let command = MediaConsolidateCommand(
                resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
                hasher: SHA256MediaFileHasher(),
                bookmarkStore: bookmarks,
                fileOperations: SubstitutingCleanupOperations(
                    substitution: substitution,
                    protectedTarget: protectedTarget
                )
            )

            XCTAssertThrowsError(
                try command.prepare(
                    project: try makeProject(media: []),
                    openMode: .editable,
                    projectPackageURL: package
                )
            ) { error in
                guard
                    case .stalePartialCleanupFailed(let url, _, _) =
                        error as? MediaConsolidateCommandError
                else {
                    return XCTFail("expected unsafe stale-entry failure, received \(error)")
                }
                XCTAssertEqual(url.lastPathComponent, candidate.lastPathComponent)
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
            XCTAssertEqual(
                attributes[.type] as? FileAttributeType,
                substitution == .directory ? .typeDirectory : .typeSymbolicLink
            )
            if substitution == .directory {
                XCTAssertEqual(
                    try Data(contentsOf: candidate.appendingPathComponent("keep.txt")),
                    Data("inside protected directory".utf8)
                )
            } else {
                XCTAssertEqual(
                    try Data(contentsOf: protectedTarget),
                    Data("protected symlink target".utf8)
                )
            }
        }
    }

}

private func makeCleanupCommand() -> MediaConsolidateCommand {
    let bookmarks = CleanupBookmarkStore()
    return MediaConsolidateCommand(
        resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
        hasher: SHA256MediaFileHasher(),
        bookmarkStore: bookmarks,
        fileOperations: DefaultConsolidateFileOperations(fileManager: .default)
    )
}

private struct SymlinkedPartialFixture {
    let root: URL
    let package: URL
    let actualPartialURL: URL
    let aliasedPartialURL: URL
    let bytes: Data

    init(name: String) throws {
        root = try temporaryDirectory(named: "consolidate-protected-\(name)")
        package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        actualPartialURL = mediaDirectory.appendingPathComponent(
            ".ajar-partial-11111111-2222-3333-4444-555555555555"
        )
        let alias = root.appendingPathComponent("media-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: mediaDirectory)
        aliasedPartialURL = alias.appendingPathComponent(actualPartialURL.lastPathComponent)
        bytes = Data("symlink parent original".utf8)
        try bytes.write(to: actualPartialURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct CleanupBookmarkStore: MediaBookmarkStore {
    func createBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8) else {
            throw MediaBookmarkError.resolutionFailed(reason: "invalid test bookmark")
        }
        return MediaBookmarkResolution(url: URL(fileURLWithPath: path), isStale: false)
    }
}

private final class CleanupRemovalFailingOperations: ConsolidateFileOperations {
    private let fileManager = FileManager.default

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileExists(at url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }

    func isDirectory(at url: URL) throws -> Bool {
        try itemType(at: url) == .typeDirectory
    }

    func isRegularFile(at url: URL) throws -> Bool {
        try itemType(at: url) == .typeRegular
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        throw NSError(
            domain: "MediaConsolidateCleanupTests",
            code: 267,
            userInfo: [NSLocalizedDescriptionKey: "injected publish refusal"]
        )
    }

    func removeItem(at url: URL) throws {
        throw NSError(
            domain: "MediaConsolidateCleanupTests",
            code: 268,
            userInfo: [NSLocalizedDescriptionKey: "injected cleanup refusal"]
        )
    }

    func removeOwnedPartial(
        at url: URL,
        expectedIdentity: ConsolidateFileIdentity?,
        finalRemovalGuard: ((ConsolidateFileIdentity) throws -> Void)?
    ) throws -> Bool {
        try removeItem(at: url)
        return true
    }

    private func itemType(at url: URL) throws -> FileAttributeType? {
        try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }
}

private enum CleanupPathSubstitution: String, CaseIterable {
    case symlink
    case directory
}

private final class SubstitutingCleanupOperations: ConsolidateFileOperations {
    private let base = DefaultConsolidateFileOperations(fileManager: .default)
    private let substitution: CleanupPathSubstitution
    private let protectedTarget: URL

    init(substitution: CleanupPathSubstitution, protectedTarget: URL) {
        self.substitution = substitution
        self.protectedTarget = protectedTarget
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
            inspectionHook: { [substitution, protectedTarget] candidate in
                try FileManager.default.removeItem(at: candidate)
                switch substitution {
                case .symlink:
                    try FileManager.default.createSymbolicLink(
                        at: candidate,
                        withDestinationURL: protectedTarget
                    )
                case .directory:
                    try FileManager.default.createDirectory(
                        at: candidate,
                        withIntermediateDirectories: false
                    )
                    try FileManager.default.copyItem(
                        at: protectedTarget.appendingPathComponent("keep.txt"),
                        to: candidate.appendingPathComponent("keep.txt")
                    )
                }
            },
            finalRemovalGuard: finalRemovalGuard
        ).removeRegularFile(at: url, expectedIdentity: expectedIdentity)
    }
}
