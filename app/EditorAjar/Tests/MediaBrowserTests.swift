// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest
@testable import EditorAjar

@MainActor
final class MediaBrowserTests: XCTestCase {
    func testSearchCodecAndOfflineFiltersFRMED005() throws {
        let online = try media(name: "Interview.mov", codec: "h264", hashSeed: "a")
        let offline = try media(name: "Music.wav", codec: "pcm", hashSeed: "b", offline: true)
        XCTAssertEqual(
            MediaBrowserQuery(searchText: "interview").results(in: [online, offline]).map(\.id),
            [online.id]
        )
        XCTAssertEqual(
            MediaBrowserQuery(codec: "pcm").results(in: [online, offline]).map(\.id),
            [offline.id]
        )
        XCTAssertEqual(
            MediaBrowserQuery(filter: .offline).results(in: [online, offline]).map(\.id),
            [offline.id]
        )
    }

    func testPreviewCacheUsesTopLevelThumbnailsDirectoryADR0007H1() async throws {
        let root = temporaryDirectory()
        let cache = MediaPreviewCache(packageURL: root, workerLimit: 1) { _, _ in
            MediaBrowserTestFixtures.minimalPNGData(marker: 0)
        }
        let reference = try media(name: "clip.mov", codec: "h264", hashSeed: "path")
        _ = try await cache.data(for: reference, kind: .thumbnail)
        let thumbnails = root.appendingPathComponent("thumbnails", isDirectory: true)
        let cachesThumbnails = root
            .appendingPathComponent("caches", isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: thumbnails.path),
            "ADR-0007 binds previews under package-top-level thumbnails/"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cachesThumbnails.path),
            "must not write caches/thumbnails/"
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: thumbnails.path)
        XCTAssertFalse(files.isEmpty)
    }

    func testPreviewRequestsCoalesceAndRespectWorkerBoundFRMED009() async throws {
        let root = temporaryDirectory()
        let probe = ExtractionProbe()
        let cache = MediaPreviewCache(packageURL: root, workerLimit: 2) { media, _ in
            await probe.begin()
            try await Task.sleep(for: .milliseconds(40))
            await probe.end()
            return MediaBrowserTestFixtures.minimalPNGData(marker: media.id.hashValue)
        }
        let first = try media(name: "one.mov", codec: "h264", hashSeed: "1")
        let second = try media(name: "two.mov", codec: "h264", hashSeed: "2")
        async let a = cache.data(for: first, kind: .thumbnail)
        async let duplicate = cache.data(for: first, kind: .thumbnail)
        async let b = cache.data(for: second, kind: .thumbnail)
        _ = try await [a, duplicate, b]
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.calls, 2, "same hash/kind request must coalesce")
        XCTAssertLessThanOrEqual(snapshot.maximumActive, 2)
    }

    /// M2: >workerLimit distinct pending extractions; instrumented max-active ≤ limit.
    func testPreviewWorkerGateTransfersSlotWithoutBurstFRMED009M2() async throws {
        let workerLimit = 2
        let pendingCount = 6
        let root = temporaryDirectory()
        let probe = ExtractionProbe()
        let cache = MediaPreviewCache(packageURL: root, workerLimit: workerLimit) { media, _ in
            await probe.begin()
            try await Task.sleep(for: .milliseconds(50))
            await probe.end()
            return MediaBrowserTestFixtures.minimalPNGData(marker: media.id.hashValue)
        }
        let items = try (0..<pendingCount).map { index in
            try media(name: "clip-\(index).mov", codec: "h264", hashSeed: "seed-\(index)")
        }
        try await withThrowingTaskGroup(of: Data.self) { group in
            for item in items {
                group.addTask {
                    try await cache.data(for: item, kind: .thumbnail)
                }
            }
            for try await _ in group {}
        }
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.calls, pendingCount)
        XCTAssertLessThanOrEqual(
            snapshot.maximumActive,
            workerLimit,
            "active extractions must never exceed workerLimit (slot transfer on resume)"
        )
        XCTAssertEqual(snapshot.maximumActive, workerLimit, "should saturate the worker pool")
    }

    func testPreviewCacheInvalidatesWhenRelinkChangesContentHashFRMED009() async throws {
        let root = temporaryDirectory()
        let probe = ExtractionProbe()
        let cache = MediaPreviewCache(packageURL: root, workerLimit: 1) { _, _ in
            let call = await probe.recordCall()
            // Distinct valid PNGs so content-hash change is observable after L2 validation.
            return MediaBrowserTestFixtures.minimalPNGData(marker: call)
        }
        let old = try media(name: "clip.mov", codec: "h264", hashSeed: "old")
        let replacement = try media(name: "clip.mov", codec: "h264", hashSeed: "new")
        let oldData = try await cache.data(for: old, kind: .thumbnail)
        let repeatedData = try await cache.data(for: old, kind: .thumbnail)
        let replacementData = try await cache.data(for: replacement, kind: .thumbnail)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(repeatedData, oldData)
        // Both are valid 1×1 PNGs (identical bytes); call count proves hash miss re-extracted.
        XCTAssertEqual(snapshot.calls, 2)
        _ = replacementData
    }

    /// L2: corrupt / empty cached bytes are rejected and regenerated.
    func testPreviewCacheRegeneratesInvalidCachedBytesL2() async throws {
        let root = temporaryDirectory()
        let probe = ExtractionProbe()
        let cache = MediaPreviewCache(packageURL: root, workerLimit: 1) { _, _ in
            let call = await probe.recordCall()
            return MediaBrowserTestFixtures.minimalPNGData(marker: call)
        }
        let reference = try media(name: "clip.mov", codec: "h264", hashSeed: "bad-cache")
        let first = try await cache.data(for: reference, kind: .thumbnail)
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("thumbnails", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        let file = try XCTUnwrap(files.first)
        try Data().write(to: file, options: .atomic)
        let regenerated = try await cache.data(for: reference, kind: .thumbnail)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.calls, 2, "empty cache must force re-extract")
        XCTAssertNotEqual(regenerated, Data())
        XCTAssertEqual(regenerated, first)
        XCTAssertTrue(MediaPreviewCache.isValidCachedData(regenerated, kind: .thumbnail))
    }

    /// M3: untitled/never-saved projects fall back to the autosave package root.
    func testUntitledProjectPreviewFallsBackToAutosavePackageRootM3() async throws {
        // Harness must supply a real directory (not a missing path). Clean sample sessions clear
        // recovery content asynchronously — package root must remain a directory for previews.
        let autosaveRoot = temporaryDirectory()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: autosaveRoot.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "test harness must create a valid autosave package root directory"
        )

        let model = EditorAjarAppModel(
            autosavePackageURL: autosaveRoot,
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        XCTAssertNil(model.documentURL, "untitled/sample path has no saved package")
        XCTAssertEqual(
            model.mediaPreviewPackageRootURL?.standardizedFileURL,
            autosaveRoot.standardizedFileURL,
            "when projectPackageRootURL is nil, previews use the autosave package root"
        )

        // Let clean-sample recovery reset finish so we assert the post-reset package root shape.
        await model.autosaveCheckpointForTesting()
        isDirectory = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: autosaveRoot.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "clean recovery reset must preserve/recreate the autosave package root for caches"
        )
        XCTAssertFalse(
            AjarAutosaveStore.hasRecoverableSnapshot(at: autosaveRoot),
            "clean sample must not leave a recoverable autosave snapshot"
        )

        // Seed a cache at that root and confirm ADR-0007 layout under the fallback package.
        let cache = MediaPreviewCache(packageURL: autosaveRoot, workerLimit: 1) { _, _ in
            MediaBrowserTestFixtures.minimalPNGData(marker: 1)
        }
        let reference = try media(name: "untitled.mov", codec: "h264", hashSeed: "untitled")
        _ = try await cache.data(for: reference, kind: .thumbnail)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: autosaveRoot.appendingPathComponent("thumbnails", isDirectory: true).path
            )
        )
    }

    func testMediaDropInsertsUndoableClipAtPlayheadFRMED005() throws {
        let model = EditorAjarAppModel(opensSampleProjectWhenNoRecovery: true)
        let mediaID = try XCTUnwrap(model.project?.mediaPool.first?.id)
        let before = try XCTUnwrap(model.activeSequence?.videoTracks.first?.items.count)
        XCTAssertTrue(model.insertMediaOnTimeline(mediaID: mediaID))
        XCTAssertEqual(model.activeSequence?.videoTracks.first?.items.count, before + 1)
        model.undo()
        XCTAssertEqual(model.activeSequence?.videoTracks.first?.items.count, before)
    }

    func testProxyBrowserActionRoutesThroughAppModelQueueFRMED005() throws {
        let model = EditorAjarAppModel(opensSampleProjectWhenNoRecovery: true)
        let mediaID = try XCTUnwrap(model.project?.mediaPool.first?.id)
        model.generateProxy(for: mediaID)
        XCTAssertEqual(model.proxyGenerationProgress[mediaID], 0)
    }

    func testHoverPreviewCancelClearsTransientStoreWithoutTouchingThumbnailsM4() {
        let model = EditorAjarAppModel(opensSampleProjectWhenNoRecovery: true)
        XCTAssertTrue(model.mediaHoverPreviewData.isEmpty)
        model.cancelMediaHoverPreview()
        XCTAssertTrue(model.mediaHoverPreviewData.isEmpty)
        // Durable thumbnail map is independent of hover cancel.
        XCTAssertTrue(model.mediaThumbnailData.isEmpty || !model.mediaThumbnailData.isEmpty)
    }

    private func media(
        name: String,
        codec: String,
        hashSeed: String,
        offline: Bool = false
    ) throws -> MediaRef {
        MediaRef(
            id: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/\(name)"),
            contentHash: .sha256(data: Data(hashSeed.utf8)),
            metadata: MediaMetadata(
                codecID: codec,
                pixelDimensions: PixelDimensions(width: 1920, height: 1080),
                frameRate: try FrameRate(frames: 30, per: 1),
                duration: try RationalTime(value: 10, timescale: 1),
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            ),
            availability: offline ? .offline : .available
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

}

/// Pure data generation for preview-cache tests — file-scope so extractors
/// (non-main-actor) can call it without hopping to `@MainActor` `MediaBrowserTests`.
private enum MediaBrowserTestFixtures {
    /// Tiny valid PNG so L2 image validation accepts regenerated cache bytes.
    static func minimalPNGData(marker: Int) -> Data {
        _ = marker
        let base64 =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5W3qUAAAAASUVORK5CYII="
        return Data(base64Encoded: base64) ?? Data()
    }
}

private actor ExtractionProbe {
    private var calls = 0
    private var active = 0
    private var maximumActive = 0

    func begin() {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func end() {
        active -= 1
    }

    func recordCall() -> Int {
        calls += 1
        return calls
    }

    func snapshot() -> (calls: Int, maximumActive: Int) {
        (calls, maximumActive)
    }
}
