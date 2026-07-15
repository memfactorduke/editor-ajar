// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarMedia

final class MediaConsolidateCommandTests: XCTestCase {  // swiftlint:disable:this type_body_length
    func testFRMED008ConsolidateRewritesRefsReportsProgressAndUndoKeepsCopies() throws {
        let root = try temporaryDirectory(named: "consolidate")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let firstURL = sources.appendingPathComponent("first.mov")
        let secondURL = sources.appendingPathComponent("second.mov")
        let firstBytes = Data("first original".utf8)
        let secondBytes = Data("second original".utf8)
        try firstBytes.write(to: firstURL)
        try secondBytes.write(to: secondURL)
        let first = try makeMediaRef(
            sourceURL: firstURL,
            contentHash: ContentHash.sha256(data: firstBytes)
        )
        let second = try makeMediaRef(
            sourceURL: secondURL,
            contentHash: ContentHash.sha256(data: secondBytes)
        )
        let project = try makeProject(media: [first, second])
        let progress = ConsolidationProgressRecorder()
        let command = makeConsolidateCommand()

        let result = try command.prepare(
            project: project,
            openMode: .editable,
            projectPackageURL: package,
            progress: progress
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.consolidatedMediaIDs, [first.id, second.id])
        let completedUpdates = progress.updates.filter {
            $0.destinationURL != nil || $0.mediaID == nil
        }
        XCTAssertEqual(completedUpdates.map(\.completedFileCount), [0, 1, 2])
        XCTAssertEqual(completedUpdates.map(\.totalFileCount), [2, 2, 2])
        XCTAssertTrue(
            result.publishedFileURLs.allSatisfy {
                $0.deletingLastPathComponent() == package.appendingPathComponent("media")
            })
        XCTAssertTrue(
            result.publishedFileURLs.allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            })
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertEqual(try Data(contentsOf: secondURL), secondBytes)

