// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarMedia

final class MediaConsolidateDurabilityTests: XCTestCase {
    func testFRMED008PostMoveSyncFailurePreservesPublishedCopyForRecovery() throws {
        let root = try temporaryDirectory(named: "consolidate-publication-sync-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.mov")
        let bytes = Data("durable publication recovery".utf8)
        try bytes.write(to: sourceURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )
        let events = PublicationEventRecorder()
        let failingOperations = PublicationDurabilityOperations(
            events: events,
            failsSynchronization: true
        )

        let failed = try makeCommand(fileOperations: failingOperations).prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package
        )

        guard
            case .publicationSyncFailed(let destinationURL, let reason) =
                failed.failure?.reason
        else {
            return XCTFail("expected a typed post-move synchronization failure")
        }
        XCTAssertTrue(reason.contains("injected directory synchronization failure"), reason)
        XCTAssertNil(failed.command)
        XCTAssertTrue(failed.publishedFileURLs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destinationURL), bytes)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
        XCTAssertEqual(events.values, [.syncPackage, .move, .syncMedia])
    }

    func testFRMED008ReuseResynchronizesPriorPublishedDestinationBeforeRewrite() throws {
        let root = try temporaryDirectory(named: "consolidate-publication-reuse-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.mov")
        let bytes = Data("durable reuse recovery".utf8)
        try bytes.write(to: sourceURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )
        let firstAttempt = try makeCommand(
            fileOperations: PublicationDurabilityOperations(
                events: PublicationEventRecorder(),
                failsSynchronization: true
            )
        ).prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package
        )
        guard
            case .publicationSyncFailed(let destinationURL, _) = firstAttempt.failure?.reason
        else {
            return XCTFail("expected first publication synchronization failure")
        }

        let reuseEvents = PublicationEventRecorder()
        let reuseSyncFailure = try makeCommand(
            fileOperations: PublicationDurabilityOperations(
                events: reuseEvents,
                failsSynchronization: true
            )
        ).prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package
        )
        guard
            case .publicationSyncFailed(let reusedURL, _) = reuseSyncFailure.failure?.reason
        else {
            return XCTFail("expected reused publication synchronization failure")
        }
        XCTAssertEqual(reusedURL, destinationURL)
        XCTAssertNil(reuseSyncFailure.command)
        XCTAssertTrue(reuseSyncFailure.publishedFileURLs.isEmpty)
        XCTAssertEqual(reuseEvents.values, [.syncPackage, .syncMedia])
        XCTAssertEqual(try Data(contentsOf: destinationURL), bytes)

        let recovered = try makeCommand().prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package
        )

        XCTAssertTrue(recovered.isComplete)
        XCTAssertEqual(recovered.publishedFileURLs, [destinationURL])
        XCTAssertEqual(try Data(contentsOf: destinationURL), bytes)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
        try assertOnlyPublishedMedia(in: package, is: destinationURL)
    }

    func testFRMED008DirectorySyncCompletesBeforeBookmarkAndReferencePublication() throws {
        let root = try temporaryDirectory(named: "consolidate-publication-sync-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.mov")
        let bytes = Data("publication order".utf8)
        try bytes.write(to: sourceURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )
        let events = PublicationEventRecorder()
        let operations = PublicationDurabilityOperations(
            events: events,
            failsSynchronization: false
        )
        let bookmarks = PublicationBookmarkStore(events: events)
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

        XCTAssertTrue(result.isComplete)
        XCTAssertNotNil(result.command)
        XCTAssertEqual(
            events.values,
            [.syncPackage, .bookmark, .move, .syncMedia, .bookmark]
        )
    }

    private func makeCommand(
        fileOperations: any ConsolidateFileOperations =
            DefaultConsolidateFileOperations(fileManager: .default)
    ) -> MediaConsolidateCommand {
        let bookmarks = PublicationBookmarkStore(events: PublicationEventRecorder())
        return MediaConsolidateCommand(
            resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: bookmarks,
            fileOperations: fileOperations
        )
    }

    private func assertOnlyPublishedMedia(in package: URL, is destinationURL: URL) throws {
        let mediaFiles = try FileManager.default.contentsOfDirectory(
            at: package.appendingPathComponent("media", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".ajar-") }
        XCTAssertEqual(
            mediaFiles.map(\.standardizedFileURL),
            [destinationURL.standardizedFileURL]
        )
    }
}

private enum PublicationEvent: Equatable {
    case move
    case syncPackage
    case syncMedia
    case bookmark
}

private final class PublicationEventRecorder {
    private(set) var values: [PublicationEvent] = []

    func append(_ event: PublicationEvent) {
        values.append(event)
    }
}

private struct PublicationBookmarkStore: MediaBookmarkStore {
    let events: PublicationEventRecorder

    func createBookmark(for url: URL) throws -> Data {
        events.append(.bookmark)
        return Data(url.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8) else {
            throw MediaBookmarkError.resolutionFailed(reason: "invalid test bookmark")
        }
        return MediaBookmarkResolution(url: URL(fileURLWithPath: path), isStale: false)
    }
}

private final class PublicationDurabilityOperations: ConsolidateFileOperations {
    private let base = DefaultConsolidateFileOperations(fileManager: .default)
    private let events: PublicationEventRecorder
    private let failsSynchronization: Bool

    init(events: PublicationEventRecorder, failsSynchronization: Bool) {
        self.events = events
        self.failsSynchronization = failsSynchronization
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
        events.append(.move)
    }
    func synchronizeDirectory(at url: URL) throws {
        let isMediaDirectory = url.lastPathComponent == "media"
        events.append(isMediaDirectory ? .syncMedia : .syncPackage)
        if failsSynchronization, isMediaDirectory {
            throw NSError(
                domain: "MediaConsolidatePublicationDurabilityTests",
                code: 267,
                userInfo: [
                    NSLocalizedDescriptionKey: "injected directory synchronization failure"
                ]
            )
        }
        try base.synchronizeDirectory(at: url)
    }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
}
