// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarMediaImportAppModelTests: XCTestCase {
    func testFRMED001AppImportAppliesOneUndoableBatchAndPresentsSummary() async throws {
        let root = try temporaryDirectory(named: "undo")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("one.mov")
        let secondURL = root.appendingPathComponent("two.wav")
        try Data("first imported bytes".utf8).write(to: firstURL)
        try Data("second imported bytes".utf8).write(to: secondURL)
        let pipeline = MediaImportPipeline(
            probe: AppModelImportProbe(result: try constantProbeResult()),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: AppModelImportBookmarkStore()
        )
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaImportPipeline: pipeline,
            opensSampleProjectWhenNoRecovery: true
        )
        let originalCount = try XCTUnwrap(model.project?.mediaPool.count)

        await model.importMediaAndWait(from: [firstURL, secondURL])

        XCTAssertEqual(model.project?.mediaPool.count, originalCount + 2)
        XCTAssertEqual(model.mediaImportSummary?.imported.count, 2)
        XCTAssertTrue(model.isMediaImportSummaryPresented)
        XCTAssertEqual(model.undoMenuTitle, "Undo Import Media")

        model.undo()
        XCTAssertEqual(model.project?.mediaPool.count, originalCount)
    }

    func testFRMED001FolderImportPublishesDiscoveringAndDeterminateProgress() async throws {
        let root = try temporaryDirectory(named: "progress")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: root.appendingPathComponent("one.mov"))
        try Data("two".utf8).write(to: nested.appendingPathComponent("two.mov"))
        let pipeline = MediaImportPipeline(
            probe: AppModelImportProbe(
                result: try constantProbeResult(),
                delayNanoseconds: 80_000_000
            ),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: AppModelImportBookmarkStore()
        )
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaImportPipeline: pipeline,
            opensSampleProjectWhenNoRecovery: true
        )

        model.importMedia(from: [root])
        XCTAssertTrue(model.isImportingMedia)
        XCTAssertEqual(model.mediaImportProgress?.phase, .discovering)

        try await waitUntil {
            model.mediaImportProgress?.phase == .importing
                && model.mediaImportProgress?.totalUnitCount == 2
        }
        XCTAssertEqual(model.mediaImportProgress?.completedUnitCount, 0)

        try await waitUntil { !model.isImportingMedia }
        XCTAssertEqual(model.mediaImportSummary?.imported.count, 2)
        XCTAssertNil(model.mediaImportProgress)
    }

    func testFRMED010AppSummarySurfacesStoredVFRConformDecision() async throws {
        let root = try temporaryDirectory(named: "vfr")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("phone.mov")
        try Data("variable frame timing".utf8).write(to: sourceURL)
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
            probe: AppModelImportProbe(
                result: MediaProbeResult(metadata: metadata, videoFrameCount: 300)
            ),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: AppModelImportBookmarkStore()
        )
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaImportPipeline: pipeline,
            opensSampleProjectWhenNoRecovery: true
        )

        await model.importMediaAndWait(from: [sourceURL])

        let expected = try FrameRate(frames: 30_000, per: 1_001)
        XCTAssertEqual(model.mediaImportSummary?.vfrConformed.first?.conformedFrameRate, expected)
        XCTAssertEqual(model.project?.mediaPool.last?.metadata.conformedFrameRate, expected)
        XCTAssertTrue(model.project?.mediaPool.last?.metadata.isVariableFrameRate == true)
    }

    func testFRMED003UnsupportedFormatSummaryUsesLocalizedClearGapMessage() async throws {
        let root = try temporaryDirectory(named: "unsupported")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("archive.mkv")
        try Data("unsupported".utf8).write(to: sourceURL)
        let pipeline = MediaImportPipeline(
            probe: AppModelUnsupportedImportProbe(),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: AppModelImportBookmarkStore()
        )
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaImportPipeline: pipeline,
            opensSampleProjectWhenNoRecovery: true
        )

        await model.importMediaAndWait(from: [sourceURL])

        let failure = try XCTUnwrap(model.mediaImportSummary?.failed.first)
        XCTAssertEqual(failure.sourceURL.lastPathComponent, "archive.mkv")
        XCTAssertEqual(failure.error, .unsupportedFormat(sourceURL))
        let message = AppString.mediaImportFailureMessage(for: failure.error)
        XCTAssertTrue(message.contains("FFmpeg"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("not available"))
    }

    func testProgrammaticImportWithoutProjectPublishesTypedVisibleRefusal() async {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)

        await model.importMediaAndWait(from: [URL(fileURLWithPath: "/tmp/clip.mov")])

        XCTAssertEqual(model.mediaImportError, .noProject)
        XCTAssertEqual(model.loadMessage, "Create or open a project before importing media.")
        XCTAssertFalse(model.isImportingMedia)
        XCTAssertNil(model.mediaImportProgress)
        XCTAssertNil(model.mediaImportSummary)
    }

    private func constantProbeResult() throws -> MediaProbeResult {
        MediaProbeResult(
            metadata: MediaMetadata(
                codecID: "h264",
                pixelDimensions: PixelDimensions(width: 1_280, height: 720),
                frameRate: try FrameRate(frames: 30),
                duration: try RationalTime(value: 3, timescale: 1),
                colorSpace: .rec709,
                audioChannelLayout: AjarCore.AudioChannelLayout(channelCount: 2),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            ),
            videoFrameCount: 90
        )
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-app-import-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        attempts: Int = 100,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for app-model import state")
    }
}

private struct AppModelImportProbe: MediaProbing {
    let result: MediaProbeResult
    let delayNanoseconds: UInt64

    init(result: MediaProbeResult, delayNanoseconds: UInt64 = 0) {
        self.result = result
        self.delayNanoseconds = delayNanoseconds
    }

    func probe(_ sourceURL: URL) async throws -> MediaProbeResult {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return result
    }
}

private struct AppModelUnsupportedImportProbe: MediaProbing {
    func probe(_ sourceURL: URL) async throws -> MediaProbeResult {
        throw MediaProbeError.unsupportedFormat(sourceURL)
    }
}

private struct AppModelImportBookmarkStore: MediaBookmarkStore {
    func createBookmark(for url: URL) throws -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8) else {
            throw MediaBookmarkError.resolutionFailed(reason: "invalid test bookmark")
        }
        return MediaBookmarkResolution(url: URL(fileURLWithPath: path), isStale: false)
    }
}
