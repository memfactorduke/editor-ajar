// SPDX-License-Identifier: GPL-3.0-or-later
// swiftlint:disable file_length

import AjarCore
import AjarMedia
import Foundation
import SwiftUI

struct EditorAjarMediaConsolidationProgress: Equatable {
    let completedFileCount: Int
    let totalFileCount: Int
    let currentFileByteCount: Int64
    let currentFileTotalByteCount: Int64

    var fractionCompleted: Double {
        guard totalFileCount > 0 else { return 0 }
        let current =
            currentFileTotalByteCount > 0
            ? min(1, Double(currentFileByteCount) / Double(currentFileTotalByteCount))
            : 0
        return min(1, (Double(completedFileCount) + current) / Double(totalFileCount))
    }
}

struct EditorAjarMediaConsolidationConfirmation: Equatable {
    let destinationURL: URL
    let fileCount: Int

    var informativeText: String {
        if fileCount == 1 {
            return AppString.localized(
                "consolidate.confirm.message.one",
                "Copy 1 media file to \(destinationURL.path). Originals are never deleted."
            )
        }
        return AppString.localized(
            "consolidate.confirm.message.many",
            "Copy \(fileCount) media files to \(destinationURL.path). Originals are never deleted."
        )
    }
}

protocol EditorAjarMediaConsolidationRunning: Sendable {
    func prepare(
        project: Project,
        openMode: AjarProjectOpenMode,
        packageURL: URL,
        progress: @escaping @Sendable (ConsolidateProgressUpdate) -> Void
    ) async throws -> MediaConsolidateResult
}

// swiftlint:disable:next type_name
struct EditorAjarMediaConsolidationOperationRequest: Sendable {
    let project: Project
    let openMode: AjarProjectOpenMode
    let packageURL: URL
    let progress: @Sendable (ConsolidateProgressUpdate) -> Void
    let isCancelled: @Sendable () -> Bool
}

// swiftlint:disable:next type_name
struct EditorAjarDefaultMediaConsolidationRunner: EditorAjarMediaConsolidationRunning {
    typealias Operation =
        @Sendable (EditorAjarMediaConsolidationOperationRequest) throws
        -> MediaConsolidateResult

    private let operation: Operation

