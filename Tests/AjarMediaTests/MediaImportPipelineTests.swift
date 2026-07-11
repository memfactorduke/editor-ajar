// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarMedia

final class MediaImportPipelineTests: XCTestCase {
    func testFRMED001ImportsRepoStillFixtureWithIDHashBookmarkAndMetadata() async throws {
        let fixtureURL = repoStillFixtureURL()
        let mediaID = try XCTUnwrap(
            UUID(uuidString: "23400000-0000-4000-8000-000000000001")
        )
        let pipeline = MediaImportPipeline(
            probe: AVFoundationMediaProbe(),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: TestImportBookmarkStore(),
            makeMediaID: { mediaID }
        )

        let batch = await pipeline.prepareImport(from: [fixtureURL], existingMedia: [])

        let item = try XCTUnwrap(batch.summary.imported.first)
        XCTAssertEqual(batch.summary.imported.count, 1)
        XCTAssertEqual(item.sourceURL, fixtureURL)
        XCTAssertEqual(item.mediaReference.id, mediaID)
        XCTAssertEqual(
            item.mediaReference.contentHash,
            try SHA256MediaFileHasher().contentHash(of: fixtureURL)
        )
        XCTAssertEqual(
            item.mediaReference.bookmark,
            TestImportBookmarkStore.bookmark(for: fixtureURL)
        )
        XCTAssertEqual(item.mediaReference.metadata.codecID, "png")
        XCTAssertGreaterThan(item.mediaReference.metadata.pixelDimensions?.width ?? 0, 0)
        XCTAssertGreaterThan(item.mediaReference.metadata.pixelDimensions?.height ?? 0, 0)
        XCTAssertFalse(item.mediaReference.metadata.isVariableFrameRate)
        XCTAssertNil(item.mediaReference.metadata.conformedFrameRate)
        XCTAssertEqual(item.mediaReference.sourceURL, fixtureURL)
    }

    func testFRMED001PreparedImportIsOneUndoableBatch() async throws {
        let root = try temporaryDirectory(named: "undo-batch")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.mov")
        let secondURL = root.appendingPathComponent("second.mov")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let probe = StubMediaProbe(result: try constantProbeResult())
        let pipeline = MediaImportPipeline(
            probe: probe,
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: TestImportBookmarkStore()
        )
        let project = try emptyProject()

        let batch = await pipeline.prepareImport(
            from: [firstURL, secondURL],
            existingMedia: project.mediaPool
        )
        let command = try XCTUnwrap(batch.command)
        var history = EditHistory(project: project)
        let imported = try history.apply(command)

        XCTAssertEqual(imported.mediaPool.count, 2)
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(history.undo()?.mediaPool, [])
        XCTAssertEqual(try history.redo()?.mediaPool, imported.mediaPool)
    }

    func testFRMED001DeduplicatesExistingAndSameBatchContentWithoutRelinking() async throws {
        let root = try temporaryDirectory(named: "dedup")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.mov")
        let duplicateURL = root.appendingPathComponent("different-name.mov")
        let bytes = Data("identical bytes".utf8)
        try bytes.write(to: firstURL)
        try bytes.write(to: duplicateURL)
        let metadata = try constantProbeResult().metadata
        let existingURL = URL(fileURLWithPath: "/kept/original.mov")
        let existingBookmark = Data([0xAA, 0xBB])
        let existing = MediaRef(
            id: UUID(),
            sourceURL: existingURL,
            bookmark: existingBookmark,
            contentHash: ContentHash.sha256(data: bytes),
            metadata: metadata
        )
        let pipeline = MediaImportPipeline(
            probe: StubMediaProbe(result: MediaProbeResult(metadata: metadata)),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: TestImportBookmarkStore()
        )

        let existingBatch = await pipeline.prepareImport(
            from: [duplicateURL],
            existingMedia: [existing]
        )
        XCTAssertNil(existingBatch.command)
        XCTAssertEqual(existingBatch.summary.skippedDuplicates.count, 1)
        XCTAssertEqual(
            existingBatch.summary.skippedDuplicates.first?.existingSourceURL,
            existingURL
        )
        XCTAssertEqual(existing.bookmark, existingBookmark)

        let sameBatch = await pipeline.prepareImport(
            from: [firstURL, duplicateURL],
            existingMedia: []
        )
        XCTAssertEqual(sameBatch.summary.imported.count, 1)
        XCTAssertEqual(sameBatch.summary.skippedDuplicates.count, 1)
    }

