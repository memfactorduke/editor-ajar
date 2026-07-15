// SPDX-License-Identifier: GPL-3.0-or-later
// swiftlint:disable file_length

import AjarCore
import AjarMedia
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarMediaConsolidationTests: XCTestCase {
    func testFRMED008DeterminateProgressDoesNotDoubleCountCompletedFile() {
        let copyingSecond = EditorAjarMediaConsolidationProgress(
            completedFileCount: 1,
            totalFileCount: 2,
            currentFileByteCount: 25,
            currentFileTotalByteCount: 100
        )
        XCTAssertEqual(copyingSecond.fractionCompleted, 0.625, accuracy: 0.000_001)

        let firstComplete = EditorAjarMediaConsolidationProgress(
            completedFileCount: 1,
            totalFileCount: 2,
            currentFileByteCount: 0,
            currentFileTotalByteCount: 0
        )
        XCTAssertEqual(firstComplete.fractionCompleted, 0.5, accuracy: 0.000_001)
    }

    func testFRMED008MenuGateAndUnsavedProjectRequireExistingSaveAsFlow() throws {
        let empty = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        XCTAssertFalse(empty.canRequestMediaConsolidation)
        XCTAssertFalse(empty.startMediaConsolidation())
        XCTAssertEqual(empty.mediaConsolidationError, .noProject)

        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true,
            automaticallyResolvesMediaReferences: false
        )
        XCTAssertTrue(model.canRequestMediaConsolidation)
        XCTAssertNil(model.mediaConsolidationConfirmation)
        XCTAssertFalse(model.startMediaConsolidation())
        XCTAssertEqual(model.mediaConsolidationError, .projectMustBeSaved)
    }

    func testFRMED008ConfirmationStatesExactDestinationCountAndOriginalPolicy() throws {
        let root = try temporaryDirectory("confirmation")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Consumer Project.ajar", isDirectory: true)
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true,
            automaticallyResolvesMediaReferences: false
        )
        try model.saveProjectAs(to: package)

        let confirmation = try XCTUnwrap(model.mediaConsolidationConfirmation)
        XCTAssertEqual(confirmation.fileCount, 2)
        XCTAssertEqual(
            confirmation.destinationURL,
            package.appendingPathComponent("media", isDirectory: true).standardizedFileURL
        )
        XCTAssertTrue(confirmation.informativeText.contains(confirmation.destinationURL.path))
        XCTAssertTrue(confirmation.informativeText.contains("2"))
        XCTAssertTrue(confirmation.informativeText.contains("Originals are never deleted"))
    }

    func testFRMED008ConfirmationUsesCorrectZeroOneAndManyGrammar() {
        let destination = URL(fileURLWithPath: "/Project.ajar/media", isDirectory: true)
        let zero = EditorAjarMediaConsolidationConfirmation(
            destinationURL: destination,
            fileCount: 0
        ).informativeText
        let one = EditorAjarMediaConsolidationConfirmation(
            destinationURL: destination,
            fileCount: 1
        ).informativeText
        let many = EditorAjarMediaConsolidationConfirmation(
            destinationURL: destination,
            fileCount: 3
        ).informativeText

        XCTAssertTrue(zero.contains("0 media files"))
        XCTAssertTrue(one.contains("1 media file"))
        XCTAssertFalse(one.contains("1 media files"))
        XCTAssertTrue(many.contains("3 media files"))
    }

    func testFRMED008NonmodalWorkAndDetachedCancelBridgeApplyOneUndoStep() async throws {
        let root = try temporaryDirectory("detached-bridge")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = DetachedCancellationOperation()
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaConsolidationRunner: EditorAjarDefaultMediaConsolidationRunner(
                operation: { request in try probe.run(request) }
            ),
            opensSampleProjectWhenNoRecovery: true,
            automaticallyResolvesMediaReferences: false
        )
        let package = root.appendingPathComponent("Bridge.ajar", isDirectory: true)
        try model.saveProjectAs(to: package)
        model.addTimelineMarkerAtPlayhead()
        XCTAssertTrue(model.canRevertProject)
        let snapshot = try XCTUnwrap(model.project)

        XCTAssertTrue(model.startMediaConsolidation())
        let reachedSecondFile = await probe.waitUntilWaitingForCancellation()
        XCTAssertTrue(reachedSecondFile)
        XCTAssertFalse(model.canRevertProject)
        XCTAssertThrowsError(try model.revertProject()) { error in
            XCTAssertEqual(
                error as? EditorAjarDocumentLifecycleError,
                .mediaConsolidationInProgress
            )
        }

        model.togglePlayback()
        XCTAssertTrue(model.isPlaying, "playback remains available under the compact overlay")
        let undoBeforeResponsiveEdit = model.editHistory?.undoCount ?? 0
        model.scrub(to: 1)
        model.addTimelineMarkerAtPlayhead()
        XCTAssertEqual(model.editHistory?.undoCount, undoBeforeResponsiveEdit + 1)
        let undoBeforeCancelResult = model.editHistory?.undoCount ?? 0

        model.cancelMediaConsolidation()
        await waitUntilFinished(model)

        XCTAssertEqual(model.editHistory?.undoCount, undoBeforeCancelResult + 1)
        XCTAssertNotEqual(model.project?.mediaPool[0].sourceURL, snapshot.mediaPool[0].sourceURL)
        XCTAssertEqual(model.project?.mediaPool[1], snapshot.mediaPool[1])
        XCTAssertTrue(model.mediaConsolidationSummaryMessage?.contains("1 of 2") == true)
    }

    func testFRMED008SessionGenerationRejectsStaleSameMediaResult() async throws {
        let root = try temporaryDirectory("session-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ReleasedResultOperation()
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaConsolidationRunner: EditorAjarDefaultMediaConsolidationRunner(
                operation: { request in try probe.run(request) }
            ),
            opensSampleProjectWhenNoRecovery: true,
            automaticallyResolvesMediaReferences: false
        )
        let package = root.appendingPathComponent("Race.ajar", isDirectory: true)
        try model.saveProjectAs(to: package)
        let sameMediaSession = try XCTUnwrap(model.project)

        XCTAssertTrue(model.startMediaConsolidation())
        let didBlock = await probe.waitUntilBlocked()
        XCTAssertTrue(didBlock)
        model.replaceProjectSessionForTesting(sameMediaSession, documentURL: package)
        probe.release()
        await waitUntilFinished(model)

        XCTAssertEqual(model.project?.mediaPool, sameMediaSession.mediaPool)
        XCTAssertEqual(model.editHistory?.undoCount, 0)
        XCTAssertEqual(model.mediaConsolidationError, .mediaReferencesChanged)
        XCTAssertTrue(
            model.mediaConsolidationSummaryMessage?.contains("different project") == true
        )
    }

    func testFRMED008BenignResolutionRefreshRebasesConsolidatedReference() async throws {
        let root = try temporaryDirectory("resolution-rebase")
        defer { try? FileManager.default.removeItem(at: root) }
        let consolidatedBookmark = Data("consolidated-bookmark".utf8)
        let probe = ReleasedResultOperation(replacementBookmark: consolidatedBookmark)
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaConsolidationRunner: EditorAjarDefaultMediaConsolidationRunner(
                operation: { request in try probe.run(request) }
            ),
            opensSampleProjectWhenNoRecovery: true,
            automaticallyResolvesMediaReferences: false
        )
        let package = root.appendingPathComponent("Resolution.ajar", isDirectory: true)
        try model.saveProjectAs(to: package)
        let snapshot = try XCTUnwrap(model.project)

        XCTAssertTrue(model.startMediaConsolidation())
        let didBlock = await probe.waitUntilBlocked()
        XCTAssertTrue(didBlock)

        let first = snapshot.mediaPool[0]
        let refreshedFirst = MediaRef(
            id: first.id,
            sourceURL: first.sourceURL,
            bookmark: Data("refreshed-bookmark".utf8),
            contentHash: first.contentHash,
            metadata: first.metadata,
            availability: .offline,
            proxyState: .ready(relativePath: "caches/proxies/refreshed.mov"),
            transcodeProvenance: first.transcodeProvenance
        )
        let refreshed = Project(
            schemaVersion: snapshot.schemaVersion,
            schemaMinor: snapshot.schemaMinor,
            settings: snapshot.settings,
            mediaPool: [refreshedFirst] + Array(snapshot.mediaPool.dropFirst()),
            sequences: snapshot.sequences,
            looks: snapshot.looks
        )
        model.replaceProjectPreservingHistoryForTesting(refreshed)
        let undoBefore = model.editHistory?.undoCount ?? 0

        probe.release()
        await waitUntilFinished(model)

        let consolidated = try XCTUnwrap(model.project?.mediaPool.first)
        XCTAssertEqual(model.editHistory?.undoCount, undoBefore + 1)
        XCTAssertEqual(
            consolidated.sourceURL,
            package.appendingPathComponent("media/stale.mov")
        )
        XCTAssertEqual(consolidated.bookmark, consolidatedBookmark)
        XCTAssertEqual(consolidated.availability, .available)
        XCTAssertEqual(consolidated.proxyState, refreshedFirst.proxyState)
        XCTAssertEqual(consolidated.transcodeProvenance, refreshedFirst.transcodeProvenance)

        model.undo()
        XCTAssertEqual(model.project?.mediaPool.first, refreshedFirst)
    }

    func testFRMED008MaterialMediaChangesRejectPreparedResult() async throws {
        for change in MaterialMediaChange.allCases {
            let root = try temporaryDirectory("material-\(change.rawValue)")
            defer { try? FileManager.default.removeItem(at: root) }
            let probe = ReleasedResultOperation()
            let model = EditorAjarAppModel(
                autosaveIntervalSeconds: 0,
                mediaConsolidationRunner: EditorAjarDefaultMediaConsolidationRunner(
                    operation: { request in try probe.run(request) }
                ),
                opensSampleProjectWhenNoRecovery: true,
                automaticallyResolvesMediaReferences: false
            )
            let package = root.appendingPathComponent("Material.ajar", isDirectory: true)
            try model.saveProjectAs(to: package)
            let snapshot = try XCTUnwrap(model.project)

            XCTAssertTrue(model.startMediaConsolidation())
            let didBlock = await probe.waitUntilBlocked()
            XCTAssertTrue(didBlock)
            let changed = try project(snapshot, applying: change)
            model.replaceProjectPreservingHistoryForTesting(changed)
            let undoBefore = model.editHistory?.undoCount

            probe.release()
            await waitUntilFinished(model)

            XCTAssertEqual(model.project, changed, "change: \(change.rawValue)")
            XCTAssertEqual(model.editHistory?.undoCount, undoBefore, "change: \(change.rawValue)")
            XCTAssertEqual(
                model.mediaConsolidationError,
                .mediaReferencesChanged,
                "change: \(change.rawValue)"
            )
        }
    }

    func testFRMED008PartialCancellationAppliesOneUndoableReferenceRewrite() async throws {
        let root = try temporaryDirectory("partial")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Partial.ajar", isDirectory: true)
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaConsolidationRunner: PartialCancellationRunner(),
            opensSampleProjectWhenNoRecovery: true,
            automaticallyResolvesMediaReferences: false
        )
        try model.saveProjectAs(to: package)
        let before = try XCTUnwrap(model.project)
        let undoBefore = model.editHistory?.undoCount ?? 0

        XCTAssertTrue(model.startMediaConsolidation())
        await waitUntilFinished(model)

        let after = try XCTUnwrap(model.project)
        XCTAssertEqual(model.editHistory?.undoCount, undoBefore + 1)
        XCTAssertNotEqual(after.mediaPool[0].sourceURL, before.mediaPool[0].sourceURL)
        XCTAssertEqual(after.mediaPool[1], before.mediaPool[1])
        XCTAssertTrue(model.isDocumentDirty)
        XCTAssertTrue(model.mediaConsolidationSummaryMessage?.contains("1 of 2") == true)
        XCTAssertTrue(model.mediaConsolidationSummaryMessage?.contains("undoable") == true)

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    func testFRMED008AlreadyRunningRefusesAndCancellationKeepsUIResponsive() async throws {
        let root = try temporaryDirectory("running")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaConsolidationRunner: SlowCancellationRunner(),
            opensSampleProjectWhenNoRecovery: true,
            automaticallyResolvesMediaReferences: false
        )
        try model.saveProjectAs(to: root.appendingPathComponent("Running.ajar"))

        XCTAssertTrue(model.startMediaConsolidation())
        XCTAssertTrue(model.isConsolidatingMedia)
        XCTAssertFalse(model.canRequestMediaConsolidation)
        XCTAssertFalse(model.canSaveProjectAs)
        XCTAssertFalse(model.startMediaConsolidation())
        XCTAssertEqual(model.mediaConsolidationError, .consolidationInProgress)

        model.cancelMediaConsolidation()
        await waitUntilFinished(model)
        XCTAssertFalse(model.isConsolidatingMedia)
        XCTAssertTrue(model.mediaConsolidationSummaryMessage?.contains("0 of 2") == true)
    }

    func testFRMED008ProductionRunnerSaveReopenPreservesConsolidatedReference() async throws {
        let root = try temporaryDirectory("save-reopen")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("original.mov")
        let sourceBytes = Data(repeating: 0x31, count: (2 * 1_024 * 1_024) + 7)
        try sourceBytes.write(to: sourceURL)
        let media = try makeMedia(sourceURL: sourceURL, bytes: sourceBytes)
        let package = root.appendingPathComponent("Saved.ajar", isDirectory: true)
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        try model.createNewProject(settings: .sensibleDefaults)
        XCTAssertTrue(model.applyEditForTesting(.addMediaReferences([media])))
        try model.saveProjectAs(to: package)

        XCTAssertTrue(model.startMediaConsolidation())
        await waitUntilFinished(model, attempts: 2_000)

        let consolidatedURL = try XCTUnwrap(model.project?.mediaPool.first?.sourceURL)
        XCTAssertEqual(
            consolidatedURL.deletingLastPathComponent().standardizedFileURL,
            package.appendingPathComponent("media", isDirectory: true).standardizedFileURL
        )
        XCTAssertEqual(try Data(contentsOf: consolidatedURL), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)

        try model.saveProject()
        let reopened = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        try reopened.openProject(at: package)
        XCTAssertEqual(reopened.project?.mediaPool.first?.sourceURL, consolidatedURL)
    }

}

