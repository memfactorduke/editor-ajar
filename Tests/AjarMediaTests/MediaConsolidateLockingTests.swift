// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarMedia

final class MediaConsolidateLockingTests: XCTestCase {
    func testFRMED008OverlappingCommandRefusesWithoutDeletingActivePartial() throws {
        let root = try temporaryDirectory(named: "consolidate-overlap-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.mov")
        let bytes = Data("active transaction bytes".utf8)
        try bytes.write(to: sourceURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )
        let operations = BlockingConsolidateCopyOperations()
        let first = makeLockingCommand(fileOperations: operations)
        let completion = expectation(description: "first consolidation finishes")
        let outcome = LockedConsolidationOutcome()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                outcome.set(
                    .success(
                        try first.prepare(
                            project: try makeProject(media: [media]),
                            openMode: .editable,
                            projectPackageURL: package
                        )
                    )
                )
            } catch {
                outcome.set(.failure(error))
            }
            completion.fulfill()
        }

        XCTAssertEqual(operations.waitUntilPartialExists(), .success)
        let partialURL = try XCTUnwrap(operations.partialURL)
        let activeBytes = try Data(contentsOf: partialURL)

        XCTAssertThrowsError(
            try MediaConsolidateCommand().prepare(
                project: try makeProject(media: []),
                openMode: .editable,
                projectPackageURL: package
            )
        ) { error in
            XCTAssertEqual(
                error as? MediaConsolidateCommandError,
                .packageBusy(package)
            )
        }
        XCTAssertEqual(try Data(contentsOf: partialURL), activeBytes)

        operations.resume()
        wait(for: [completion], timeout: 3)
        XCTAssertTrue(try outcome.result.get().isComplete)

        let afterSuccess = try MediaConsolidateCommand().prepare(
            project: try makeProject(media: []),
            openMode: .editable,
            projectPackageURL: package
        )
        XCTAssertTrue(afterSuccess.isComplete)
    }

    func testFRMED008LockReleasesAfterCancellation() throws {
        let root = try temporaryDirectory(named: "consolidate-cancel-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.mov")
        let bytes = Data("cancel lock bytes".utf8)
        try bytes.write(to: sourceURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )

        let cancelled = try MediaConsolidateCommand().prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package,
            isCancelled: { true }
        )
        XCTAssertEqual(cancelled.failure?.reason, .cancelled)

        XCTAssertTrue(
            try MediaConsolidateCommand().prepare(
                project: try makeProject(media: []),
                openMode: .editable,
                projectPackageURL: package
            ).isComplete
        )
    }

    func testFRMED008LockReleasesAfterThrownCleanupFailure() throws {
        let root = try temporaryDirectory(named: "consolidate-failure-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        let partialURL = mediaDirectory.appendingPathComponent(
            ".ajar-partial-11111111-2222-3333-4444-555555555555"
        )
        try Data("leftover".utf8).write(to: partialURL)
        let failingCommand = makeLockingCommand(
            fileOperations: ThrowingStaleCleanupOperations()
        )

        XCTAssertThrowsError(
            try failingCommand.prepare(
                project: try makeProject(media: []),
                openMode: .editable,
                projectPackageURL: package
            )
        ) { error in
            guard case .stalePartialCleanupFailed = error as? MediaConsolidateCommandError else {
                return XCTFail("expected stale cleanup failure, received \(error)")
            }
        }

        XCTAssertTrue(
            try MediaConsolidateCommand().prepare(
                project: try makeProject(media: []),
                openMode: .editable,
                projectPackageURL: package
            ).isComplete
        )
    }
}

private func makeLockingCommand(
    fileOperations: any ConsolidateFileOperations
) -> MediaConsolidateCommand {
    let bookmarks = LockingBookmarkStore()
    return MediaConsolidateCommand(
        resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
        hasher: SHA256MediaFileHasher(),
        bookmarkStore: bookmarks,
        fileOperations: fileOperations
    )
}

private struct LockingBookmarkStore: MediaBookmarkStore {
    func createBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8) else {
            throw MediaBookmarkError.resolutionFailed(reason: "invalid test bookmark")
        }
        return MediaBookmarkResolution(url: URL(fileURLWithPath: path), isStale: false)
    }
}

private final class BlockingConsolidateCopyOperations: ConsolidateFileOperations {
    private let base = DefaultConsolidateFileOperations(fileManager: .default)
    private let stateLock = NSLock()
    private let partialCreated = DispatchSemaphore(value: 0)
    private let continueCopy = DispatchSemaphore(value: 0)
    private var storedPartialURL: URL?

    var partialURL: URL? { stateLock.withLock { storedPartialURL } }

    func waitUntilPartialExists() -> DispatchTimeoutResult {
        partialCreated.wait(timeout: .now() + 3)
    }

    func resume() {
        continueCopy.signal()
    }

    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func isDirectory(at url: URL) throws -> Bool { try base.isDirectory(at: url) }
    func isRegularFile(at url: URL) throws -> Bool { try base.isRegularFile(at: url) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try base.copyItem(at: sourceURL, to: destinationURL)
    }

    func copyItem(
        at sourceURL: URL,
        to destinationURL: URL,
        isCancelled: @escaping @Sendable () -> Bool,
        didCreate: (ConsolidateFileIdentity) -> Void,
        progress: @escaping (Int64, Int64) -> Void
    ) throws {
        let bytes = try Data(contentsOf: sourceURL)
        try Data(bytes.prefix(max(1, bytes.count / 2))).write(to: destinationURL)
        didCreate(try ConsolidateFileIdentity.withoutFollowingSymlinks(at: destinationURL))
        stateLock.withLock { storedPartialURL = destinationURL }
        partialCreated.signal()
        _ = continueCopy.wait(timeout: .now() + 3)
        if isCancelled() { throw CancellationError() }
        try bytes.write(to: destinationURL)
        progress(Int64(bytes.count), Int64(bytes.count))
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try base.moveItem(at: sourceURL, to: destinationURL)
    }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
}

private final class ThrowingStaleCleanupOperations: ConsolidateFileOperations {
    private let base = DefaultConsolidateFileOperations(fileManager: .default)

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
        throw NSError(
            domain: "MediaConsolidateLockingTests",
            code: 267,
            userInfo: [NSLocalizedDescriptionKey: "injected stale cleanup failure"]
        )
    }
}

private final class LockedConsolidationOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<MediaConsolidateResult, Error>?

    var result: Result<MediaConsolidateResult, Error> {
        lock.withLock {
            storedResult ?? .failure(LockingTestError.missingResult)
        }
    }

    func set(_ result: Result<MediaConsolidateResult, Error>) {
        lock.withLock { storedResult = result }
    }
}

private enum LockingTestError: Error {
    case missingResult
}