    func testFRMED010VFRConformsFromStatisticsAndPreservesProbeChoice() async throws {
        let root = try temporaryDirectory(named: "vfr")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("phone.mov")
        try Data("vfr source".utf8).write(to: sourceURL)
        let metadata = MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 30),
            duration: try RationalTime(value: 1_001, timescale: 100),
            colorSpace: .rec709,
            audioChannelLayout: AjarCore.AudioChannelLayout(channelCount: 2),
            isVariableFrameRate: true,
            conformedFrameRate: nil
        )
        let pipeline = MediaImportPipeline(
            probe: StubMediaProbe(
                result: MediaProbeResult(metadata: metadata, videoFrameCount: 300)
            ),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: TestImportBookmarkStore()
        )

        let batch = await pipeline.prepareImport(from: [sourceURL], existingMedia: [])

        let imported = try XCTUnwrap(batch.summary.imported.first?.mediaReference)
        let expected = try FrameRate(frames: 30_000, per: 1_001)
        XCTAssertTrue(imported.metadata.isVariableFrameRate)
        XCTAssertEqual(imported.metadata.conformedFrameRate, expected)
        XCTAssertEqual(batch.summary.vfrConformed.first?.conformedFrameRate, expected)

        let provided = try FrameRate(frames: 25)
        let providedMetadata = MediaMetadata(
            codecID: metadata.codecID,
            pixelDimensions: metadata.pixelDimensions,
            frameRate: metadata.frameRate,
            duration: metadata.duration,
            colorSpace: metadata.colorSpace,
            audioChannelLayout: metadata.audioChannelLayout,
            isVariableFrameRate: true,
            conformedFrameRate: provided
        )
        XCTAssertEqual(
            MediaFrameRateConformer.conform(
                MediaProbeResult(metadata: providedMetadata, videoFrameCount: 300)
            )?.conformedFrameRate,
            provided
        )

    }

    func testFRMED010ConformStatisticsUseVideoTrackDurationInsteadOfLongAudioTail() throws {
        let metadata = MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 30),
            duration: try RationalTime(value: 20, timescale: 1),
            colorSpace: .rec709,
            audioChannelLayout: AjarCore.AudioChannelLayout(channelCount: 2),
            isVariableFrameRate: true,
            conformedFrameRate: nil
        )
        XCTAssertEqual(
            MediaFrameRateConformer.conform(
                MediaProbeResult(
                    metadata: metadata,
                    videoFrameCount: 300,
                    videoDuration: try RationalTime(value: 10, timescale: 1)
                )
            )?.conformedFrameRate,
            try FrameRate(frames: 30)
        )
    }

    func testFRMED003UnsupportedFormatReturnsTypedImportFailure() async throws {
        let root = try temporaryDirectory(named: "unsupported")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("legacy.mkv")
        try Data("not native media".utf8).write(to: sourceURL)
        let pipeline = MediaImportPipeline(
            probe: StubMediaProbe(error: .unsupportedFormat(sourceURL)),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: TestImportBookmarkStore()
        )

        let batch = await pipeline.prepareImport(from: [sourceURL], existingMedia: [])

        XCTAssertNil(batch.command)
        XCTAssertEqual(batch.summary.imported, [])
        XCTAssertEqual(
            batch.summary.failed,
            [
                FailedMediaImportItem(
                    sourceURL: sourceURL,
                    error: .unsupportedFormat(sourceURL)
                )
            ]
        )
    }

    func testFRMED003NativeProbeReportsUnsupportedFormatWithoutFFmpegFallback() async throws {
        let root = try temporaryDirectory(named: "native-unsupported")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("legacy.mkv")
        try Data("not a media container".utf8).write(to: sourceURL)
        let pipeline = MediaImportPipeline(
            probe: AVFoundationMediaProbe(),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: TestImportBookmarkStore()
        )

        let batch = await pipeline.prepareImport(from: [sourceURL], existingMedia: [])

        XCTAssertNil(batch.command)
        XCTAssertEqual(batch.summary.failed.first?.error, .unsupportedFormat(sourceURL))
    }

    func testFRMED010TimingStatisticsSortBFramePresentationOrderBeforeVFRDecision() {
        // Compressed H.264 samples can arrive in decode order. Sorting PTS values prevents a
        // normal CFR GOP with B-frames from looking variable at the import boundary.
        let frame = 1.0 / 30.0
        let decodeOrder = [0, 3, 1, 2, 6, 4, 5].map { Double($0) * frame }

        let facts = SampleTimingStatistics(presentationSeconds: decodeOrder).facts

        XCTAssertEqual(facts.frameCount, 7)
        XCTAssertFalse(facts.isVariableFrameRate)
        XCTAssertEqual(facts.averageFrameRate, try? FrameRate(frames: 30))
    }

    func testFRMED001FolderImportRecursesAndReportsDeterminateProgress() async throws {
        let root = try temporaryDirectory(named: "folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let firstURL = root.appendingPathComponent("a.mov")
        let secondURL = nested.appendingPathComponent("b.wav")
        try Data("video".utf8).write(to: firstURL)
        try Data("audio".utf8).write(to: secondURL)
        let recorder = ProgressRecorder()
        let pipeline = MediaImportPipeline(
            probe: StubMediaProbe(result: try constantProbeResult()),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: TestImportBookmarkStore()
        )

        let batch = await pipeline.prepareImport(
            from: [root],
            existingMedia: [],
            progress: { snapshot in
                await recorder.append(snapshot)
            }
        )
        let snapshots = await recorder.snapshots()

        XCTAssertEqual(
            batch.summary.imported.map { $0.sourceURL.resolvingSymlinksInPath() },
            [firstURL, secondURL].map { $0.resolvingSymlinksInPath() }
        )
        XCTAssertEqual(snapshots.first?.phase, .discovering)
        XCTAssertEqual(snapshots.dropFirst().first?.phase, .importing)
        XCTAssertEqual(snapshots.dropFirst().first?.completedUnitCount, 0)
        XCTAssertEqual(snapshots.last?.completedUnitCount, 2)
        XCTAssertEqual(snapshots.last?.totalUnitCount, 2)
        XCTAssertEqual(snapshots.last?.fractionCompleted, 1)
    }

    private func repoStillFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden/single-clip-blue/reference.png")
    }

    private func constantProbeResult() throws -> MediaProbeResult {
        MediaProbeResult(
            metadata: MediaMetadata(
                codecID: "h264",
                pixelDimensions: PixelDimensions(width: 1_280, height: 720),
                frameRate: try FrameRate(frames: 30),
                duration: try RationalTime(value: 5, timescale: 1),
                colorSpace: .rec709,
                audioChannelLayout: AjarCore.AudioChannelLayout(channelCount: 2),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            ),
            videoFrameCount: 150
        )
    }

    private func emptyProject() throws -> Project {
        Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: try FrameRate(frames: 30),
                resolution: PixelDimensions(width: 1_920, height: 1_080),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [],
            sequences: []
        )
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-import-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct StubMediaProbe: MediaProbing {
    let result: MediaProbeResult?
    let error: MediaProbeError?

    init(result: MediaProbeResult) {
        self.result = result
        error = nil
    }

    init(error: MediaProbeError) {
        result = nil
        self.error = error
    }

    func probe(_ sourceURL: URL) async throws -> MediaProbeResult {
        if let error {
            throw error
        }
        guard let result else {
            throw MediaProbeError.metadataUnavailable(
                url: sourceURL,
                reason: "stub result missing"
            )
        }
        return result
    }
}

private struct TestImportBookmarkStore: MediaBookmarkStore {
    static func bookmark(for url: URL) -> Data {
        Data(url.standardizedFileURL.path.utf8)
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

private actor ProgressRecorder {
    private var values: [MediaImportProgress] = []

    func append(_ value: MediaImportProgress) {
        values.append(value)
    }

    func snapshots() -> [MediaImportProgress] {
        values
    }
}
