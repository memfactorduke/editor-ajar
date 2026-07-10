// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarMedia

final class MediaRelinkCommandTests: XCTestCase {
    func testFRMED007RelinkHashMatchPreparesStableIDBookmarkEdit() throws {
        let root = try temporaryDirectory(named: "relink-match")
        defer { try? FileManager.default.removeItem(at: root) }
        let candidateURL = root.appendingPathComponent("renamed.mov")
        let bytes = Data("same original bytes".utf8)
        try bytes.write(to: candidateURL)
        let original = try makeMediaRef(
            sourceURL: root.appendingPathComponent("old.mov"),
            contentHash: ContentHash.sha256(data: bytes),
            availability: .offline
        )
        let project = try makeProject(media: [original])
        let workflow = makeRelinkCommand()

        guard case .ready(let command, let match) = try workflow.prepare(
            mediaReferenceID: original.id,
            newFileURL: candidateURL,
            in: project,
            mismatchPolicy: .warn
        ) else {
            return XCTFail("expected hash-matched relink command")
        }

        XCTAssertEqual(match, .contentHash)
        var history = EditHistory(project: project)
        let edited = try history.apply(command)
        let relinked = try XCTUnwrap(edited.mediaPool.first)
        XCTAssertEqual(relinked.id, original.id)
        XCTAssertEqual(relinked.sourceURL, candidateURL)
        XCTAssertEqual(relinked.contentHash, original.contentHash)
        XCTAssertEqual(relinked.bookmark, TestBookmarkStore.bookmark(for: candidateURL))
        XCTAssertEqual(relinked.availability, .available)
        XCTAssertEqual(history.undo(), project)
    }

