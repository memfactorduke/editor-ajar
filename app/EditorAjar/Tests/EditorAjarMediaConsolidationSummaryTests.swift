// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarMediaConsolidationSummaryTests: XCTestCase {
    func testFRMED008PartialFailureSummariesNameTheAffectedMedia() async throws {
        let cases: [(SummaryFailureKind, String)] = [
            (.offline, "is unavailable"),
            (.hash, "could not be verified"),
            (.copy, "could not be copied safely"),
            (.publicationSync, "safe storage could not be confirmed"),
            (.bookmark, "could not be authorized for reopening"),
            (.cleanup, "temporary copy")
        ]

        for (kind, expectedReason) in cases {
            let root = try temporaryDirectory(kind.rawValue)
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceURL = root.appendingPathComponent("named-original.mov")
            let bytes = Data("summary source".utf8)
            try bytes.write(to: sourceURL)
            let model = EditorAjarAppModel(
                autosaveIntervalSeconds: 0,
                mediaConsolidationRunner: SummaryFailureRunner(kind: kind)
            )
            try model.createNewProject(settings: .sensibleDefaults)
            XCTAssertTrue(
                model.applyEditForTesting(
                    .addMediaReferences([try makeMedia(sourceURL: sourceURL, bytes: bytes)])
                )
            )
            try model.saveProjectAs(
                to: root.appendingPathComponent("Summary.ajar", isDirectory: true)
            )

            XCTAssertTrue(model.startMediaConsolidation())
            await waitUntilFinished(model)

            let summary = try XCTUnwrap(model.mediaConsolidationSummaryMessage)
            XCTAssertTrue(summary.contains("named-original.mov"), summary)
            XCTAssertTrue(summary.contains(expectedReason), summary)
            XCTAssertTrue(summary.contains("Originals were not deleted"), summary)
        }
    }

    func testFRMED008PartialFailureSummaryFallsBackToStableMediaID() async throws {
        let root = try temporaryDirectory("uuid-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("offline source identity".utf8)
        let media = try makeMedia(sourceURL: nil, bytes: bytes)
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaConsolidationRunner: SummaryFailureRunner(kind: .offline)
        )
        try model.createNewProject(settings: .sensibleDefaults)
        XCTAssertTrue(model.applyEditForTesting(.addMediaReferences([media])))
        try model.saveProjectAs(to: root.appendingPathComponent("Fallback.ajar"))

        XCTAssertTrue(model.startMediaConsolidation())
        await waitUntilFinished(model)

        XCTAssertTrue(model.mediaConsolidationSummaryMessage?.contains(media.id.uuidString) == true)
    }

    func testFRMED008PackageBusyOutcomeIsClearAndPreservesOriginals() async throws {
        let root = try temporaryDirectory("package-busy")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("busy-original.mov")
        let bytes = Data("busy source".utf8)
        try bytes.write(to: sourceURL)
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaConsolidationRunner: PackageBusyRunner()
        )
        try model.createNewProject(settings: .sensibleDefaults)
        XCTAssertTrue(
            model.applyEditForTesting(
                .addMediaReferences([try makeMedia(sourceURL: sourceURL, bytes: bytes)])
            )
        )
        let package = root.appendingPathComponent("Busy.ajar", isDirectory: true)
        try model.saveProjectAs(to: package)

        XCTAssertTrue(model.startMediaConsolidation())
        await waitUntilFinished(model)

        let summary = try XCTUnwrap(model.mediaConsolidationSummaryMessage)
        XCTAssertTrue(summary.contains("already consolidating media"), summary)
        XCTAssertTrue(summary.contains("another window or process"), summary)
        XCTAssertTrue(summary.contains("Originals were not deleted"), summary)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
    }

    func testFRMED008ProtectedSourceProbeFailureUsesLocalizedCleanupSummary() async throws {
        let root = try temporaryDirectory("protected-probe")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaConsolidationRunner: StaleCleanupRunner()
        )
        try model.createNewProject(settings: .sensibleDefaults)
        let sourceURL = root.appendingPathComponent("source.mov")
        let bytes = Data("protected source".utf8)
        try bytes.write(to: sourceURL)
        XCTAssertTrue(
            model.applyEditForTesting(
                .addMediaReferences([try makeMedia(sourceURL: sourceURL, bytes: bytes)])
            )
        )
        try model.saveProjectAs(to: root.appendingPathComponent("Protected.ajar"))

        XCTAssertTrue(model.startMediaConsolidation())
        await waitUntilFinished(model)

        let summary = try XCTUnwrap(model.mediaConsolidationSummaryMessage)
        XCTAssertTrue(summary.contains("source.mov"), summary)
        XCTAssertTrue(
            summary.contains("Temporary media cleanup for source.mov needs attention"),
            summary
        )
        XCTAssertTrue(summary.contains("without deleting the uncertain item"), summary)
        XCTAssertTrue(summary.contains("Originals were not deleted"), summary)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
    }

    func testFRMED008StaleCleanupSummaryNamesExactCandidateWhenMediaIDIsUnavailable() async throws {
        let root = try temporaryDirectory("named-stale-candidate")
        defer { try? FileManager.default.removeItem(at: root) }
        let candidateName = ".ajar-partial-11111111-2222-3333-4444-555555555555"
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaConsolidationRunner: CandidateCleanupRunner(candidateName: candidateName)
        )
        try model.createNewProject(settings: .sensibleDefaults)
        let sourceURL = root.appendingPathComponent("source.mov")
        let bytes = Data("source remains present".utf8)
        try bytes.write(to: sourceURL)
        XCTAssertTrue(
            model.applyEditForTesting(
                .addMediaReferences([try makeMedia(sourceURL: sourceURL, bytes: bytes)])
            )
        )
        try model.saveProjectAs(to: root.appendingPathComponent("Candidate.ajar"))

        XCTAssertTrue(model.startMediaConsolidation())
        await waitUntilFinished(model)

        let summary = try XCTUnwrap(model.mediaConsolidationSummaryMessage)
        XCTAssertTrue(summary.contains(candidateName), summary)
        XCTAssertTrue(summary.contains("without deleting the uncertain item"), summary)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
    }

    func testFRMED008UnverifiedProtectedSourceSummaryNamesReferencedMedia() async throws {
        let root = try temporaryDirectory("unverified-protected-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("referenced-original.mov")
        let bytes = Data("referenced source remains present".utf8)
        try bytes.write(to: sourceURL)
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaConsolidationRunner: ProtectedSourceRunner()
        )
        try model.createNewProject(settings: .sensibleDefaults)
        XCTAssertTrue(
            model.applyEditForTesting(
                .addMediaReferences([try makeMedia(sourceURL: sourceURL, bytes: bytes)])
            )
        )
        try model.saveProjectAs(to: root.appendingPathComponent("ProtectedSource.ajar"))

        XCTAssertTrue(model.startMediaConsolidation())
        await waitUntilFinished(model)

        let summary = try XCTUnwrap(model.mediaConsolidationSummaryMessage)
        XCTAssertTrue(summary.contains("referenced-original.mov"), summary)
        XCTAssertTrue(summary.contains("Media safety could not verify"), summary)
        XCTAssertTrue(summary.contains("before temporary files were cleaned up"), summary)
        XCTAssertTrue(summary.contains("Originals were not deleted"), summary)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
    }

    private func waitUntilFinished(_ model: EditorAjarAppModel) async {
        for _ in 0..<1_000 where model.isConsolidatingMedia {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(model.isConsolidatingMedia)
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "editor-ajar-summary-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeMedia(sourceURL: URL?, bytes: Data) throws -> MediaRef {
        MediaRef(
            id: UUID(),
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes),
            metadata: MediaMetadata(
                codecID: "prores422",
                pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
                frameRate: try FrameRate(frames: 30),
                duration: try RationalTime(value: 1, timescale: 1),
                colorSpace: .rec709,
                audioChannelLayout: AudioChannelLayout(channelCount: 2),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
    }
}

private enum SummaryFailureKind: String, Sendable {
    case offline
    case hash
    case copy
    case publicationSync
    case bookmark
    case cleanup
}

private struct SummaryFailureRunner: EditorAjarMediaConsolidationRunning {
    let kind: SummaryFailureKind

    func prepare(
        project: Project,
        openMode: AjarProjectOpenMode,
        packageURL: URL,
        progress: @escaping @Sendable (ConsolidateProgressUpdate) -> Void
    ) async throws -> MediaConsolidateResult {
        let media = project.mediaPool[0]
        let sourceURL = media.sourceURL ?? packageURL
        let reason: MediaConsolidateFailureReason
        switch kind {
        case .offline:
            reason = .sourceResolutionFailed(
                .sourceMissing(mediaID: media.id, lastKnownURL: sourceURL)
            )
        case .hash:
            reason = .hashingFailed(url: sourceURL, reason: "injected hash refusal")
        case .copy:
            reason = .copyFailed(
                sourceURL: sourceURL,
                destinationURL: packageURL.appendingPathComponent("media"),
                reason: "injected copy refusal"
            )
        case .publicationSync:
            reason = .publicationSyncFailed(
                destinationURL: packageURL.appendingPathComponent("media/named-original.mov"),
                reason: "injected directory synchronization refusal"
            )
        case .bookmark:
            reason = .bookmarkCreationFailed(
                url: packageURL.appendingPathComponent("media/named-original.mov"),
                reason: "injected bookmark refusal"
            )
        case .cleanup:
            reason = .partialCleanupFailed(
                url: packageURL.appendingPathComponent("media/.ajar-partial-injected"),
                reason: "injected cleanup refusal"
            )
        }
        return MediaConsolidateResult(
            command: nil,
            publishedFileURLs: [],
            consolidatedMediaIDs: [],
            failure: MediaConsolidateFailure(mediaID: media.id, reason: reason)
        )
    }
}

private struct PackageBusyRunner: EditorAjarMediaConsolidationRunning {
    func prepare(
        project: Project,
        openMode: AjarProjectOpenMode,
        packageURL: URL,
        progress: @escaping @Sendable (ConsolidateProgressUpdate) -> Void
    ) async throws -> MediaConsolidateResult {
        throw MediaConsolidateCommandError.packageBusy(packageURL)
    }
}

private struct StaleCleanupRunner: EditorAjarMediaConsolidationRunning {
    func prepare(
        project: Project,
        openMode: AjarProjectOpenMode,
        packageURL: URL,
        progress: @escaping @Sendable (ConsolidateProgressUpdate) -> Void
    ) async throws -> MediaConsolidateResult {
        let media = project.mediaPool[0]
        throw MediaConsolidateCommandError.stalePartialCleanupFailed(
            url: media.sourceURL ?? packageURL,
            mediaID: media.id,
            reason: "injected protected-source probe refusal"
        )
    }
}

private struct CandidateCleanupRunner: EditorAjarMediaConsolidationRunning {
    let candidateName: String

    func prepare(
        project: Project,
        openMode: AjarProjectOpenMode,
        packageURL: URL,
        progress: @escaping @Sendable (ConsolidateProgressUpdate) -> Void
    ) async throws -> MediaConsolidateResult {
        throw MediaConsolidateCommandError.stalePartialCleanupFailed(
            url: packageURL.appendingPathComponent("media/\(candidateName)"),
            mediaID: nil,
            reason: "injected stale-candidate cleanup refusal"
        )
    }
}

private struct ProtectedSourceRunner: EditorAjarMediaConsolidationRunning {
    func prepare(
        project: Project,
        openMode: AjarProjectOpenMode,
        packageURL: URL,
        progress: @escaping @Sendable (ConsolidateProgressUpdate) -> Void
    ) async throws -> MediaConsolidateResult {
        let media = project.mediaPool[0]
        throw MediaConsolidateCommandError.protectedSourceUnavailable(
            mediaID: media.id,
            url: media.sourceURL,
            reason: "injected unverified source"
        )
    }
}
