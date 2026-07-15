// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarMedia

final class MediaConsolidateCancellationTests: XCTestCase {
    func testFRMED008AtomicMoveRemainsTheCompletionBoundary() throws {
        let root = try temporaryDirectory(named: "consolidate-move-boundary")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.mov")
        let bytes = Data("publish before cancellation is observed".utf8)
        try bytes.write(to: sourceURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )
        let cancellation = HashCancellationState()
        let bookmarks = CancellationBookmarkStore()
        let command = MediaConsolidateCommand(
            resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: bookmarks,
            fileOperations: CancelAfterMoveOperations(cancellation: cancellation)
        )

        let result = try command.prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package,
            isCancelled: { cancellation.isCancelled }
        )

        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.consolidatedMediaIDs, [media.id])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(result.publishedFileURLs.first)), bytes)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
    }

    func testFRMED008CancellationDuringExistingSourceReuseHashDoesNotComplete() throws {
        let root = try temporaryDirectory(named: "consolidate-cancel-existing-reuse")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        let sourceURL = mediaDirectory.appendingPathComponent("already.mov")
        let bytes = Data("already consolidated".utf8)
        try bytes.write(to: sourceURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )
        let cancellation = HashCancellationState()
        let hasher = CancellingPathHasher(
            targetURL: sourceURL,
            cancelOnTargetInvocation: 2,
            cancellation: cancellation
        )

        let result = try makeCancellationCommand(hasher: hasher).prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package,
            isCancelled: { cancellation.isCancelled }
        )

        XCTAssertEqual(result.failure?.reason, .cancelled)
        XCTAssertTrue(result.consolidatedMediaIDs.isEmpty)
        XCTAssertNil(result.command)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
    }

    func testFRMED008CancellationDuringCollisionHashDoesNotCompleteOrCopy() throws {
        let root = try temporaryDirectory(named: "consolidate-cancel-collision")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        let mediaDirectory = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        let sourceURL = root.appendingPathComponent("source.mov")
        let sourceBytes = Data("wanted source".utf8)
        try sourceBytes.write(to: sourceURL)
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: sourceBytes)
        )
        let collisionURL = mediaDirectory.appendingPathComponent(
            "\(media.id.uuidString.lowercased()).mov"
        )
        let collisionBytes = Data("unrelated collision".utf8)
        try collisionBytes.write(to: collisionURL)
        let cancellation = HashCancellationState()
        let hasher = CancellingPathHasher(
            targetURL: collisionURL,
            cancelOnTargetInvocation: 1,
            cancellation: cancellation
        )

        let result = try makeCancellationCommand(hasher: hasher).prepare(
            project: try makeProject(media: [media]),
            openMode: .editable,
            projectPackageURL: package,
            isCancelled: { cancellation.isCancelled }
        )

        XCTAssertEqual(result.failure?.reason, .cancelled)
        XCTAssertTrue(result.consolidatedMediaIDs.isEmpty)
        XCTAssertNil(result.command)
        XCTAssertEqual(try Data(contentsOf: collisionURL), collisionBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: mediaDirectory.appendingPathComponent(
                    "\(media.id.uuidString.lowercased())-1.mov"
                ).path
            )
        )
    }

    func testFRMED008ChunkCancellationCleansPartialAndKeepsUndoableSuccess() throws {
        let root = try temporaryDirectory(named: "consolidate-cancel-chunk")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Project.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let firstURL = root.appendingPathComponent("first.mov")
        let secondURL = root.appendingPathComponent("second.mov")
        let firstBytes = Data("first completes".utf8)
        let secondBytes = Data(repeating: 0xA7, count: (3 * 1_024 * 1_024) + 19)
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
        let cancellation = ChunkCancellationRecorder(cancelMediaID: second.id)
        let bookmarks = CancellationBookmarkStore()
        let command = MediaConsolidateCommand(
            resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: bookmarks,
            fileOperations: DefaultConsolidateFileOperations(fileManager: .default)
        )

        let result = try command.prepare(
            project: try makeProject(media: [first, second]),
            openMode: .editable,
            projectPackageURL: package,
            progress: cancellation,
            isCancelled: { cancellation.isCancelled }
        )

        XCTAssertEqual(
            result.failure,
            MediaConsolidateFailure(mediaID: second.id, reason: .cancelled)
        )
        XCTAssertEqual(result.consolidatedMediaIDs, [first.id])
        XCTAssertEqual(cancellation.firstCopiedChunkByteCount, 1_024 * 1_024)
        let files = try FileManager.default.contentsOfDirectory(
            at: package.appendingPathComponent("media", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        let publishedFiles = files.filter {
            $0.lastPathComponent != ".ajar-consolidation.lock"
        }
        XCTAssertEqual(
            publishedFiles.map(\.standardizedFileURL),
            result.publishedFileURLs.map(\.standardizedFileURL)
        )
        XCTAssertFalse(files.contains { $0.lastPathComponent.contains(".ajar-partial") })
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertEqual(try Data(contentsOf: secondURL), secondBytes)

        var history = EditHistory(project: try makeProject(media: [first, second]))
        let edited = try history.apply(try XCTUnwrap(result.command))
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(edited.mediaPool[0].sourceURL, result.publishedFileURLs.first)
        XCTAssertEqual(edited.mediaPool[1], second)
    }

    private func makeCancellationCommand(
        hasher: any MediaFileHashing
    ) -> MediaConsolidateCommand {
        let bookmarks = CancellationBookmarkStore()
        return MediaConsolidateCommand(
            resolver: MediaReferenceResolver(bookmarkStore: bookmarks),
            hasher: hasher,
            bookmarkStore: bookmarks,
            fileOperations: DefaultConsolidateFileOperations(fileManager: .default)
        )
    }
}

private final class CancelAfterMoveOperations: ConsolidateFileOperations {
    private let fileManager = FileManager.default
    private let cancellation: HashCancellationState

    init(cancellation: HashCancellationState) {
        self.cancellation = cancellation
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileExists(at url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }

    func isDirectory(at url: URL) throws -> Bool { try itemType(at: url) == .typeDirectory }

    func isRegularFile(at url: URL) throws -> Bool { try itemType(at: url) == .typeRegular }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        cancellation.cancel()
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    private func itemType(at url: URL) throws -> FileAttributeType? {
        try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }
}

private final class HashCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private final class CancellingPathHasher: MediaFileHashing, @unchecked Sendable {
    private let lock = NSLock()
    private let targetURL: URL
    private let cancelOnTargetInvocation: Int
    private let cancellation: HashCancellationState
    private var targetInvocationCount = 0

    init(
        targetURL: URL,
        cancelOnTargetInvocation: Int,
        cancellation: HashCancellationState
    ) {
        self.targetURL = targetURL.standardizedFileURL
        self.cancelOnTargetInvocation = cancelOnTargetInvocation
        self.cancellation = cancellation
    }

    func contentHash(of fileURL: URL) throws -> ContentHash {
        try SHA256MediaFileHasher().contentHash(of: fileURL)
    }

    func contentHash(
        of fileURL: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> ContentHash {
        if fileURL.standardizedFileURL == targetURL {
            let shouldCancel = lock.withLock { () -> Bool in
                targetInvocationCount += 1
                return targetInvocationCount == cancelOnTargetInvocation
            }
            if shouldCancel {
                cancellation.cancel()
            }
        }
        if isCancelled() {
            throw CancellationError()
        }
        return try SHA256MediaFileHasher().contentHash(
            of: fileURL,
            isCancelled: isCancelled
        )
    }
}

private final class ChunkCancellationRecorder: ConsolidateProgress, @unchecked Sendable {
    private let lock = NSLock()
    private let cancelMediaID: UUID
    private var cancelled = false
    private(set) var firstCopiedChunkByteCount: Int64?

    init(cancelMediaID: UUID) {
        self.cancelMediaID = cancelMediaID
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func consolidateDidUpdate(_ progress: ConsolidateProgressUpdate) {
        guard progress.mediaID == cancelMediaID, progress.copiedByteCount > 0 else { return }
        lock.withLock {
            if firstCopiedChunkByteCount == nil {
                firstCopiedChunkByteCount = progress.copiedByteCount
            }
            cancelled = true
        }
    }
}

private struct CancellationBookmarkStore: MediaBookmarkStore {
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

final class ConsolidationProgressRecorder: ConsolidateProgress {
    private(set) var updates: [ConsolidateProgressUpdate] = []

    func consolidateDidUpdate(_ progress: ConsolidateProgressUpdate) {
        updates.append(progress)
    }
}