    func testFRMED007RelinkHashMismatchWarnsThenExplicitOverrideUpdatesHash() throws {
        let root = try temporaryDirectory(named: "relink-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let candidateURL = root.appendingPathComponent("interview.mov")
        let candidateBytes = Data("different bytes".utf8)
        try candidateBytes.write(to: candidateURL)
        let original = try makeMediaRef(
            sourceURL: root.appendingPathComponent("interview.mov"),
            contentHash: ContentHash.sha256(data: Data("stored bytes".utf8)),
            availability: .offline
        )
        let project = try makeProject(media: [original])
        let workflow = makeRelinkCommand()

        guard case .warning(let warning) = try workflow.prepare(
            mediaReferenceID: original.id,
            newFileURL: candidateURL,
            in: project,
            mismatchPolicy: .warn
        ) else {
            return XCTFail("expected typed mismatch warning")
        }
        guard case .contentHashMismatch(let expected, let actual) = warning.reason else {
            return XCTFail("expected contentHashMismatch warning")
        }
        XCTAssertEqual(expected, original.contentHash)
        XCTAssertEqual(actual, ContentHash.sha256(data: candidateBytes))

        guard case .ready(let overrideCommand, let match) = try workflow.prepare(
            mediaReferenceID: original.id,
            newFileURL: candidateURL,
            in: project,
            mismatchPolicy: .override
        ) else {
            return XCTFail("expected explicit override command")
        }
        XCTAssertEqual(match, .overriddenContentHash)
        let edited = try apply(overrideCommand, to: project)
        XCTAssertEqual(edited.mediaPool.first?.contentHash, actual)
        XCTAssertEqual(edited.mediaPool.first?.id, original.id)
        XCTAssertEqual(edited.mediaPool.first?.metadata, original.metadata)
    }

    func testFRMED007RelinkMismatchWarnsBeforeBookmarkCreation() throws {
        let root = try temporaryDirectory(named: "relink-warning-before-bookmark")
        defer { try? FileManager.default.removeItem(at: root) }
        let candidateURL = root.appendingPathComponent("interview.mov")
        let candidateBytes = Data("different bytes".utf8)
        try candidateBytes.write(to: candidateURL)
        let original = try makeMediaRef(
            sourceURL: root.appendingPathComponent("interview.mov"),
            contentHash: ContentHash.sha256(data: Data("stored bytes".utf8)),
            availability: .offline
        )
        let workflow = MediaRelinkCommand(
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: FailingBookmarkStore()
        )

        guard case .warning(let warning) = try workflow.prepare(
            mediaReferenceID: original.id,
            newFileURL: candidateURL,
            in: try makeProject(media: [original]),
            mismatchPolicy: .warn
        ) else {
            return XCTFail("expected mismatch warning without bookmark creation")
        }

        guard case .contentHashMismatch = warning.reason else {
            return XCTFail("expected contentHashMismatch warning")
        }
    }

    func testFRMED007BatchRelinkRecursesAndRequiresFilenamePlusHash() throws {
        let root = try temporaryDirectory(named: "batch-relink")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let matchingURL = nested.appendingPathComponent("interview.mov")
        let matchingBytes = Data("matching interview".utf8)
        try matchingBytes.write(to: matchingURL)
        let wrongNameURL = root.appendingPathComponent("renamed.mov")
        try matchingBytes.write(to: wrongNameURL)
        let wrongHashURL = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongHashURL, withIntermediateDirectories: true)
        try Data("wrong".utf8).write(to: wrongHashURL.appendingPathComponent("interview.mov"))

        let matched = try makeMediaRef(
            sourceURL: URL(fileURLWithPath: "/old/interview.mov"),
            contentHash: ContentHash.sha256(data: matchingBytes),
            availability: .offline
        )
        let unmatched = try makeMediaRef(
            sourceURL: URL(fileURLWithPath: "/old/renamed.mov"),
            contentHash: ContentHash.sha256(data: Data("not matching".utf8)),
            availability: .offline
        )
        let alreadyOnline = try makeMediaRef(
            sourceURL: URL(fileURLWithPath: "/online/interview.mov"),
            contentHash: ContentHash.sha256(data: matchingBytes),
            availability: .available
        )
        let project = try makeProject(media: [matched, unmatched, alreadyOnline])

        let result = try makeRelinkCommand().prepareBatch(folderURL: root, in: project)

        XCTAssertEqual(result.relinkedMediaIDs, [matched.id])
        XCTAssertEqual(result.unresolvedMediaIDs, [unmatched.id])
        let command = try XCTUnwrap(result.command)
        let edited = try apply(command, to: project)
        XCTAssertEqual(
            edited.mediaPool[0].sourceURL?.resolvingSymlinksInPath(),
            matchingURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(edited.mediaPool[0].availability, .available)
        XCTAssertEqual(edited.mediaPool[1], unmatched)
        XCTAssertEqual(edited.mediaPool[2], alreadyOnline)
    }

    func testFRMED007BatchRelinkRehashesSelectedCandidateBeforeAcceptingIt() throws {
        let root = try temporaryDirectory(named: "batch-relink-mutation")
        defer { try? FileManager.default.removeItem(at: root) }
        let candidateURL = root.appendingPathComponent("interview.mov")
        let originalBytes = Data("matching interview".utf8)
        try originalBytes.write(to: candidateURL)
        let media = try makeMediaRef(
            sourceURL: URL(fileURLWithPath: "/old/interview.mov"),
            contentHash: ContentHash.sha256(data: originalBytes),
            availability: .offline
        )
        let workflow = MediaRelinkCommand(
            hasher: MutatingAfterFirstHashHasher(
                mutatedBytes: Data("changed during scan".utf8)
            ),
            bookmarkStore: TestBookmarkStore()
        )

        let result = try workflow.prepareBatch(
            folderURL: root,
            in: try makeProject(media: [media])
        )

        XCTAssertNil(result.command)
        XCTAssertEqual(result.relinkedMediaIDs, [])
        XCTAssertEqual(result.unresolvedMediaIDs, [media.id])
    }

    private func makeRelinkCommand() -> MediaRelinkCommand {
        MediaRelinkCommand(
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: TestBookmarkStore()
        )
    }
}

final class MediaReferenceResolverTests: XCTestCase {
    func testFRMED007MissingURLBecomesOfflineAndLaterResolutionRestoresAvailable() throws {
        let root = try temporaryDirectory(named: "resolver-transition")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.mov")
        let media = try makeMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: Data("source".utf8))
        )
        let resolver = MediaReferenceResolver(bookmarkStore: TestBookmarkStore())