    init() {
        operation = { request in
            try Self.productionOperation(request)
        }
    }

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func prepare(
        project: Project,
        openMode: AjarProjectOpenMode,
        packageURL: URL,
        progress: @escaping @Sendable (ConsolidateProgressUpdate) -> Void
    ) async throws -> MediaConsolidateResult {
        let operation = self.operation
        let worker = Task.detached(priority: .userInitiated) {
            try operation(
                EditorAjarMediaConsolidationOperationRequest(
                    project: project,
                    openMode: openMode,
                    packageURL: packageURL,
                    progress: progress,
                    isCancelled: { Task.isCancelled }
                )
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func productionOperation(
        _ request: EditorAjarMediaConsolidationOperationRequest
    ) throws -> MediaConsolidateResult {
        let relay = EditorAjarMediaConsolidationProgressRelay(request.progress)
        return try MediaConsolidateCommand().prepare(
            project: request.project,
            openMode: request.openMode,
            projectPackageURL: request.packageURL,
            progress: relay,
            isCancelled: request.isCancelled
        )
    }
}

// swiftlint:disable:next type_name
private final class EditorAjarMediaConsolidationProgressRelay: ConsolidateProgress {
    private let handler: @Sendable (ConsolidateProgressUpdate) -> Void

    init(_ handler: @escaping @Sendable (ConsolidateProgressUpdate) -> Void) {
        self.handler = handler
    }

    func consolidateDidUpdate(_ progress: ConsolidateProgressUpdate) {
        handler(progress)
    }
}

extension EditorAjarMediaConsolidationProgressRelay: @unchecked Sendable {}

// swiftlint:disable:next type_name
private final class EditorAjarMediaConsolidationModelProgressSink: @unchecked Sendable {
    private weak var model: EditorAjarAppModel?

    init(model: EditorAjarAppModel) {
        self.model = model
    }

    func receive(_ update: ConsolidateProgressUpdate) {
        Task { @MainActor [weak model] in
            model?.receiveMediaConsolidationProgress(update)
        }
    }
}

@MainActor
extension EditorAjarAppModel {
    var canRequestMediaConsolidation: Bool {
        guard let project else { return false }
        return projectOpenMode.allowsEditing
            && !project.mediaPool.isEmpty
            && !isConsolidatingMedia
            && !isImportingMedia
    }

    var mediaConsolidationConfirmation: EditorAjarMediaConsolidationConfirmation? {
        guard let project, let documentURL, !project.mediaPool.isEmpty else { return nil }
        return EditorAjarMediaConsolidationConfirmation(
            destinationURL: documentURL.appendingPathComponent("media", isDirectory: true),
            fileCount: project.mediaPool.count
        )
    }

    @discardableResult
    func startMediaConsolidation() -> Bool {
        guard let snapshot = project else { return refuseMediaConsolidation(.noProject) }
        guard projectOpenMode.allowsEditing else {
            presentReadOnlyBannerIfNeeded()
            return refuseMediaConsolidation(.projectReadOnly)
        }
        guard !snapshot.mediaPool.isEmpty else { return refuseMediaConsolidation(.noMedia) }
        guard let packageURL = documentURL else {
            return refuseMediaConsolidation(.projectMustBeSaved)
        }
        guard !isConsolidatingMedia, !isImportingMedia else {
            return refuseMediaConsolidation(.consolidationInProgress)
        }

        mediaConsolidationError = nil
        mediaConsolidationSummaryMessage = nil
        isConsolidatingMedia = true
        mediaConsolidationProgress = EditorAjarMediaConsolidationProgress(
            completedFileCount: 0,
            totalFileCount: snapshot.mediaPool.count,
            currentFileByteCount: 0,
            currentFileTotalByteCount: 0
        )
        let runner = mediaConsolidationRunner
        let openMode = projectOpenMode
        let sessionGeneration = projectSessionGeneration
        let expectedPackageURL = packageURL.standardizedFileURL
        let progressSink = EditorAjarMediaConsolidationModelProgressSink(model: self)
        mediaConsolidationTask = Task { [weak self] in
            do {
                let result = try await runner.prepare(
                    project: snapshot,
                    openMode: openMode,
                    packageURL: packageURL,
                    progress: { progressSink.receive($0) }
                )
                self?.finishMediaConsolidation(
                    result,
                    snapshot: snapshot,
                    sessionGeneration: sessionGeneration,
                    expectedPackageURL: expectedPackageURL
                )
            } catch is CancellationError {
                self?.finishCancelledMediaConsolidation(total: snapshot.mediaPool.count)
            } catch {
                self?.finishFailedMediaConsolidation(error, snapshot: snapshot)
            }
        }
        return true
    }

    func cancelMediaConsolidation() {
        mediaConsolidationTask?.cancel()
    }

    func dismissMediaConsolidationSummary() {
        mediaConsolidationSummaryMessage = nil
    }

    fileprivate func receiveMediaConsolidationProgress(_ update: ConsolidateProgressUpdate) {
        guard isConsolidatingMedia else { return }
        let isCompletedFileUpdate = update.destinationURL != nil
        mediaConsolidationProgress = EditorAjarMediaConsolidationProgress(
            completedFileCount: update.completedFileCount,
            totalFileCount: update.totalFileCount,
            currentFileByteCount: isCompletedFileUpdate ? 0 : update.copiedByteCount,
            currentFileTotalByteCount: isCompletedFileUpdate ? 0 : update.totalByteCount
        )
    }

    // swiftlint:disable:next function_body_length
    private func finishMediaConsolidation(
        _ result: MediaConsolidateResult,
        snapshot: Project,
        sessionGeneration: UInt64,
        expectedPackageURL: URL
    ) {
        let total = snapshot.mediaPool.count
        let completed = result.consolidatedMediaIDs.count
        let currentMedia = project?.mediaPool
        let isExpectedSession =
            projectSessionGeneration == sessionGeneration
            && documentURL?.standardizedFileURL == expectedPackageURL
            && currentMedia.map {
                Self.hasNoMaterialMediaConflict(snapshot: snapshot.mediaPool, current: $0)
            } == true
        guard isExpectedSession else {
            isConsolidatingMedia = false
            mediaConsolidationProgress = nil
            mediaConsolidationTask = nil
            mediaConsolidationError = .mediaReferencesChanged
            mediaConsolidationSummaryMessage = AppString.localized(
                "consolidate.summary.applyFailed",
                // swiftlint:disable:next line_length
                "Media copies were left safely in the project, but references were not changed because a different project or media set is now open. Originals were not deleted."
            )
            return
        }

        var didApply = result.command == nil
        // swift-format-ignore
        if result.command != nil,
            let currentMedia,
            let command = Self.rebasedConsolidationCommand(
                result.command,
                current: currentMedia
            ) {
            didApply = applyEdit(command)
        }
        isConsolidatingMedia = false
        mediaConsolidationProgress = nil
        mediaConsolidationTask = nil

        guard didApply else {
            mediaConsolidationError = mediaConsolidationError ?? .projectUpdateFailed
            mediaConsolidationSummaryMessage = AppString.localized(
                "consolidate.summary.applyFailed",
                // swiftlint:disable:next line_length
                "Media copies were left safely in the project, but references were not changed because the project changed during consolidation. Originals were not deleted."
            )
            return
        }

        if let failure = result.failure {
            let failedItem = Self.consolidationItemName(
                mediaID: failure.mediaID,
                snapshot: snapshot
            )
            let completedText = Self.localizedCompletedFileCount(completed, total: total)
            let rewriteText = Self.localizedReferenceRewriteCount(completed)
            switch failure.reason {
            case .cancelled:
                mediaConsolidationSummaryMessage = AppString.localized(
                    "consolidate.summary.cancelled",
                    // swiftlint:disable:next line_length
                    "Consolidation canceled before \(failedItem), after \(completedText). \(rewriteText) Originals were not deleted."
                )
            default:
                mediaConsolidationSummaryMessage = AppString.localized(
                    "consolidate.summary.partialFailure",
                    // swiftlint:disable:next line_length
                    "Consolidated \(completedText). \(rewriteText) \(Self.localizedConsolidationFailure(failure.reason, itemName: failedItem)) Originals were not deleted."
                )
            }
        } else {
            let path =
                documentURL?.appendingPathComponent("media", isDirectory: true).path ?? "media"
            let completedText = Self.localizedCompletedFileCount(completed, total: total)
            let rewriteText = Self.localizedReferenceRewriteCount(completed)
            mediaConsolidationSummaryMessage = AppString.localized(
                "consolidate.summary.complete",
                // swiftlint:disable:next line_length
                "Consolidated \(completedText) into \(path). \(rewriteText) Originals were not deleted."
            )
        }
    }

    private static func hasNoMaterialMediaConflict(
        snapshot: [MediaRef],
        current: [MediaRef]
    ) -> Bool {
        guard snapshot.count == current.count else { return false }
        return zip(snapshot, current).allSatisfy { original, latest in
            original.id == latest.id
                && original.sourceURL == latest.sourceURL
                && original.contentHash == latest.contentHash
                && original.metadata == latest.metadata
                && original.transcodeProvenance == latest.transcodeProvenance
        }
    }

    private static func rebasedConsolidationCommand(
        _ command: EditCommand?,
        current: [MediaRef]
    ) -> EditCommand? {
        guard
            case .updateMediaReferences(let kind, let replacements) = command,
            kind == .consolidate
        else {
            return nil
        }
        var currentByID: [UUID: MediaRef] = [:]
        for reference in current {
            guard currentByID[reference.id] == nil else { return nil }
            currentByID[reference.id] = reference
        }
        var rebased: [MediaRef] = []
        for replacement in replacements {
            guard let latest = currentByID[replacement.id] else { return nil }
            rebased.append(
                MediaRef(
                    id: latest.id,
                    sourceURL: replacement.sourceURL,
                    bookmark: replacement.bookmark,
                    contentHash: replacement.contentHash,
                    metadata: latest.metadata,
                    availability: .available,
                    proxyState: latest.proxyState,
                    transcodeProvenance: latest.transcodeProvenance
                )
            )
        }
        return .updateMediaReferences(kind: .consolidate, replacements: rebased)
    }

    private func finishCancelledMediaConsolidation(total: Int) {
        isConsolidatingMedia = false
        mediaConsolidationProgress = nil
        mediaConsolidationTask = nil
        let completedText = Self.localizedCompletedFileCount(0, total: total)
        mediaConsolidationSummaryMessage = AppString.localized(
            "consolidate.summary.cancelled.none",
            // swiftlint:disable:next line_length
            "Consolidation canceled before any references changed, after \(completedText). Originals were not deleted."
        )
    }

    private func finishFailedMediaConsolidation(_ error: Error, snapshot: Project) {
        isConsolidatingMedia = false
        mediaConsolidationProgress = nil
        mediaConsolidationTask = nil
        mediaConsolidationSummaryMessage = AppString.localized(
            "consolidate.summary.failed",
            // swiftlint:disable:next line_length
            "Media could not be consolidated. \(Self.localizedConsolidationCommandError(error, snapshot: snapshot)) Originals were not deleted."
        )
    }

    private func refuseMediaConsolidation(_ error: EditorAjarMediaConsolidationError) -> Bool {
        mediaConsolidationError = error
        switch error {
        case .noProject:
            surfaceLocalizedEditRefusal(
                "consolidate.refusal.noProject",
                "Create or open a project before consolidating media.")
        case .projectReadOnly:
            surfaceLocalizedEditRefusal(
                "consolidate.refusal.readOnly",
                "Media cannot be consolidated in a read-only project.")
        case .noMedia:
            surfaceLocalizedEditRefusal(
                "consolidate.refusal.noMedia", "The project has no media to consolidate.")
        case .projectMustBeSaved:
            surfaceLocalizedEditRefusal(
                "consolidate.refusal.mustSave", "Save the project before consolidating media.")
        case .consolidationInProgress:
            surfaceLocalizedEditRefusal(
                "consolidate.refusal.inProgress", "Media consolidation is already in progress.")
        case .mediaReferencesChanged, .projectUpdateFailed:
            surfaceLocalizedEditRefusal(
                "consolidate.refusal.projectChanged",
                "Project media changed before consolidation could be applied.")
        }
        return false
    }

    private static func consolidationItemName(mediaID: UUID, snapshot: Project) -> String {
        snapshot.mediaPool.first(where: { $0.id == mediaID })?.sourceURL?.lastPathComponent
            ?? mediaID.uuidString
    }

    private static func localizedCompletedFileCount(_ completed: Int, total: Int) -> String {
        if total == 1 {
            return AppString.localized("consolidate.count.files.one", "\(completed) of 1 file")
        }
        return AppString.localized(
            "consolidate.count.files.many", "\(completed) of \(total) files")
    }

    private static func localizedReferenceRewriteCount(_ count: Int) -> String {
        if count == 0 {
            return AppString.localized(
                "consolidate.count.references.zero",
                "No references were changed."
            )
        }
        if count == 1 {
            return AppString.localized(
                "consolidate.count.references.one",
                "That reference was updated as one undoable change."
            )
        }
        return AppString.localized(
            "consolidate.count.references.many",
            "Those \(count) references were updated as one undoable change."
        )
    }

    private static func localizedConsolidationFailure(
        _ reason: MediaConsolidateFailureReason,
        itemName: String
    ) -> String {
        switch reason {
        case .cancelled:
            return AppString.localized(
                "consolidate.failure.cancelled", "\(itemName) was canceled.")
        case .partialCleanupFailed:
            return AppString.localized(
                "consolidate.failure.cleanup",
                // swiftlint:disable:next line_length
                "An unpublished temporary copy for \(itemName) could not be removed safely. Consolidation stopped without deleting it."
            )
        case .sourceResolutionFailed:
            return AppString.localized(
                "consolidate.failure.offline", "\(itemName) is unavailable.")
        case .sourceContentHashMismatch:
            return AppString.localized(
                "consolidate.failure.changed", "\(itemName) changed since import.")
        case .hashingFailed:
            return AppString.localized(
                "consolidate.failure.hash", "\(itemName) could not be verified.")
        case .sourceNotRegularFile:
            return AppString.localized(
                "consolidate.failure.unsafeSource", "\(itemName) is not a safe regular file.")
        case .copiedContentHashMismatch:
            return AppString.localized(
                "consolidate.failure.copyMismatch",
                "The copy of \(itemName) failed verification and was not published.")
        case .copyFailed:
            return AppString.localized(
                "consolidate.failure.copy", "\(itemName) could not be copied safely.")
        case .publicationSyncFailed:
            return AppString.localized(
                "consolidate.failure.publicationSync",
                "The copy of \(itemName) is present, but safe storage could not be confirmed, so its reference was not changed."
            )
        case .bookmarkCreationFailed:
            return AppString.localized(
                "consolidate.failure.bookmark",
                "The copy of \(itemName) could not be authorized for reopening.")
        }
    }

    private static func localizedConsolidationCommandError(
        _ error: Error,
        snapshot: Project
    ) -> String {
        guard let commandError = error as? MediaConsolidateCommandError else {
            return AppString.localized(
                "consolidate.failure.unknown", "The project package was unavailable.")
        }
        switch commandError {
        case .projectOpenedReadOnly:
            return AppString.localized("consolidate.failure.readOnly", "The project is read-only.")
        case .duplicateMediaReferenceID:
            return AppString.localized(
                "consolidate.failure.duplicate", "The project contains ambiguous media references.")
        case .packageMustBeFileURL, .packageDirectoryUnavailable:
            return AppString.localized(
                "consolidate.failure.package", "The saved project package is unavailable.")
        case .mediaDirectoryCreationFailed, .unsafeMediaDirectory:
            return AppString.localized(
                "consolidate.failure.mediaDirectory",
                "The project media folder is unavailable or unsafe.")
        case .stalePartialCleanupFailed(let url, let mediaID, _):
            let itemName = consolidationCleanupItemName(
                url: url,
                mediaID: mediaID,
                snapshot: snapshot
            )
            return AppString.localized(
                "consolidate.failure.staleCleanup",
                // swiftlint:disable:next line_length
                "Temporary media cleanup for \(itemName) needs attention. Consolidation stopped without deleting the uncertain item."
            )
        case .protectedSourceUnavailable(let mediaID, let url, _):
            let itemName = consolidationCleanupItemName(
                url: url,
                mediaID: mediaID,
                snapshot: snapshot
            )
            return AppString.localized(
                "consolidate.failure.sourceProtection",
                "Media safety could not verify \(itemName). Consolidation stopped before temporary files were cleaned up."
            )
        case .packageBusy:
            return AppString.localized(
                "consolidate.failure.packageBusy",
                // swiftlint:disable:next line_length
                "This project is already consolidating media in another window or process. Wait for it to finish and try again."
            )
        case .packageLockFailed:
            return AppString.localized(
                "consolidate.failure.packageLock",
                "The project media folder could not be locked safely."
            )
        }
    }

    private static func consolidationCleanupItemName(
        url: URL?,
        mediaID: UUID?,
        snapshot: Project
    ) -> String {
        if let mediaID {
            return consolidationItemName(mediaID: mediaID, snapshot: snapshot)
        }
        let filename = url?.lastPathComponent ?? ""
        return filename.isEmpty ? (url?.path ?? "Media") : filename
    }
}

struct EditorAjarMediaConsolidationProgressView: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppString.localized("consolidate.progress.title", "Consolidating Media"))
                .font(.title2.weight(.semibold))
            if let progress = model.mediaConsolidationProgress {
                ProgressView(value: progress.fractionCompleted)
                    .accessibilityLabel(
                        AppString.localized(
                            "consolidate.progress.ax", "Media consolidation progress")
                    )
                    .accessibilityValue(
                        Self.localizedProgressCount(progress)
                    )
                    .accessibilityIdentifier("Media Consolidation Progress")
                Text(Self.localizedProgressCount(progress, includesComplete: true))
                    .foregroundStyle(.secondary)
            }
            Text(
                AppString.localized(
                    "consolidate.progress.originals", "Original files are never deleted.")
            )
            .font(.callout)
            HStack {
                Spacer()
                Button(AppString.localized("consolidate.progress.cancel", "Cancel")) {
                    model.cancelMediaConsolidation()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(
                    AppString.localized(
                        "consolidate.progress.cancel.ax", "Cancel media consolidation")
                )
                .accessibilityIdentifier("Cancel Media Consolidation")
            }
        }
        .padding(16)
        .frame(width: 390)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 1)
        }
        .shadow(radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppString.localized(
                "consolidate.progress.overlay.ax",
                "Media consolidation controls. The editor remains available."
            )
        )
        .accessibilityIdentifier("Media Consolidation Nonmodal Overlay")
    }

    private static func localizedProgressCount(
        _ progress: EditorAjarMediaConsolidationProgress,
        includesComplete: Bool = false
    ) -> String {
        if progress.totalFileCount == 1 {
            return includesComplete
                ? AppString.localized(
                    "consolidate.progress.count.one",
                    "\(progress.completedFileCount) of 1 file complete")
                : AppString.localized(
                    "consolidate.progress.value.one", "\(progress.completedFileCount) of 1 file")
        }
        return includesComplete
            ? AppString.localized(
                "consolidate.progress.count.many",
                "\(progress.completedFileCount) of \(progress.totalFileCount) files complete"
            )
            : AppString.localized(
                "consolidate.progress.value.many",
                "\(progress.completedFileCount) of \(progress.totalFileCount) files"
            )
    }
}