        var history = EditHistory(project: project)
        let edited = try history.apply(try XCTUnwrap(result.command))
        XCTAssertEqual(edited.mediaPool.map(\.id), [first.id, second.id])
        XCTAssertEqual(
            edited.mediaPool.map(\.sourceURL),
            result.publishedFileURLs.map(Optional.some)
        )
        XCTAssertEqual(history.undo(), project)
        XCTAssertTrue(
            result.publishedFileURLs.allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            })
    }

    func testFRMED008ConsolidateCopyFailureKeepsPublishedFilesAndRefsConsistent() throws {
        let root = try temporaryDirectory(named: "consolidate-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        var media: [MediaRef] = []
        for index in 0..<3 {
            let url = sources.appendingPathComponent("source-\(index).mov")
            let bytes = Data("source \(index)".utf8)
            try bytes.write(to: url)
            media.append(
                try makeMediaRef(
                    sourceURL: url,
                    contentHash: ContentHash.sha256(data: bytes)
                )
            )
        }
        let project = try makeProject(media: media)
        let operations = FailingCopyOperations(failingMoveNumber: 2)
        let command = makeConsolidateCommand(fileOperations: operations)

        let result = try command.prepare(
            project: project,
            openMode: .editable,
            projectPackageURL: package
        )

        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.failure?.mediaID, media[1].id)
        XCTAssertEqual(result.consolidatedMediaIDs, [media[0].id])
        let firstPublished = try XCTUnwrap(result.publishedFileURLs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPublished.path))
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: mediaDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(leftovers.contains { $0.lastPathComponent.contains(".ajar-partial") })

        let edited = try apply(try XCTUnwrap(result.command), to: project)
        XCTAssertEqual(edited.mediaPool[0].sourceURL, firstPublished)
        let editedFirstPath = edited.mediaPool[0].sourceURL?.path ?? ""
        XCTAssertTrue(FileManager.default.fileExists(atPath: editedFirstPath))
        XCTAssertEqual(edited.mediaPool[1], media[1])
        XCTAssertEqual(edited.mediaPool[2], media[2])
        for original in media {
            let url = try XCTUnwrap(original.sourceURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testFRMED004ConsolidatePreservesProxyStateWhileRelinkResets() throws {
        let root = try temporaryDirectory(named: "consolidate-proxy-preserve")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("clip.mov")
        let bytes = Data("proxy-preserve-original".utf8)
        try bytes.write(to: sourceURL)
        let readyPath = "caches/proxies/clip-proxy.mov"
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes),
            proxyState: .ready(relativePath: readyPath)
        )
        let project = try makeProject(media: [media])
        let result = try makeConsolidateCommand().prepare(
            project: project,
            openMode: .editable,
            projectPackageURL: package
        )
        XCTAssertTrue(result.isComplete)
        let edited = try apply(try XCTUnwrap(result.command), to: project)
        let consolidated = try XCTUnwrap(edited.mediaPool.first)
        // Same-bytes consolidate preserves the ready proxy; genuine relink below resets it.
        XCTAssertEqual(consolidated.proxyState, .ready(relativePath: readyPath))
        let relinked = consolidated.relinked(to: MediaRelinkCandidate(
            sourceURL: URL(fileURLWithPath: "/other/source.mov"),
            contentHash: ContentHash.sha256(data: Data("different".utf8))
        ))
        XCTAssertEqual(relinked.proxyState, MediaProxyState.none)
    }

    func testFRMED008ReadOnlyConsolidateRefusesBeforeCreatingMediaDirectory() throws {
        let root = try temporaryDirectory(named: "consolidate-read-only")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let project = try makeProject(media: [])
        let reason = AjarProjectReadOnlyReason.newerSchemaMinor(
            found: AjarProjectCodec.currentSchemaMinor + 1,
            supported: AjarProjectCodec.currentSchemaMinor
        )

        XCTAssertThrowsError(
            try makeConsolidateCommand().prepare(
                project: project,
                openMode: .readOnly(reason: reason),
                projectPackageURL: package
            )
        ) { error in
            XCTAssertEqual(
                error as? MediaConsolidateCommandError,
                .projectOpenedReadOnly(reason)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: package.appendingPathComponent("media").path
            )
        )
    }

    func testFRMED008DuplicateMediaIDsFailBeforeCreatingMediaDirectory() throws {
        let root = try temporaryDirectory(named: "consolidate-duplicate-id")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.mov")
        let bytes = Data("source bytes".utf8)
        try bytes.write(to: sourceURL)
        let first = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )
        let duplicate = try makeMediaRef(
            id: first.id,
            sourceURL: sourceURL,
            contentHash: first.contentHash ?? ContentHash.sha256(data: bytes)
        )

        XCTAssertThrowsError(
            try makeConsolidateCommand().prepare(
                project: try makeProject(media: [first, duplicate]),
                openMode: .editable,
                projectPackageURL: package
            )
        ) { error in
            XCTAssertEqual(
                error as? MediaConsolidateCommandError,
                .duplicateMediaReferenceID(first.id)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: package.appendingPathComponent("media").path
            )
        )
    }

    func testFRMED008ConsolidateRejectsSymlinkInsteadOfPublishingExternalReference() throws {
        let root = try temporaryDirectory(named: "consolidate-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let targetURL = root.appendingPathComponent("target.mov")
        let sourceURL = root.appendingPathComponent("source.mov")
        let bytes = Data("external target".utf8)
        try bytes.write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: targetURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )

        let result = try makeConsolidateCommand().prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package
        )

        XCTAssertEqual(result.failure?.reason, .sourceNotRegularFile(sourceURL))
        XCTAssertNil(result.command)
        let published = try FileManager.default.contentsOfDirectory(
            at: package.appendingPathComponent("media"),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(published.allSatisfy { $0.lastPathComponent == ".ajar-consolidation.lock" })
        XCTAssertEqual(try Data(contentsOf: targetURL), bytes)
    }

    func testFRMED008ConsolidateVerifiesTemporaryBytesBeforePublish() throws {
        let root = try temporaryDirectory(named: "consolidate-corrupt-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.mov")
        let bytes = Data("source bytes".utf8)
        try bytes.write(to: sourceURL)
        let expectedHash = ContentHash.sha256(data: bytes)
        let media = try makeMediaRef(sourceURL: sourceURL, contentHash: expectedHash)

        let result = try makeConsolidateCommand(
            fileOperations: CorruptingCopyOperations()
        ).prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package
        )

        let corruptedHash = ContentHash.sha256(data: CorruptingCopyOperations.corruptedBytes)
        XCTAssertEqual(
            result.failure?.reason,
            .copiedContentHashMismatch(expected: expectedHash, actual: corruptedHash)
        )
        XCTAssertNil(result.command)
        let published = try FileManager.default.contentsOfDirectory(
            at: package.appendingPathComponent("media"),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(published.allSatisfy { $0.lastPathComponent == ".ajar-consolidation.lock" })
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
    }

    func testFRMED008ConsolidateIsIdempotentAfterApplyingReferenceRewrite() throws {
        let root = try temporaryDirectory(named: "consolidate-idempotent")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.mov")
        let bytes = Data("source bytes".utf8)
        try bytes.write(to: sourceURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )
        let project = try makeProject(media: [media])
        let command = makeConsolidateCommand()

        let first = try command.prepare(
            project: project,
            openMode: .editable,
            projectPackageURL: package
        )
        let consolidated = try apply(try XCTUnwrap(first.command), to: project)
        let second = try command.prepare(
            project: consolidated,
            openMode: .editable,
            projectPackageURL: package
        )

        XCTAssertEqual(second.publishedFileURLs, first.publishedFileURLs)
        let files = try FileManager.default.contentsOfDirectory(
            at: package.appendingPathComponent("media"),
            includingPropertiesForKeys: nil
        )
        let mediaFiles = files.filter { $0.lastPathComponent != ".ajar-consolidation.lock" }
        XCTAssertEqual(mediaFiles.count, 1)
    }

    func testFRMED008ConsolidateRejectsMediaDirectorySymlink() throws {
        let root = try temporaryDirectory(named: "consolidate-media-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let external = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: mediaDirectory,
            withDestinationURL: external
        )

        XCTAssertThrowsError(
            try makeConsolidateCommand().prepare(
                project: try makeProject(media: []),
                openMode: .editable,
                projectPackageURL: package
            )
        ) { error in
            XCTAssertEqual(
                error as? MediaConsolidateCommandError,
                .unsafeMediaDirectory(mediaDirectory)
            )
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: external,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testFRMED008ConsolidateAcceptsLegalLongSourceFilename() throws {
        let root = try temporaryDirectory(named: "consolidate-long-name")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent(String(repeating: "a", count: 180) + ".mov")
        let bytes = Data("long filename source".utf8)
        try bytes.write(to: sourceURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )

        let result = try makeConsolidateCommand().prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package
        )

        XCTAssertTrue(result.isComplete)
        let destination = try XCTUnwrap(result.publishedFileURLs.first)
        XCTAssertLessThan(destination.lastPathComponent.utf8.count, 255)
        XCTAssertEqual(destination.pathExtension, "mov")
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    private func makeConsolidateCommand(
        fileOperations: any ConsolidateFileOperations = DefaultConsolidateFileOperations(
            fileManager: .default
        )
    ) -> MediaConsolidateCommand {
        let bookmarks = TestConsolidateBookmarkStore()
        return MediaConsolidateCommand(
            resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: bookmarks,
            fileOperations: fileOperations
        )
    }
}

private struct TestConsolidateBookmarkStore: MediaBookmarkStore {
    func createBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8) else {
            throw MediaBookmarkError.resolutionFailed(reason: "invalid test bookmark")
        }
        return MediaBookmarkResolution(url: URL(fileURLWithPath: path), isStale: false)
    }
}

private final class FailingCopyOperations: ConsolidateFileOperations {
    private let fileManager = FileManager.default
    private let failingMoveNumber: Int
    private var moveCount = 0

    init(failingMoveNumber: Int) {
        self.failingMoveNumber = failingMoveNumber
    }

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
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        moveCount += 1
        if moveCount == failingMoveNumber {
            throw NSError(
                domain: "MediaConsolidateCommandTests",
                code: 218,
                userInfo: [NSLocalizedDescriptionKey: "injected publish failure"]
            )
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}

private final class CorruptingCopyOperations: ConsolidateFileOperations {
    static let corruptedBytes = Data("corrupted copy".utf8)
    private let fileManager = FileManager.default

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
        try Self.corruptedBytes.write(to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}