        guard case .offline(let offline, let failure) = resolver.resolve(media) else {
            return XCTFail("expected missing source to become offline")
        }
        XCTAssertEqual(
            failure,
            .sourceMissing(mediaID: media.id, lastKnownURL: sourceURL)
        )
        XCTAssertEqual(offline.availability, .offline)

        try Data("source".utf8).write(to: sourceURL)
        guard case .resolved(let restored, let resolvedURL) = resolver.resolve(offline) else {
            return XCTFail("expected restored URL to become available")
        }
        XCTAssertEqual(resolvedURL, sourceURL)
        XCTAssertEqual(restored.id, media.id)
        XCTAssertEqual(restored.availability, .available)
    }

    func testFRMED007BookmarkAndURLFailureReturnsTypedOfflineState() throws {
        let media = try makeMediaRef(
            sourceURL: URL(fileURLWithPath: "/definitely/missing/source.mov"),
            contentHash: ContentHash.sha256(data: Data("source".utf8)),
            bookmark: Data([0xFF])
        )
        let resolver = MediaReferenceResolver(bookmarkStore: FailingBookmarkStore())

        guard case .offline(let offline, let failure) = resolver.resolve(media) else {
            return XCTFail("expected invalid bookmark and URL to become offline")
        }
        XCTAssertEqual(failure, .bookmarkResolutionFailed(mediaID: media.id))
        XCTAssertTrue(offline.isOffline)
    }
}

private struct TestBookmarkStore: MediaBookmarkStore {
    static func bookmark(for url: URL) -> Data {
        Data(url.path.utf8)
    }

    func createBookmark(for url: URL) throws -> Data {
        Self.bookmark(for: url)
    }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8) else {
            throw MediaBookmarkError.resolutionFailed(reason: "invalid test bookmark")
        }
        return MediaBookmarkResolution(url: URL(fileURLWithPath: path), isStale: false)
    }
}

private struct FailingBookmarkStore: MediaBookmarkStore {
    func createBookmark(for url: URL) throws -> Data {
        throw MediaBookmarkError.creationFailed(url: url, reason: "injected")
    }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        throw MediaBookmarkError.resolutionFailed(reason: "injected")
    }
}

private final class MutatingAfterFirstHashHasher: MediaFileHashing {
    private let mutatedBytes: Data
    private var hashCount = 0

    init(mutatedBytes: Data) {
        self.mutatedBytes = mutatedBytes
    }

    func contentHash(of url: URL) throws -> ContentHash {
        hashCount += 1
        let hash = ContentHash.sha256(data: try Data(contentsOf: url))
        if hashCount == 1 {
            try mutatedBytes.write(to: url)
        }
        return hash
    }
}

func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("editor-ajar-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeMediaRef(
    id: UUID = UUID(),
    sourceURL: URL,
    contentHash: ContentHash,
    bookmark: Data? = nil,
    availability: MediaAvailability = .available
) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: sourceURL,
        bookmark: bookmark,
        contentHash: contentHash,
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 64, height: 36),
            frameRate: try FrameRate(frames: 24),
            duration: try RationalTime(value: 1, timescale: 1),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        ),
        availability: availability
    )
}

func makeProject(media: [MediaRef]) throws -> Project {
    Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 64, height: 36),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: media,
        sequences: [
            Sequence(
                id: UUID(),
                name: "Media workflow",
                videoTracks: [],
                audioTracks: [],
                markers: [],
                timebase: try FrameRate(frames: 24)
            )
        ]
    )
}