private extension EditorAjarMediaConsolidationTests {
    private func waitUntilFinished(
        _ model: EditorAjarAppModel,
        attempts: Int = 200
    ) async {
        for _ in 0..<attempts where model.isConsolidatingMedia {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(model.isConsolidatingMedia, "consolidation did not finish in time")
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "editor-ajar-app-consolidate-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeMedia(sourceURL: URL, bytes: Data) throws -> MediaRef {
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

    private func project(
        _ project: Project,
        applying change: MaterialMediaChange
    ) throws -> Project {
        var media = project.mediaPool
        let first = media[0]
        switch change {
        case .relink:
            media[0] = MediaRef(
                id: first.id,
                sourceURL: URL(fileURLWithPath: "/tmp/relinked.mov"),
                bookmark: Data("relinked".utf8),
                contentHash: first.contentHash,
                metadata: first.metadata,
                availability: .available,
                proxyState: first.proxyState,
                transcodeProvenance: first.transcodeProvenance
            )
        case .importMedia:
            media.append(
                MediaRef(
                    id: UUID(),
                    sourceURL: URL(fileURLWithPath: "/tmp/imported.mov"),
                    contentHash: ContentHash.sha256(data: Data("imported".utf8)),
                    metadata: first.metadata
                )
            )
        case .remove:
            media.removeLast()
        case .reorder:
            media.reverse()
        case .content:
            media[0] = MediaRef(
                id: first.id,
                sourceURL: first.sourceURL,
                bookmark: first.bookmark,
                contentHash: ContentHash.sha256(data: Data("changed content".utf8)),
                metadata: first.metadata,
                availability: first.availability,
                proxyState: first.proxyState,
                transcodeProvenance: first.transcodeProvenance
            )
        }
        return Project(
            schemaVersion: project.schemaVersion,
            schemaMinor: project.schemaMinor,
            settings: project.settings,
            mediaPool: media,
            sequences: project.sequences,
            looks: project.looks
        )
    }
}

private enum MaterialMediaChange: String, CaseIterable {
    case relink
    case importMedia
    case remove
    case reorder
    case content
}

private final class DetachedCancellationOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var isWaiting = false

    func run(
        _ request: EditorAjarMediaConsolidationOperationRequest
    ) throws -> MediaConsolidateResult {
        let first = request.project.mediaPool[0]
        let destination = request.packageURL.appendingPathComponent("media/first.mov")
        let replacement = first.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: destination,
                contentHash: first.contentHash
            )
        )
        request.progress(
            ConsolidateProgressUpdate(
                completedFileCount: 1,
                totalFileCount: request.project.mediaPool.count,
                mediaID: first.id,
                destinationURL: destination
            )
        )
        lock.withLock { isWaiting = true }
        while !request.isCancelled() {
            Thread.sleep(forTimeInterval: 0.001)
        }
        return MediaConsolidateResult(
            command: .updateMediaReferences(kind: .consolidate, replacements: [replacement]),
            publishedFileURLs: [destination],
            consolidatedMediaIDs: [first.id],
            failure: MediaConsolidateFailure(
                mediaID: request.project.mediaPool[1].id,
                reason: .cancelled
            )
        )
    }

    func waitUntilWaitingForCancellation() async -> Bool {
        for _ in 0..<1_000 {
            if lock.withLock({ isWaiting }) { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }
}

private final class ReleasedResultOperation: @unchecked Sendable {
    private let condition = NSCondition()
    private let replacementBookmark: Data?
    private var blocked = false
    private var released = false

    init(replacementBookmark: Data? = nil) {
        self.replacementBookmark = replacementBookmark
    }

    func run(
        _ request: EditorAjarMediaConsolidationOperationRequest
    ) throws -> MediaConsolidateResult {
        condition.lock()
        blocked = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()

        let first = request.project.mediaPool[0]
        let destination = request.packageURL.appendingPathComponent("media/stale.mov")
        let replacement = first.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: destination,
                contentHash: first.contentHash,
                bookmark: replacementBookmark
            )
        )
        return MediaConsolidateResult(
            command: .updateMediaReferences(kind: .consolidate, replacements: [replacement]),
            publishedFileURLs: [destination],
            consolidatedMediaIDs: [first.id],
            failure: nil
        )
    }

    func waitUntilBlocked() async -> Bool {
        for _ in 0..<1_000 {
            if blockedSnapshot() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    private func blockedSnapshot() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return blocked
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private struct PartialCancellationRunner: EditorAjarMediaConsolidationRunning {
    func prepare(
        project: Project,
        openMode: AjarProjectOpenMode,
        packageURL: URL,
        progress: @escaping @Sendable (ConsolidateProgressUpdate) -> Void
    ) async throws -> MediaConsolidateResult {
        let first = project.mediaPool[0]
        let destination = packageURL.appendingPathComponent("media/first.mov")
        let replacement = first.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: destination,
                contentHash: first.contentHash
            ))
        progress(
            ConsolidateProgressUpdate(
                completedFileCount: 1,
                totalFileCount: project.mediaPool.count,
                mediaID: first.id,
                destinationURL: destination,
                copiedByteCount: 10,
                totalByteCount: 10
            ))
        return MediaConsolidateResult(
            command: .updateMediaReferences(kind: .consolidate, replacements: [replacement]),
            publishedFileURLs: [destination],
            consolidatedMediaIDs: [first.id],
            failure: MediaConsolidateFailure(
                mediaID: project.mediaPool[1].id,
                reason: .cancelled
            )
        )
    }
}

private struct SlowCancellationRunner: EditorAjarMediaConsolidationRunning {
    func prepare(
        project: Project,
        openMode: AjarProjectOpenMode,
        packageURL: URL,
        progress: @escaping @Sendable (ConsolidateProgressUpdate) -> Void
    ) async throws -> MediaConsolidateResult {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return MediaConsolidateResult(
            command: nil,
            publishedFileURLs: [],
            consolidatedMediaIDs: [],
            failure: nil
        )
    }
}
