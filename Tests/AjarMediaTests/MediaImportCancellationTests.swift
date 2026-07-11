// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarMedia

/// Cooperative-cancellation coverage for `MediaImportPipeline.prepareImport` (FR-MED-001).
final class MediaImportCancellationTests: XCTestCase {
    func testFRMED001MidBatchCancellationBailsEarlyAndCallerMutatesNoPool() async throws {
        let root = try temporaryDirectory(named: "cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let submittedCount = 4
        let urls: [URL] = try (0..<submittedCount).map { index in
            let url = root.appendingPathComponent("file-\(index).mov")
            // Distinct bytes → distinct hashes so each file would import (no dedup masking).
            try Data("clip-\(index)".utf8).write(to: url)
            return url
        }
        let probe = GatedMediaProbe(result: try constantProbeResult())
        let pipeline = MediaImportPipeline(
            probe: probe,
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: CancellationTestBookmarkStore()
        )
        let project = try emptyProject()

        // Mirror EditorAjarAppModel.performMediaImport: run inside a Task, then guard
        // `!Task.isCancelled` before applying — the cancelled path performs no pool mutation.
        let task = Task { () -> CancellationOutcome in
            let batch = await pipeline.prepareImport(
                from: urls,
                existingMedia: project.mediaPool
            )
            let cancelled = Task.isCancelled
            var poolCount = project.mediaPool.count
            if !cancelled, let command = batch.command {
                var history = EditHistory(project: project)
                if let applied = try? history.apply(command) {
                    poolCount = applied.mediaPool.count
                }
            }
            return CancellationOutcome(
                importedCount: batch.summary.imported.count,
                wasCancelled: cancelled,
                poolCount: poolCount
            )
        }

        // Cancel only once the batch is parked inside the first file's probe (mid-batch),
        // then release the probe so the loop advances and observes the cancellation.
        await probe.waitForFirstProbe()
        task.cancel()
        await probe.release()
        let outcome = await task.value
        let probeCount = await probe.probeCount

        // The caller's post-return guard fired, so no command was applied to the pool.
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.poolCount, 0)
        // Early exit: fewer files were probed/imported than were submitted.
        XCTAssertGreaterThanOrEqual(probeCount, 1)
        XCTAssertLessThan(probeCount, submittedCount)
        XCTAssertLessThan(outcome.importedCount, submittedCount)
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

private struct CancellationOutcome {
    let importedCount: Int
    let wasCancelled: Bool
    let poolCount: Int
}

/// Probe that parks inside the first `probe(_:)` call until the test releases it, so the batch can
/// be cancelled deterministically while stopped mid-batch (before the second file is reached).
private final class GatedMediaProbe: MediaProbing, @unchecked Sendable {
    private let result: MediaProbeResult
    private let gate = Gate()

    init(result: MediaProbeResult) {
        self.result = result
    }

    func probe(_ sourceURL: URL) async throws -> MediaProbeResult {
        await gate.enter()
        return result
    }

    var probeCount: Int {
        get async { await gate.count }
    }

    func waitForFirstProbe() async {
        await gate.waitForFirstProbe()
    }

    func release() async {
        await gate.release()
    }

    private actor Gate {
        private(set) var count = 0
        private var firstProbeSignaled = false
        private var mayProceed = false
        private var firstProbeWaiter: CheckedContinuation<Void, Never>?
        private var proceedWaiter: CheckedContinuation<Void, Never>?

        func enter() async {
            count += 1
            guard count == 1 else {
                return
            }
            firstProbeSignaled = true
            firstProbeWaiter?.resume()
            firstProbeWaiter = nil
            if !mayProceed {
                await withCheckedContinuation { proceedWaiter = $0 }
            }
        }

        func waitForFirstProbe() async {
            if firstProbeSignaled {
                return
            }
            await withCheckedContinuation { firstProbeWaiter = $0 }
        }

        func release() {
            mayProceed = true
            proceedWaiter?.resume()
            proceedWaiter = nil
        }
    }
}

private struct CancellationTestBookmarkStore: MediaBookmarkStore {
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
