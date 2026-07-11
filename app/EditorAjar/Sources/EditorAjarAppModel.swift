// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import AjarExport
import AjarMedia
import AppKit
import CoreImage
import Foundation
import Metal
import SwiftUI

/// Typed state-machine refusals above the package I/O layer.
enum EditorAjarDocumentLifecycleError: Error, Equatable {
    /// Replacing the current document would discard unsaved user work.
    case unsavedChanges

    /// The requested operation needs an open project.
    case noProject

    /// Plain Save was requested for an untitled project; the UI should present Save As.
    case documentHasNoURL

    /// A save path was requested for a newer-minor read-only open.
    case projectOpenedReadOnly(AjarProjectReadOnlyReason)
}

/// Typed reasons a requested media import did not start.
enum EditorAjarMediaImportError: Error, Equatable {
    case noProject
    case projectReadOnly
    case importInProgress
    case emptySelection
}

/// User-facing context for localized document errors.
enum EditorAjarDocumentOperation {
    case create
    case open
    case save
    case revert
    case sample
}

@MainActor
final class EditorAjarAppModel: ObservableObject {
    @Published private(set) var project: Project?
    /// User-visible `.ajar` package currently represented by the window.
    @Published private(set) var documentURL: URL?
    /// Native window edited-state source, derived from the last explicit save baseline.
    @Published private(set) var isDocumentDirty = false
    /// App-side recent project list (never persisted inside project packages).
    @Published private(set) var recentProjectURLs: [URL] = []
    /// New-project settings sheet state (FR-PROJ-003).
    @Published private(set) var isNewProjectSheetPresented = false
    @Published var newProjectSettings = EditorAjarNewProjectSettings.sensibleDefaults
    /// Localized document-operation failure shown by the root view.
    @Published private(set) var documentErrorMessage: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var playheadFrame: Int64 = 0
    @Published private(set) var durationFrames: Int64 = 1
    @Published private(set) var presentedTexture: MTLTexture?
    @Published private(set) var loadMessage: String
    @Published private(set) var timelineState = TimelineInteractionState()
    @Published private(set) var timelineHasFocus = false
    @Published private(set) var selectedMediaIDs: Set<UUID> = []
    @Published private(set) var timelineTool: TimelineTool = .selection
    @Published private(set) var timelineGestureFeedback: String?
    @Published private(set) var timelineSnapIndicatorFrame: Int64?
    @Published private(set) var selectedTimelineTrackID: UUID?
    @Published private(set) var activeSequenceID: UUID?
    @Published private(set) var copiedGradeSource: ProjectClipReference?
    @Published private(set) var canvasSafeAreaGuidesVisible = false
    /// Display-only monitor option; never changes graph identity or exported pixels.
    @Published private(set) var checkerboardAlphaVisible = false
    /// Session-only in/out looping; project schema remains unchanged.
    @Published private(set) var isLoopRangeEnabled = false
    @Published private(set) var selectedCanvasTitleBoxReference: CanvasTitleBoxReference?
    @Published private(set) var editingCanvasTitleBoxReference: CanvasTitleBoxReference?

    /// Identities of text fields that currently hold keyboard focus (#240 review).
    ///
    /// A set (not a Bool) so focus moving directly between two fields — where SwiftUI may report
    /// the new field's gain before the old field's loss — never leaves the flag incorrectly clear.
    @Published private(set) var focusedTextEditorIDs: Set<UUID> = []

    /// Whether any text editor (inspector/search field or the canvas title editor) is active.
    ///
    /// While true, timeline gestures with plain-key or clipboard shortcuts are inert and their
    /// menu items disabled, so typing can never blade, trim, cut, or delete timeline content.
    var isTextEditingActive: Bool {
        !focusedTextEditorIDs.isEmpty || editingCanvasTitleBoxReference != nil
    }

    /// Session open mode from the load / recovery path (ADR-0018 / FR-PROJ-005).
    @Published private(set) var projectOpenMode: AjarProjectOpenMode = .editable

    /// Whether the read-only workspace banner is currently shown.
    @Published private(set) var isReadOnlyBannerVisible = false

    /// Minimal export dialog state (FR-EXP-003/004).
    @Published private(set) var exportDialog = EditorAjarExportDialogModel()

    /// Whether the FR-EXP-005 export queue panel is visible.
    @Published var isExportQueuePanelVisible = false

    /// Background export queue bridge (FR-EXP-005). Observe this for job list updates.
    let exportQueueController: EditorAjarExportQueueController

    /// In-memory proxy generation progress by media id (FR-MED-004; not persisted).
    @Published private(set) var proxyGenerationProgress: [UUID: Double] = [:]

    /// Whether the multi-select file/folder importer is presented (FR-MED-001).
    @Published private(set) var isMediaImportPickerPresented = false

    /// Whether one serialized media-import batch is running off-main.
    @Published private(set) var isImportingMedia = false

    /// Session-only folder/file import progress.
    @Published private(set) var mediaImportProgress: MediaImportProgress?

    /// Most recently completed import breakdown.
    @Published private(set) var mediaImportSummary: MediaImportSummary?

    /// Whether the categorized import summary sheet is visible.
    @Published private(set) var isMediaImportSummaryPresented = false

    /// Most recent programmatic import refusal, cleared when a batch starts.
    @Published private(set) var mediaImportError: EditorAjarMediaImportError?

    /// Browser-owned regeneratable preview bytes, keyed by stable media id (FR-MED-009).
    @Published private(set) var mediaThumbnailData: [UUID: Data] = [:]
    /// Transient hover-scrub frames only — never written into `mediaThumbnailData` (M4).
    @Published private(set) var mediaHoverPreviewData: [UUID: Data] = [:]
    /// Decoded audio waveform summaries for media-browser tiles (M6).
    @Published private(set) var mediaWaveformSummary: [UUID: AudioWaveformSummary] = [:]
    /// Stable offline item currently awaiting a single-file relink choice.
    @Published private(set) var mediaIDAwaitingRelink: UUID?

    /// Hash-mismatch candidate awaiting explicit Override / Cancel (FR-MED-007 / #246).
    @Published private(set) var pendingRelinkMismatch: EditorAjarPendingRelinkMismatch?

    /// Whether the batch relink folder picker is presented.
    @Published private(set) var isBatchRelinkFolderPickerPresented = false

    /// Result of the last batch folder relink, when the summary sheet is open.
    @Published private(set) var batchRelinkSummary: MediaBatchRelinkResult?

    /// Whether the batch relink summary sheet is visible.
    @Published private(set) var isBatchRelinkSummaryPresented = false

    /// First-media project-settings proposal awaiting Apply / Keep (FR-PROJ-003 / #246).
    @Published private(set) var proposedFirstMediaSettings: ProjectSettings?

    /// Whether the first-media settings confirmation sheet is visible.
    @Published private(set) var isFirstMediaSettingsProposalPresented = false

    /// When true, present the FR-PROJ-003 proposal after the import summary sheet dismisses.
    ///
    /// macOS drops one of two simultaneous `.sheet` modifiers stacked on the same view; sequence
    /// summary → proposal via this pending flag instead of presenting both at once.
    private var pendingFirstMediaProposal = false

    private var playbackController: EditorAjarPlaybackController?
    private var renderPipeline: EditorAjarRenderPipeline?
    private var displayLinkDriver: EditorAjarDisplayLinkDriver?
    private var editHistory: EditHistory?
    private let autosaveCoordinator: EditorAjarAutosaveCoordinator?
    /// Fallback package root for untitled/never-saved projects (preview cache, M3).
    private let autosavePackageRootURL: URL?
    private let autosaveIntervalSeconds: TimeInterval
    private let audioCoordinator: (any EditorAjarAudioCoordinating)?
    private let exportPresetStore: EditorAjarExportPresetStore
    private let mediaImportPipeline: MediaImportPipeline
    private let documentStore: EditorAjarDocumentStore
    private let recentProjectsStore: EditorAjarRecentProjectsStore
    private var savedProjectBaseline: Project?
    private var unsavedDocumentName: String?
    private var documentSecurityScope: EditorAjarSecurityScopedAccess?
    /// Package root for `caches/proxies/` resolution and proxy writes (FR-MED-004).
    private var projectPackageRootURL: URL?
    /// Dedicated proxy-generation queue (not the user export queue).
    private let proxyGenerationQueue: ProxyGenerationQueue
    private var proxyObserveTask: Task<Void, Never>?
    /// Media ids with a pending/running proxy job (dedupe app-side enqueue).
    private var proxyJobsInFlight: Set<UUID> = []
    private var autosaveLoopTask: Task<Void, Never>?
    private var autosaveWriteTask: Task<Void, Never>?
    private var mediaResolutionTask: Task<Void, Never>?
    private var mediaImportTask: Task<Void, Never>?
    private var mediaHoverTask: Task<Void, Never>?
    private var mediaHoverMediaID: UUID?
    private var mediaPreviewTasks: [UUID: Task<Void, Never>] = [:]
    private var mediaPreviewCache: MediaPreviewCache?
    private var autosaveCommandCount = 0
    private var renderGeneration = 0
    private var sequenceContexts: [UUID: SequenceEditingContext] = [:]
    private var canvasTitleEditingUndoBaseline: Int?
    private var timelineClipboard: [TimelineClipboardItem] = []
    /// Surfaces the read-only edit refusal message once per session (not per-command spam).
    private var hasSurfacedReadOnlyEditRefusal = false
    /// One-shot authorization set only after the user confirms Discard in native document chrome.
    private var mayDiscardChangesForNextReplacement = false

    init(
        autosavePackageURL: URL? = nil,
        autosaveIntervalSeconds: TimeInterval = 5.0,
        audioCoordinator: (any EditorAjarAudioCoordinating)? = nil,
        exportPresetStoreURL: URL? = nil,
        exportQueueController: EditorAjarExportQueueController? = nil,
        mediaImportPipeline: MediaImportPipeline? = nil,
        documentStore: EditorAjarDocumentStore = EditorAjarDocumentStore(),
        recentProjectsUserDefaults: UserDefaults = .standard,
        recentProjectsStorageKey: String = "document.recentProjects",
        opensSampleProjectWhenNoRecovery: Bool = false
    ) {
        self.autosaveIntervalSeconds = autosaveIntervalSeconds
        autosavePackageRootURL = autosavePackageURL
        if let autosavePackageURL {
            autosaveCoordinator = EditorAjarAutosaveCoordinator(packageURL: autosavePackageURL)
        } else {
            autosaveCoordinator = nil
        }
        self.audioCoordinator = audioCoordinator ?? Self.makeAudioCoordinator()
        exportPresetStore = EditorAjarExportPresetStore(
            fileURL: exportPresetStoreURL ?? EditorAjarExportPresetStore.defaultFileURL()
        )
        self.documentStore = documentStore
        recentProjectsStore = EditorAjarRecentProjectsStore(
            userDefaults: recentProjectsUserDefaults,
            storageKey: recentProjectsStorageKey
        )
        recentProjectURLs = recentProjectsStore.load()
        self.exportQueueController = exportQueueController ?? EditorAjarExportQueueController()
        self.mediaImportPipeline = mediaImportPipeline ?? MediaImportPipeline()
        proxyGenerationQueue = ProxyGenerationQueue(
            sessionFactory: Self.makeProxySessionFactory()
        )

        loadMessage = AppString.localized(
            "status.noProject",
            "Create a new project or open an existing project"
        )

        var initialLoadResult: AjarProjectLoadResult?
        var initialLoadIsSampleFixture = false
        if let autosavePackageURL,
           AjarAutosaveStore.hasRecoverableSnapshot(at: autosavePackageURL)
        {
            do {
                let recovery = try AjarAutosaveStore.recoverProject(from: autosavePackageURL)
                initialLoadResult = recovery.loadResult
                projectPackageRootURL = autosavePackageURL
                autosaveCommandCount = recovery.latestCommandCount
                let recoveryPrefix = recovery.isComplete
                    ? AppString.localized("status.recoveredAutosave", "Recovered autosave")
                    : AppString.localized(
                        "status.recoveredAutosavePartial", "Recovered autosave to last good state"
                    )
                switch recovery.openMode {
                case .editable:
                    loadMessage = recoveryPrefix
                case .readOnly:
                    // Journal was skipped (#193); banner shows the typed reason message.
                    loadMessage = AppString.localized(
                        "status.recoveredReadOnly", "\(recoveryPrefix) (read-only)"
                    )
                }
            } catch {
                loadMessage = "Autosave recovery unavailable: \(error)"
            }
        }

        // Explicit test fixture only. Production launch never opts in; Help uses openSampleProject().
        if initialLoadResult == nil, opensSampleProjectWhenNoRecovery {
            switch Self.makeSampleProject() {
            case .success(let sampleProject):
                initialLoadResult = .editable(sampleProject)
                initialLoadIsSampleFixture = true
                loadMessage = AppString.localized(
                    "status.sampleProjectLoaded",
                    "Sample project loaded"
                )
            case .failure(let error):
                let detail = String(describing: error)
                loadMessage = AppString.localized(
                    "document.error.sample",
                    "Could not open the sample project: \(detail)"
                )
            }
        }

        if let initialLoadResult {
            project = initialLoadResult.project
            projectOpenMode = initialLoadResult.openMode
            editHistory = EditHistory(loadResult: initialLoadResult)
            if initialLoadIsSampleFixture {
                savedProjectBaseline = initialLoadResult.project
                unsavedDocumentName = AppString.localized(
                    "document.sample.name",
                    "Sample Project"
                )
                isDocumentDirty = false
            } else {
                // Recovery has no explicit saved-document baseline: retain it as unsaved work.
                savedProjectBaseline = nil
                unsavedDocumentName = AppString.localized(
                    "document.recovered.name",
                    "Recovered Project"
                )
                isDocumentDirty = initialLoadResult.openMode.allowsEditing
            }
            if case .readOnly = initialLoadResult.openMode {
                isReadOnlyBannerVisible = true
            }
            if let sequence = initialLoadResult.project.sequences.first {
                activeSequenceID = sequence.id
                durationFrames = Self.durationFrames(for: sequence)
                playbackController = EditorAjarPlaybackController(
                    frameRate: sequence.timebase,
                    durationFrames: durationFrames
                )
                persistActiveSequenceContext()
            }
        } else {
            project = nil
        }

        do {
            renderPipeline = try EditorAjarRenderPipeline()
            bindRenderPackageRoot()
        } catch {
            loadMessage = "Metal playback unavailable: \(error)"
        }

        displayLinkDriver = EditorAjarDisplayLinkDriver { [weak self] deltaSeconds in
            self?.displayLinkTick(deltaSeconds)
        }
        // Only checkpoint editable sessions — read-only must never rewrite package bytes.
        if let project, projectOpenMode.allowsEditing {
            scheduleAutosaveCheckpoint(project: project)
        }
        startAutosaveLoop()
        startProxyQueueObservation()
        reloadExportPresets()
        requestRenderForCurrentFrame()
        if let initialLoadResult {
            startMediaResolution(for: initialLoadResult)
        }
    }

    // MARK: - Project document lifecycle (FR-PROJ-001/002/003)

    /// Display name used by the native window title bridge.
    var documentDisplayName: String {
        if let documentURL {
            return documentURL.deletingPathExtension().lastPathComponent
        }
        if project != nil {
            return unsavedDocumentName
                ?? AppString.localized("document.untitled", "Untitled")
        }
        return AppString.localized("app.name", "Editor Ajar")
    }

    /// Whether Save As is available for this session.
    var canSaveProjectAs: Bool {
        project != nil && projectOpenMode.allowsEditing
    }

    /// Whether Revert can discard edits back to an on-disk package.
    var canRevertProject: Bool {
        documentURL != nil && isDocumentDirty
    }

    /// Presents the FR-PROJ-003 settings sheet with sensible defaults.
    func presentNewProjectSheet() {
        newProjectSettings = .sensibleDefaults
        isNewProjectSheetPresented = true
    }

    /// Cancels the New Project sheet without changing the current document.
    func dismissNewProjectSheet() {
        isNewProjectSheetPresented = false
        mayDiscardChangesForNextReplacement = false
    }

    /// Allows exactly one New/Open/Sample transition to replace dirty work after confirmation.
    func authorizeDiscardForNextDocumentReplacement() {
        mayDiscardChangesForNextReplacement = true
    }

    /// Clears a pending authorization when a file panel or settings sheet is cancelled.
    func cancelDocumentReplacementAuthorization() {
        mayDiscardChangesForNextReplacement = false
    }

    /// Records an explicit Discard choice made while closing the window or quitting.
    ///
    /// Making the live state clean queues removal of the app-level crash-recovery package. Quit
    /// waits for that queue below, so deliberately discarded work is not offered again at launch.
    func discardUnsavedChangesForClosing() {
        guard let project else {
            return
        }
        savedProjectBaseline = project
        refreshDirtyState()
        resetAutosaveForInstalledProject()
    }

    /// Waits for the latest queued recovery write/removal before the process terminates.
    func finishPendingDocumentWrites() async {
        await autosaveWriteTask?.value
    }

    /// Creates an untitled project from the settings sheet.
    func createNewProject(settings: EditorAjarNewProjectSettings) throws {
        try refuseReplacementWhenDirty()
        let newProject = try EditorAjarNewProjectFactory.makeProject(settings: settings)
        installProjectSession(
            .editable(newProject),
            documentURL: nil,
            savedBaseline: nil,
            unsavedName: AppString.localized("document.untitled", "Untitled")
        )
        isNewProjectSheetPresented = false
        loadMessage = AppString.localized("status.newProjectCreated", "New project created")
        resetAutosaveForInstalledProject()
    }

    /// #234 import seam for FR-PROJ-003 auto-detection from the first media item.
    ///
    /// The importer should call this before committing its first `MediaRef`, then apply the
    /// returned settings together with that import edit. Returning `nil` once media already exists
    /// makes the first-clip-only policy explicit without adding persisted lifecycle flags.
    func autoDetectedSettingsForFirstImportedMedia(
        _ media: MediaRef,
        detectedAudioSampleRate: Int? = nil
    ) -> ProjectSettings? {
        guard let project, project.mediaPool.isEmpty else {
            return nil
        }
        return EditorAjarFirstClipSettingsDetector.detectedSettings(
            from: media,
            current: project.settings,
            detectedAudioSampleRate: detectedAudioSampleRate
        )
    }

    /// Opens a user-selected package through recovery + existing read-only open machinery.
    func openProject(at url: URL) throws {
        try refuseReplacementWhenDirty()
        let standardizedURL = url.standardizedFileURL
        let scope = EditorAjarSecurityScopedAccess(url: standardizedURL)
        let opened = try documentStore.open(at: standardizedURL)
        installProjectSession(
            opened.loadResult,
            documentURL: standardizedURL,
            savedBaseline: opened.savedBaseline,
            unsavedName: nil
        )
        documentSecurityScope = scope
        recentProjectURLs = recentProjectsStore.record(standardizedURL)
        loadMessage = opened.recoveryIssues.isEmpty
            ? AppString.localized(
                "status.projectOpened",
                "Opened \(standardizedURL.deletingPathExtension().lastPathComponent)"
            )
            : AppString.localized(
                "status.projectOpenedWithRecovery",
                "Opened project at the last recoverable edit"
            )
        resetAutosaveForInstalledProject()
    }

    /// Opens a recent item, removing an entry that can no longer be opened.
    func openRecentProject(at url: URL) throws {
        do {
            try openProject(at: url)
        } catch {
            recentProjectURLs = recentProjectsStore.remove(url)
            throw error
        }
    }

    /// Explicit Help-menu sample path. Normal launch intentionally stays at New/Open.
    func openSampleProject() throws {
        try refuseReplacementWhenDirty()
        let sampleProject = try Self.makeSampleProject().get()
        installProjectSession(
            .editable(sampleProject),
            documentURL: nil,
            savedBaseline: sampleProject,
            unsavedName: AppString.localized("document.sample.name", "Sample Project")
        )
        loadMessage = AppString.localized("status.sampleProjectLoaded", "Sample project loaded")
        resetAutosaveForInstalledProject()
    }

    /// Saves over the represented package using canonical codec + atomic write APIs.
    func saveProject() throws {
        guard let project else {
            throw EditorAjarDocumentLifecycleError.noProject
        }
        guard let documentURL else {
            throw EditorAjarDocumentLifecycleError.documentHasNoURL
        }
        try requireEditableSaveMode()
        try documentStore.save(
            project: project,
            openMode: projectOpenMode,
            appliedCommandCount: autosaveCommandCount,
            to: documentURL
        )
        didSave(project: project, at: documentURL)
    }

    /// Saves to a new package, cloning non-identity sidecars from the current package first.
    func saveProjectAs(to destinationURL: URL) throws {
        guard let project else {
            throw EditorAjarDocumentLifecycleError.noProject
        }
        try requireEditableSaveMode()
        let standardizedURL = destinationURL.standardizedFileURL
        let newScope = EditorAjarSecurityScopedAccess(url: standardizedURL)
        try documentStore.saveAs(
            project: project,
            openMode: projectOpenMode,
            appliedCommandCount: autosaveCommandCount,
            sourceURL: documentURL,
            destinationURL: standardizedURL
        )
        documentSecurityScope = newScope
        didSave(project: project, at: standardizedURL)
    }

    /// Discards unsaved edits and reloads only the explicit saved bytes (no journal replay).
    func revertProject() throws {
        guard let documentURL else {
            throw EditorAjarDocumentLifecycleError.documentHasNoURL
        }
        let loadResult = try documentStore.revert(at: documentURL)
        installProjectSession(
            loadResult,
            documentURL: documentURL,
            savedBaseline: loadResult.project,
            unsavedName: nil
        )
        loadMessage = AppString.localized("status.projectReverted", "Reverted to saved project")
        resetAutosaveForInstalledProject()
    }

    /// Localizes a typed lifecycle/store failure for the root alert.
    func presentDocumentError(_ error: Error, operation: EditorAjarDocumentOperation) {
        let detail = localizedDocumentErrorDetail(error)
        switch operation {
        case .create:
            documentErrorMessage = AppString.localized(
                "document.error.create",
                "Could not create the project: \(detail)"
            )
        case .open:
            documentErrorMessage = AppString.localized(
                "document.error.open",
                "Could not open the project: \(detail)"
            )
        case .save:
            documentErrorMessage = AppString.localized(
                "document.error.save",
                "Could not save the project: \(detail)"
            )
        case .revert:
            documentErrorMessage = AppString.localized(
                "document.error.revert",
                "Could not revert the project: \(detail)"
            )
        case .sample:
            documentErrorMessage = AppString.localized(
                "document.error.sample",
                "Could not open the sample project: \(detail)"
            )
        }
    }

    /// Dismisses the document-operation alert.
    func dismissDocumentError() {
        documentErrorMessage = nil
    }

    // MARK: - Export dialog (FR-EXP-003 / FR-EXP-004)

    /// Opens the export dialog with the current preset list.
    func presentExportDialog() {
        reloadExportPresets()
        var dialog = exportDialog
        dialog.isPresented = true
        dialog.statusMessage = nil
        exportDialog = dialog
    }

    /// Closes the export dialog without starting an export.
    func dismissExportDialog() {
        var dialog = exportDialog
        dialog.isPresented = false
        dialog.statusMessage = nil
        exportDialog = dialog
    }

    func setExportMode(_ mode: EditorAjarExportMode) {
        var dialog = exportDialog
        dialog.mode = mode
        exportDialog = dialog
    }

    func setExportRangeChoice(_ choice: EditorAjarExportRangeChoice) {
        var dialog = exportDialog
        dialog.rangeChoice = choice
        exportDialog = dialog
    }

    func setExportPresetID(_ id: UUID) {
        var dialog = exportDialog
        dialog.selectedPresetID = id
        exportDialog = dialog
    }

    func setStillFormat(_ format: EditorAjarStillFormatChoice) {
        var dialog = exportDialog
        dialog.stillFormat = format
        exportDialog = dialog
    }

    func setAudioOnlyFormat(_ format: EditorAjarAudioOnlyFormatChoice) {
        var dialog = exportDialog
        dialog.audioOnlyFormat = format
        exportDialog = dialog
    }

    /// Validates the current dialog selection against the open project (unit-test surface).
    ///
    /// Does not write media files; the FR-EXP-005 queue owns background export execution.
    @discardableResult
    func validateExportDialogSelection() -> Bool {
        guard let project, let sequence = activeSequence else {
            var dialog = exportDialog
            dialog.statusMessage = AppString.localized(
                "export.status.noSequence", "No sequence available to export"
            )
            exportDialog = dialog
            return false
        }

        do {
            switch exportDialog.mode {
            case .video:
                _ = try exportDialog.makeVideoSettings()
                _ = try exportDialog.resolvedRange(
                    sequence: sequence,
                    selectionInFrame: timelineState.selectionInFrame,
                    selectionOutFrame: timelineState.selectionOutFrame
                )
            case .stillFrame:
                // Still validation requires time ∈ [0, duration). Clamp playhead at the last
                // valid frame when it sits on durationFrames (exclusive end of the timeline).
                let stillFrame = Self.clampedStillExportFrame(
                    playheadFrame: playheadFrame,
                    durationFrames: durationFrames
                )
                let time = try RationalTime.atFrame(stillFrame, frameRate: sequence.timebase)
                _ = try StillFrameExportRequest(
                    project: project,
                    sequenceID: sequence.id,
                    time: time,
                    destinationURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("validate-still.\(exportDialog.suggestedPathExtension)"),
                    format: exportDialog.stillFormat.stillFormat
                )
            case .audioOnly:
                _ = try exportDialog.makeAudioOnlySettings(
                    projectSampleRate: project.settings.audioSampleRate
                )
                _ = try exportDialog.resolvedRange(
                    sequence: sequence,
                    selectionInFrame: timelineState.selectionInFrame,
                    selectionOutFrame: timelineState.selectionOutFrame
                )
            }
            var dialog = exportDialog
            dialog.statusMessage = AppString.localized(
                "export.status.ready", "Ready to export \(exportDialog.mode.displayName.lowercased())"
            )
            exportDialog = dialog
            return true
        } catch {
            var dialog = exportDialog
            dialog.statusMessage = String(describing: error)
            exportDialog = dialog
            return false
        }
    }

    /// Saves a custom preset app-side (Application Support JSON — not the project package).
    func saveCustomExportPreset(_ preset: ExportPreset) throws {
        // Corrupt on-disk JSON must not permanently block saves — recover like
        // `reloadExportPresets` (empty custom list) and overwrite with the new preset.
        var customs: [ExportPreset]
        do {
            customs = try exportPresetStore.loadCustomPresets()
        } catch EditorAjarExportPresetStoreError.decodingFailed {
            customs = []
        }
        customs.removeAll { $0.id == preset.id }
        var stored = preset
        // Force non-built-in so we never overwrite compiled defaults on disk.
        stored = ExportPreset(
            id: preset.id,
            name: preset.name,
            isBuiltIn: false,
            container: preset.container,
            videoCodec: preset.videoCodec,
            resolution: preset.resolution,
            frameRate: preset.frameRate,
            averageBitRate: preset.averageBitRate,
            quality: preset.quality,
            colorSpace: preset.colorSpace,
            audio: preset.audio
        )
        try stored.validate()
        customs.append(stored)
        try exportPresetStore.saveCustomPresets(customs)
        reloadExportPresets()
    }

    private func reloadExportPresets() {
        let customs = (try? exportPresetStore.loadCustomPresets()) ?? []
        var dialog = exportDialog
        dialog.availablePresets = EditorAjarExportPresetStore.mergedPresets(custom: customs)
        if dialog.selectedPresetID == nil
            || !dialog.availablePresets.contains(where: { $0.id == dialog.selectedPresetID }) {
            dialog.selectedPresetID = dialog.availablePresets.first?.id
        }
        exportDialog = dialog
    }

    deinit {
        audioCoordinator?.stop()
        autosaveLoopTask?.cancel()
        autosaveWriteTask?.cancel()
        mediaResolutionTask?.cancel()
        mediaImportTask?.cancel()
        proxyObserveTask?.cancel()
    }

    private func startMediaResolution(for loadResult: AjarProjectLoadResult) {
        let originalProject = loadResult.project
        let openMode = loadResult.openMode
        mediaResolutionTask = Task { [weak self, originalProject, openMode] in
            let resolvedProject = await Task.detached(priority: .userInitiated) {
                MediaReferenceResolver().reconcile(originalProject)
            }.value
            guard !Task.isCancelled, let self, var history = self.editHistory else {
                return
            }
            do {
                let mergedProject = try history.reconcileMediaReferences(
                    expected: originalProject.mediaPool,
                    resolved: resolvedProject.mediaPool
                )
                self.editHistory = history
                self.updateProject(mergedProject)
                if openMode.allowsEditing {
                    self.scheduleAutosaveCheckpoint(project: mergedProject)
                }
            } catch {
                self.loadMessage = "Media availability refresh unavailable: \(error)"
            }
        }
    }

    // MARK: - Media import (FR-MED-001 / FR-MED-010)

    /// Whether File > Import Media and drag/drop may start a new batch.
    var canImportMedia: Bool {
        project != nil && projectOpenMode.allowsEditing && !isImportingMedia
    }

    /// Presents the multi-select file/folder picker.
    func presentMediaImporter() {
        guard canImportMedia else {
            if isProjectReadOnly {
                presentReadOnlyBannerIfNeeded()
            }
            return
        }
        isMediaImportPickerPresented = true
    }

    /// Dismisses the file/folder picker binding.
    func dismissMediaImporter() {
        isMediaImportPickerPresented = false
    }

    /// Handles the SwiftUI file-importer result without exposing picker details to the pipeline.
    func handleMediaImporterResult(_ result: Result<[URL], Error>) {
        isMediaImportPickerPresented = false
        switch result {
        case .success(let urls):
            importMedia(from: urls)
        case .failure(let error):
            guard !Self.isMediaPickerCancellation(error) else {
                return
            }
            loadMessage = AppString.localized(
                "import.picker.failed",
                "Media selection failed: \(error.localizedDescription)"
            )
        }
    }

    /// Starts an asynchronous import and returns immediately so menus/playback remain responsive.
    func importMedia(from urls: [URL]) {
        guard beginMediaImport(urls) else {
            return
        }
        mediaImportTask = Task { [weak self] in
            await self?.performMediaImport(urls)
        }
    }

    /// Deterministic awaitable import surface for app-model tests.
    func importMediaAndWait(from urls: [URL]) async {
        guard beginMediaImport(urls) else {
            return
        }
        await performMediaImport(urls)
    }

    /// Dismisses the result sheet while retaining its value for tests/session history.
    ///
    /// If a first-media settings proposal was deferred (H1 sequencing), present it now so only
    /// one sheet is active at a time on macOS.
    func dismissMediaImportSummary() {
        isMediaImportSummaryPresented = false
        if pendingFirstMediaProposal {
            pendingFirstMediaProposal = false
            isFirstMediaSettingsProposalPresented = true
        }
    }

    private func beginMediaImport(_ urls: [URL]) -> Bool {
        if urls.isEmpty {
            refuseMediaImport(.emptySelection)
            return false
        }
        guard project != nil else {
            refuseMediaImport(.noProject)
            return false
        }
        guard projectOpenMode.allowsEditing else {
            refuseMediaImport(.projectReadOnly)
            presentReadOnlyBannerIfNeeded()
            return false
        }
        guard !isImportingMedia else {
            refuseMediaImport(.importInProgress)
            return false
        }
        mediaImportError = nil
        isMediaImportPickerPresented = false
        isMediaImportSummaryPresented = false
        pendingFirstMediaProposal = false
        isImportingMedia = true
        mediaImportProgress = MediaImportProgress(
            phase: .discovering,
            completedUnitCount: 0,
            totalUnitCount: 0
        )
        return true
    }

    /// Keeps non-UI callers honest: a rejected import publishes a typed reason and visible status.
    private func refuseMediaImport(_ error: EditorAjarMediaImportError) {
        mediaImportError = error
        switch error {
        case .noProject:
            loadMessage = AppString.localized(
                "import.status.noProject",
                "Create or open a project before importing media."
            )
        case .projectReadOnly:
            loadMessage = AppString.localized(
                "import.status.readOnly",
                "Media cannot be imported into a read-only project."
            )
        case .importInProgress:
            loadMessage = AppString.localized(
                "import.status.inProgress",
                "A media import is already in progress."
            )
        case .emptySelection:
            loadMessage = AppString.localized(
                "import.status.emptySelection",
                "No media was selected for import."
            )
        }
    }

    private func performMediaImport(_ urls: [URL]) async {
        let existingMedia = project?.mediaPool ?? []
        let batch = await mediaImportPipeline.prepareImport(
            from: urls,
            existingMedia: existingMedia,
            projectPackageURL: projectPackageRootURL,
            progress: { [weak self] progress in
                await self?.receiveMediaImportProgress(progress)
            }
        )
        guard !Task.isCancelled else {
            isImportingMedia = false
            mediaImportProgress = nil
            return
        }

        var summary = batch.summary
        // FR-PROJ-003: propose (do not silently apply) settings when the first media lands in a
        // still-empty project that still uses the New Project sensible defaults.
        let detectedFirstMediaSettings: ProjectSettings?
        if existingMedia.isEmpty,
           let currentSettings = project?.settings,
           let defaultSettings = try? EditorAjarNewProjectSettings.sensibleDefaults
               .makeProjectSettings(),
           currentSettings.resolution == defaultSettings.resolution
               && currentSettings.frameRate == defaultSettings.frameRate
               && currentSettings.colorSpace == defaultSettings.colorSpace
               && currentSettings.audioSampleRate == defaultSettings.audioSampleRate,
           let firstImported = summary.imported.first
        {
            detectedFirstMediaSettings = autoDetectedSettingsForFirstImportedMedia(
                firstImported.mediaReference,
                detectedAudioSampleRate: firstImported.audioSampleRate
            )
        } else {
            detectedFirstMediaSettings = nil
        }
        if let command = batch.command, !applyEdit(command) {
            summary = Self.projectUpdateFailureSummary(from: batch.summary)
            loadMessage = AppString.localized(
                "import.status.applyFailed",
                "Imported media could not be added to the project."
            )
        } else {
            if let proposed = detectedFirstMediaSettings,
               let current = project?.settings,
               EditorAjarFirstClipSettingsDetector.proposalDiffersFromCurrent(
                   proposed,
                   current: current
               )
            {
                proposedFirstMediaSettings = proposed
                // Defer presentation until the import summary dismisses (H1: one sheet at a time).
                pendingFirstMediaProposal = true
            }
            let importedCount = summary.imported.count
            let skippedCount = summary.skippedDuplicates.count
            let failedCount = summary.failed.count
            loadMessage = AppString.localized(
                "import.status.complete",
                "Import complete: \(importedCount) imported, \(skippedCount) skipped, \(failedCount) failed"
            )
        }
        mediaImportSummary = summary
        mediaImportProgress = nil
        isImportingMedia = false
        isMediaImportSummaryPresented = true
        mediaImportTask = nil
    }

    /// Applies the FR-PROJ-003 first-media settings proposal as one undoable settings edit.
    func applyProposedFirstMediaSettings() {
        guard let proposed = proposedFirstMediaSettings else {
            dismissFirstMediaSettingsProposal()
            return
        }
        _ = applyEdit(.setProjectSettings(proposed))
        loadMessage = AppString.localized(
            "document.settings.autoDetect.applied",
            "Project settings updated from first media"
        )
        dismissFirstMediaSettingsProposal()
    }

    /// Declines the FR-PROJ-003 first-media settings proposal (keeps current settings).
    func declineProposedFirstMediaSettings() {
        loadMessage = AppString.localized(
            "document.settings.autoDetect.declined",
            "Kept current project settings"
        )
        dismissFirstMediaSettingsProposal()
    }

    func dismissFirstMediaSettingsProposal() {
        proposedFirstMediaSettings = nil
        isFirstMediaSettingsProposalPresented = false
        pendingFirstMediaProposal = false
    }

    private func receiveMediaImportProgress(_ progress: MediaImportProgress) {
        guard isImportingMedia else {
            return
        }
        mediaImportProgress = progress
    }

    private static func isMediaPickerCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && cocoaError.code == CocoaError.Code.userCancelled.rawValue
    }

    private static func projectUpdateFailureSummary(
        from summary: MediaImportSummary
    ) -> MediaImportSummary {
        let reason = AppString.localized(
            "import.failure.projectUpdate.reason",
            "The open project rejected the import batch."
        )
        let updateFailures = summary.imported.map { item in
            FailedMediaImportItem(
                sourceURL: item.sourceURL,
                error: .projectUpdateFailed(url: item.sourceURL, reason: reason)
            )
        }
        return MediaImportSummary(
            imported: [],
            skippedDuplicates: summary.skippedDuplicates,
            vfrConformed: [],
            transcoded: [],
            failed: summary.failed + updateFailures
        )
    }

    var canUndo: Bool {
        projectOpenMode.allowsEditing && (editHistory?.undoCount ?? 0) > 0
    }

    var canRedo: Bool {
        projectOpenMode.allowsEditing && (editHistory?.redoCount ?? 0) > 0
    }

    /// Whether the open project may be edited and resaved (FR-PROJ-005).
    var isProjectEditable: Bool {
        projectOpenMode.allowsEditing
    }

    /// Whether the open project is read-only (higher schema minor).
    var isProjectReadOnly: Bool {
        !projectOpenMode.allowsEditing
    }

    /// Typed reason when the session is read-only.
    var projectReadOnlyReason: AjarProjectReadOnlyReason? {
        if case .readOnly(let reason) = projectOpenMode {
            return reason
        }
        return nil
    }

    /// User-facing banner copy for a read-only open (nil when banner is hidden).
    var readOnlyBannerMessage: String? {
        guard isReadOnlyBannerVisible, let reason = projectReadOnlyReason else {
            return nil
        }
        return AppString.readOnlyProjectMessage(for: reason)
    }

    /// Save / autosave gate: blocked for read-only opens (FR-PROJ-005 / ADR-0018).
    var canSaveProject: Bool {
        project != nil && projectOpenMode.allowsEditing
    }

    /// Dismisses the read-only workspace banner (keyboard-reachable from the banner control).
    func dismissReadOnlyBanner() {
        isReadOnlyBannerVisible = false
    }

    /// Shows or hides the background export queue panel (FR-EXP-005).
    func toggleExportQueuePanel() {
        isExportQueuePanelVisible.toggle()
    }

    /// Whether playback prefers proxy media when ready (FR-MED-004).
    var preferProxyPlayback: Bool {
        project?.settings.preferProxyPlayback ?? false
    }

    /// One-click project-level proxy/original playback toggle (FR-MED-004).
    ///
    /// Persists on `ProjectSettings` so reopening a heavy project keeps proxy mode.
    @discardableResult
    func togglePreferProxyPlayback() -> Bool {
        guard let project else {
            return false
        }
        let next = !project.settings.preferProxyPlayback
        let updated = project.updatingPreferProxyPlayback(next)
        if var history = editHistory, projectOpenMode.allowsEditing {
            self.project = history.replaceCurrentProjectPreservingHistory(updated)
            editHistory = history
            refreshDirtyState()
            scheduleAutosaveCheckpoint(project: updated)
        } else {
            // Session-local flip under read-only open (no package rewrite).
            self.project = updated
            refreshDirtyState()
        }
        loadMessage = next
            ? AppString.localized("status.proxyPlaybackOn", "Proxy playback on")
            : AppString.localized("status.originalPlaybackOn", "Original playback on")
        requestRenderForCurrentFrame()
        return true
    }

    /// Enqueues a ProRes export of the active sequence range (full sequence by default).
    ///
    /// Captures the current `project` value into the queue job so later edits cannot mutate
    /// the in-flight encode (FR-EXP-005 snapshot isolation).
    func enqueueActiveSequenceExport(destinationURL: URL? = nil) {
        guard let project, let sequence = activeSequence else {
            exportQueueController.presentError(
                NSError(
                    domain: "EditorAjar",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No active sequence to export"
                    ]
                )
            )
            isExportQueuePanelVisible = true
            return
        }

        let exportsDirectory = FileManager.default.urls(
            for: .moviesDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("Editor Ajar Exports", isDirectory: true)
            ?? FileManager.default.temporaryDirectory

        do {
            try FileManager.default.createDirectory(
                at: exportsDirectory,
                withIntermediateDirectories: true
            )
            let settings = try EditorAjarExportQueueController.defaultSettings(for: project)
            let url =
                destinationURL
                ?? exportsDirectory.appendingPathComponent(
                    "\(sequence.name)-\(UUID().uuidString.prefix(8)).mov"
                )
            let duration = try sequence.timelineDuration()
            let range = try TimeRange(start: .zero, duration: duration)
            // Snapshot `project` by value at enqueue (struct copy).
            let snapshot = project
            Task {
                do {
                    _ = try await exportQueueController.enqueueExport(
                        project: snapshot,
                        sequenceID: sequence.id,
                        range: range,
                        destinationURL: url,
                        settings: settings,
                        displayName: sequence.name
                    )
                    isExportQueuePanelVisible = true
                } catch {
                    exportQueueController.presentError(error)
                    isExportQueuePanelVisible = true
                }
            }
        } catch {
            exportQueueController.presentError(error)
            isExportQueuePanelVisible = true
        }
    }

    func cancelExportJob(_ jobID: UUID) {
        Task {
            do {
                try await exportQueueController.cancel(jobID: jobID)
            } catch {
                exportQueueController.presentError(error)
            }
        }
    }

    func pauseExportJob(_ jobID: UUID) {
        Task {
            do {
                try await exportQueueController.pause(jobID: jobID)
            } catch {
                exportQueueController.presentError(error)
            }
        }
    }

    func resumeExportJob(_ jobID: UUID) {
        Task {
            do {
                try await exportQueueController.resume(jobID: jobID)
            } catch {
                exportQueueController.presentError(error)
            }
        }
    }

    /// Re-shows the read-only banner when the user tries an edit after dismissing it.
    func presentReadOnlyBannerIfNeeded() {
        guard isProjectReadOnly else {
            return
        }
        isReadOnlyBannerVisible = true
    }

    var undoMenuTitle: String {
        editMenuTitle(
            prefix: AppString.localized("menu.edit.undo", "Undo"),
            command: editHistory?.nextUndoCommand
        )
    }

    var redoMenuTitle: String {
        editMenuTitle(
            prefix: AppString.localized("menu.edit.redo", "Redo"),
            command: editHistory?.nextRedoCommand
        )
    }

    var activeSequence: Sequence? {
        guard let project else {
            return nil
        }
        if let activeSequenceID,
           let sequence = project.sequences.first(where: { $0.id == activeSequenceID })
        {
            return sequence
        }
        return project.sequences.first
    }

    var activeSequenceName: String {
        activeSequence?.name ?? AppString.localized("sequence.none", "No Sequence")
    }

    var sequenceTabs: [SequenceTab] {
        guard let project else {
            return []
        }
        let activeID = activeSequence?.id
        let canClose = isProjectEditable && project.sequences.count > 1
        return project.sequences.map { sequence in
            SequenceTab(
                id: sequence.id,
                title: sequence.name,
                isActive: sequence.id == activeID,
                canClose: canClose
            )
        }
    }

    var canCloseActiveSequence: Bool {
        isProjectEditable && (project?.sequences.count ?? 0) > 1
    }

    var projectSummary: String {
        guard let project else {
            return AppString.localized("project.summary.none", "No project")
        }

        let sequenceCount = project.sequences.count
        let mediaCount = project.mediaPool.count
        let sequenceLabel = sequenceCount == 1
            ? AppString.localized("project.summary.sequence", "sequence")
            : AppString.localized("project.summary.sequences", "sequences")
        return AppString.localized(
            "project.summary",
            "\(sequenceCount) \(sequenceLabel), \(mediaCount) media items"
        )
    }

    var frameRateDescription: String {
        playbackController?.frameRateDescription ?? "--"
    }

    var playheadDescription: String {
        AppString.localized("frame.value", "Frame \(playheadFrame)")
    }

    var playbackRate: Int {
        playbackController?.playbackRate ?? 0
    }

    /// Audio scrubbing is intentionally typed off until the audio coordinator exposes a
    /// non-real-time preview route; toggling the live render callback would violate ADR-0012.
    var audioScrubbingUnavailableReason: String {
        AppString.localized(
            "playback.audioScrub.unavailable",
            "Audio scrubbing is unavailable until a safe preview-audio path is added"
        )
    }

    var timelineSnappingEnabled: Bool {
        timelineState.snappingEnabled
    }

    var timelineSelectedClipCount: Int {
        timelineState.selectedClips.count
    }

    var selectedClipReference: TimelineClipReference? {
        guard timelineState.selectedClips.count == 1 else {
            return nil
        }
        return timelineState.selectedClips.first
    }

    var selectedProjectClipReference: ProjectClipReference? {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference
        else {
            return nil
        }
        return ProjectClipReference(
            sequenceID: sequenceID,
            trackID: selectedClipReference.trackID,
            clipID: selectedClipReference.clipID
        )
    }

    var selectedClip: Clip? {
        guard let selectedClipReference,
              let sequence = activeSequence
        else {
            return nil
        }
        return Self.clip(selectedClipReference, in: sequence)
    }

    var selectedClipSpeedPercent: String {
        guard let clip = selectedClip else { return "100" }
        return String(Double(clip.speed.numerator) / Double(clip.speed.denominator) * 100)
    }

    @discardableResult
    func updateSelectedClipSpeed(percentText: String) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let reference = selectedClipReference,
              let percent = Double(percentText), percent > 0,
              percent.isFinite else { return false }
        let scaled = Int64((percent * 1_000).rounded())
        guard let speed = try? RationalValue(numerator: scaled, denominator: 100_000) else {
            return false
        }
        return applyEdit(.setClipSpeed(
            sequenceID: sequenceID, trackID: reference.trackID,
            clipID: reference.clipID, speed: speed
        ))
    }

    @discardableResult
    func setSelectedClipReverse(_ reverse: Bool) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let reference = selectedClipReference,
              let clip = selectedClip else { return false }
        return applyEdit(.setClipPlaybackAttributes(
            sequenceID: sequenceID, trackID: reference.trackID, clipID: reference.clipID,
            reverse: reverse, freezeFrame: clip.freezeFrame
        ))
    }

    @discardableResult
    func setSelectedClipFreezeFrame(_ freezeFrame: Bool) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let reference = selectedClipReference,
              let clip = selectedClip else { return false }
        return applyEdit(.setClipPlaybackAttributes(
            sequenceID: sequenceID, trackID: reference.trackID, clipID: reference.clipID,
            reverse: clip.reverse, freezeFrame: freezeFrame
        ))
    }

    var savedLooks: [ProjectLook] {
        project?.looks ?? []
    }

    var canCopyGrade: Bool {
        // Copy is non-destructive; allowed even for read-only inspection.
        guard let selectedClip, selectedClip.kind == .video else {
            return false
        }
        return !selectedClip.effectStack.grade.nodes.isEmpty
    }

    var canPasteGrade: Bool {
        guard isProjectEditable,
              selectedClip?.kind == .video,
              let project,
              let copiedGradeSource,
              let sourceClip = Self.clip(copiedGradeSource, in: project)
        else {
            return false
        }
        return !sourceClip.effectStack.grade.nodes.isEmpty
    }

    var canSaveLook: Bool {
        isProjectEditable && canCopyGrade
    }

    var canApplyLook: Bool {
        isProjectEditable && selectedClip?.kind == .video && !savedLooks.isEmpty
    }

    var selectedTransformClipReference: TimelineClipReference? {
        guard let selectedClipReference,
              selectedClip?.kind == .video
        else {
            return nil
        }
        return selectedClipReference
    }

    var selectedTransformInspector: SelectedTransformInspectorState? {
        guard let selectedClip,
              selectedClip.kind == .video,
              let sequence = activeSequence,
              let time = playheadTime(in: sequence)
        else {
            return nil
        }

        return SelectedTransformInspectorState(
            clipName: selectedClip.name,
            transform: selectedClip.transformAnimation.value(at: time)
        )
    }

    var selectedTrackCompositingInspector: SelectedTrackCompositingInspectorState? {
        guard let reference = selectedTransformClipReference,
              let sequence = activeSequence,
              let trackIndex = sequence.videoTracks.firstIndex(where: { $0.id == reference.trackID }),
              let time = playheadTime(in: sequence)
        else {
            return nil
        }

        let track = sequence.videoTracks[trackIndex]
        return SelectedTrackCompositingInspectorState(
            trackName: "Video track \(trackIndex + 1)",
            opacity: track.opacity.value(at: time),
            blendMode: track.blendMode
        )
    }

    var selectedTransformKeyframeLanes: [TransformKeyframeLane] {
        guard let selectedClip,
              selectedClip.kind == .video,
              let sequence = activeSequence
        else {
            return []
        }

        return TransformKeyframeLane.makeLanes(
            animation: selectedClip.transformAnimation,
            frameRate: sequence.timebase,
            pixelsPerFrame: timelineState.pixelsPerFrame
        )
    }

    var selectedCanvasTransformLayout: CanvasClipTransformLayout? {
        guard let project,
              let selectedClip,
              selectedClip.kind == .video,
              let sequence = activeSequence,
              let time = playheadTime(in: sequence),
              let clipDimensions = Self.mediaDimensions(for: selectedClip, in: project)
        else {
            return nil
        }

        return CanvasClipTransformLayout(
            canvasSize: project.settings.resolution,
            clipSize: clipDimensions,
            transform: selectedClip.transformAnimation.value(at: time)
        )
    }

    var selectedClipIsLinked: Bool {
        selectedClip?.linkGroupID != nil
    }

    var canvasDimensions: PixelDimensions? {
        project?.settings.resolution
    }

    var canvasAspectRatio: Double {
        guard let canvasDimensions, canvasDimensions.height > 0 else {
            return 16.0 / 9.0
        }
        return Double(canvasDimensions.width) / Double(canvasDimensions.height)
    }

    var visibleCanvasTitleBoxes: [CanvasTitleBoxLayout] {
        guard let project,
              let sequence = activeSequence,
              let time = playheadTime(in: sequence)
        else {
            return []
        }

        var layouts: [CanvasTitleBoxLayout] = []
        for track in sequence.videoTracks where track.enabled && !track.hidden {
            for item in track.items {
                guard case .clip(let clip) = item,
                      (try? clip.timelineRange.contains(time)) == true,
                      case .title(let title) = clip.source
                else {
                    continue
                }

                let transform = clip.transformAnimation.value(at: time)
                for (boxIndex, box) in title.boxes.enumerated() {
                    layouts.append(
                        CanvasTitleBoxLayout(
                            canvasSize: project.settings.resolution,
                            reference: CanvasTitleBoxReference(
                                sequenceID: sequence.id,
                                trackID: track.id,
                                clipID: clip.id,
                                boxID: box.id
                            ),
                            box: box,
                            boxIndex: boxIndex,
                            clipName: clip.name,
                            clipTransform: transform,
                            isEditable: !track.locked
                        )
                    )
                }
            }
        }
        return layouts
    }

    var selectedMarker: Marker? {
        guard let selectedMarkerID = timelineState.selectedMarkerID else {
            return nil
        }
        return activeSequence?.markers.first { $0.id == selectedMarkerID }
    }

    /// Human-readable in/out range. Both marks are **inclusive** frame indices (NLE convention);
    /// export resolves them to the half-open engine span `[in, out+1)`.
    var timelineRangeDescription: String {
        switch (timelineState.selectionInFrame, timelineState.selectionOutFrame) {
        case (.some(let inFrame), .some(let outFrame)):
            let startFrame = min(inFrame, outFrame)
            let endFrame = max(inFrame, outFrame)
            return AppString.localized("timeline.range.inOut", "Range \(startFrame)-\(endFrame)")
        case (.some(let inFrame), .none):
            return AppString.localized("timeline.range.in", "Range in \(inFrame)")
        case (.none, .some(let outFrame)):
            return AppString.localized("timeline.range.out", "Range out \(outFrame)")
        case (.none, .none):
            return AppString.localized("timeline.range.none", "No range")
        }
    }

    var metalDevice: MTLDevice? {
        renderPipeline?.device
    }

    func togglePlayback() {
        isPlaying ? shuttlePause() : shuttleForward()
    }

    func shuttleBackward() {
        playbackController?.shuttleBackward()
        isPlaying = true
        stopAudioPlayback()
        displayLinkDriver?.start()
    }

    func shuttlePause() {
        playbackController?.shuttlePause()
        isPlaying = false
        stopAudioPlayback()
        displayLinkDriver?.stop()
    }

    func shuttleForward() {
        playbackController?.shuttleForward()
        isPlaying = true
        if playbackRate == 1 {
            startAudioPlayback()
        } else {
            stopAudioPlayback()
        }
        displayLinkDriver?.start()
    }

    func toggleLoopRange() {
        guard let lower = timelineState.selectionInFrame,
              let upper = timelineState.selectionOutFrame else {
            isLoopRangeEnabled = false
            playbackController?.setLoopRange(nil)
            loadMessage = AppString.localized(
                "playback.loop.needsRange",
                "Set both range In and Out before enabling loop playback"
            )
            return
        }
        isLoopRangeEnabled.toggle()
        playbackController?.setLoopRange(
            isLoopRangeEnabled ? min(lower, upper)...max(lower, upper) : nil
        )
    }

    func toggleCheckerboardAlpha() {
        checkerboardAlphaVisible.toggle()
    }

    func toggleProgramMonitorFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    func jumpToStart() { scrub(to: 0) }
    func jumpToEnd() { scrub(to: max(0, durationFrames - 1)) }

    func jumpToRangeIn() {
        if let frame = timelineState.selectionInFrame { scrub(to: frame) }
    }

    func jumpToRangeOut() {
        if let frame = timelineState.selectionOutFrame { scrub(to: frame) }
    }

    func jumpToNextEditPoint() {
        if let target = editPointFrames.first(where: { $0 > playheadFrame }) { scrub(to: target) }
    }

    func jumpToPreviousEditPoint() {
        if let target = editPointFrames.last(where: { $0 < playheadFrame }) { scrub(to: target) }
    }

    private var editPointFrames: [Int64] {
        guard let sequence = activeSequence else { return [] }
        return Self.editPointFrames(
            in: sequence,
            durationFrames: durationFrames
        )
    }

    static func editPointFrames(in sequence: Sequence, durationFrames: Int64) -> [Int64] {
        Set((sequence.videoTracks + sequence.audioTracks).flatMap { track in
            track.items.flatMap { item -> [Int64] in
                guard case .clip(let clip) = item,
                      let start = try? clip.timelineRange.start.frameIndex(
                        at: sequence.timebase, rounding: .nearestOrAwayFromZero
                      ),
                      let endTime = try? clip.timelineRange.end(),
                      let end = try? endTime.frameIndex(
                        at: sequence.timebase, rounding: .nearestOrAwayFromZero
                      ) else { return [] }
                return [start, min(max(0, durationFrames - 1), end)]
            }
        }).sorted()
    }

    @discardableResult
    func selectSequence(_ sequenceID: UUID) -> Bool {
        guard let project,
              let sequence = project.sequences.first(where: { $0.id == sequenceID })
        else {
            return false
        }

        persistActiveSequenceContext()
        isPlaying = false
        isLoopRangeEnabled = false
        stopAudioPlayback()
        displayLinkDriver?.stop()
        restoreActiveSequenceContext(for: sequence)
        requestRenderForCurrentFrame()
        return true
    }

    @discardableResult
    func addSequence() -> Bool {
        guard let project else {
            return false
        }

        let sequence = Self.emptySequence(
            name: Self.nextSequenceName(in: project),
            frameRate: project.settings.frameRate
        )
        guard applyEdit(.addSequence(sequence)) else {
            return false
        }

        return selectSequence(sequence.id)
    }

    @discardableResult
    func closeActiveSequence() -> Bool {
        guard let sequenceID = activeSequence?.id else {
            return false
        }
        return closeSequence(sequenceID)
    }

    @discardableResult
    func closeSequence(_ sequenceID: UUID) -> Bool {
        guard let project else {
            return false
        }
        let replacementID = Self.replacementSequenceID(
            afterRemoving: sequenceID,
            from: project
        )
        let isRemovingActiveSequence = activeSequence?.id == sequenceID

        guard applyEdit(.removeSequence(sequenceID: sequenceID)) else {
            return false
        }

        if isRemovingActiveSequence, let replacementID {
            selectSequence(replacementID)
        }
        return true
    }

    func stepBackward() {
        isPlaying = false
        stopAudioPlayback()
        displayLinkDriver?.stop()
        playbackController?.stepBackward()
        syncPlayheadFromController()
        publishAudioPlanForCurrentFrame()
        requestRenderForCurrentFrame()
    }

    func stepForward() {
        isPlaying = false
        stopAudioPlayback()
        displayLinkDriver?.stop()
        playbackController?.stepForward()
        syncPlayheadFromController()
        publishAudioPlanForCurrentFrame()
        requestRenderForCurrentFrame()
    }

    func scrub(to frame: Int64) {
        isPlaying = false
        stopAudioPlayback()
        displayLinkDriver?.stop()
        playbackController?.scrub(to: frame)
        syncPlayheadFromController()
        publishAudioPlanForCurrentFrame()
        requestRenderForCurrentFrame()
    }

    func scrubTimeline(xPosition: Double, snappingDisabled: Bool = false) {
        let proposedFrame = TimelineInteraction.frame(
            atX: xPosition,
            pixelsPerFrame: timelineState.pixelsPerFrame,
            durationFrames: durationFrames
        )
        let frame: Int64
        if timelineState.snappingEnabled && !snappingDisabled, let sequence = activeSequence {
            frame = TimelineInteraction.snappedFrame(
                proposedFrame: proposedFrame,
                targets: TimelineInteraction.snapTargets(
                    in: sequence,
                    playheadFrame: playheadFrame
                ),
                toleranceFrames: timelineState.snapToleranceFrames
            )
        } else {
            frame = proposedFrame
        }
        scrub(to: frame)
    }

    func timelineClipLayouts(for track: Track) -> [TimelineClipLayout] {
        guard let sequence = activeSequence else {
            return []
        }
        return TimelineInteraction.clipLayouts(
            for: track,
            frameRate: sequence.timebase,
            pixelsPerFrame: timelineState.pixelsPerFrame
        )
    }

    func timelineContentWidth(minimumWidth: Double) -> Double {
        TimelineInteraction.contentWidth(
            durationFrames: durationFrames,
            pixelsPerFrame: timelineState.pixelsPerFrame,
            minimumWidth: minimumWidth
        )
    }

    func timelineMarkerLayouts() -> [TimelineMarkerLayout] {
        guard let sequence = activeSequence else {
            return []
        }

        return sequence.markers.compactMap { marker in
            guard let frame = try? marker.time.frameIndex(
                at: sequence.timebase,
                rounding: .nearestOrAwayFromZero
            ) else {
                return nil
            }

            return TimelineMarkerLayout(
                markerID: marker.id,
                name: marker.name,
                note: marker.note,
                color: marker.color,
                frame: frame,
                xPosition: timelineXPosition(for: frame)
            )
        }
    }

    func timelineXPosition(for frame: Int64) -> Double {
        TimelineInteraction.xPosition(frame: frame, pixelsPerFrame: timelineState.pixelsPerFrame)
    }

    func isClipSelected(_ reference: TimelineClipReference) -> Bool {
        timelineState.selectedClips.contains(reference)
    }

    func selectClip(trackID: UUID, clipID: UUID, mode: TimelineSelectionMode) {
        guard let sequence = activeSequence else {
            return
        }
        let reference = TimelineClipReference(trackID: trackID, clipID: clipID)
        let result = TimelineInteraction.reducedSelection(
            currentSelection: timelineState.selectedClips,
            anchor: timelineState.selectionAnchor,
            visibleClipReferences: TimelineInteraction.clipReferences(in: sequence),
            reference: reference,
            mode: mode
        )
        timelineState.selectedClips = result.selectedClips
        timelineState.selectionAnchor = result.anchor
        timelineState.selectedMarkerID = nil
        persistActiveSequenceContext()
    }

    func focusTimeline() {
        timelineHasFocus = true
    }

    func selectTimelineTrack(_ trackID: UUID) {
        selectedTimelineTrackID = trackID
        timelineHasFocus = true
    }

    func blurTimeline() {
        timelineHasFocus = false
    }

    /// Records a text field gaining or losing keyboard focus (#240 review, finding 1).
    ///
    /// Gaining focus blurs the timeline so destructive clipboard/delete commands refuse while
    /// typing; losing focus does not restore timeline focus — the next timeline interaction
    /// (clip click, track selection, blade toggle) reclaims it explicitly via `focusTimeline()`.
    func textEditorFocusChanged(id: UUID, isFocused: Bool) {
        if isFocused {
            focusedTextEditorIDs.insert(id)
            timelineHasFocus = false
        } else {
            focusedTextEditorIDs.remove(id)
        }
    }

    func setSelectedMediaIDs(_ ids: Set<UUID>) {
        selectedMediaIDs = ids
        timelineHasFocus = false
    }

    func toggleBladeTool() {
        guard !isTextEditingActive else { return }
        timelineTool = timelineTool == .blade ? .selection : .blade
        timelineHasFocus = true
    }

    func cancelTimelineGesture() {
        timelineGestureFeedback = nil
        timelineSnapIndicatorFrame = nil
    }

    @discardableResult
    func copyGradeFromSelectedClip() -> Bool {
        guard canCopyGrade,
              let selectedProjectClipReference
        else {
            return false
        }
        copiedGradeSource = selectedProjectClipReference
        return true
    }

    @discardableResult
    func pasteGradeToSelectedClip() -> Bool {
        guard let project,
              let source = copiedGradeSource,
              let target = selectedProjectClipReference,
              let sourceClip = Self.clip(source, in: project)
        else {
            return false
        }
        let newNodeIDs = sourceClip.effectStack.grade.nodes.map { _ in UUID() }
        guard !newNodeIDs.isEmpty else {
            return false
        }
        return applyEdit(
            .copyClipGrade(source: source, target: target, newNodeIDs: newNodeIDs)
        )
    }

    @discardableResult
    func saveLookFromSelectedClip() -> Bool {
        guard let project,
              canSaveLook,
              let source = selectedProjectClipReference
        else {
            return false
        }
        return applyEdit(
            .saveLookFromClip(
                source: source,
                lookID: UUID(),
                name: Self.nextLookName(in: project)
            )
        )
    }

    @discardableResult
    func applyLookToSelectedClip(lookID: UUID) -> Bool {
        guard let target = selectedProjectClipReference,
              let look = savedLooks.first(where: { $0.id == lookID })
        else {
            return false
        }
        let newNodeIDs = look.grade.nodes.map { _ in UUID() }
        guard !newNodeIDs.isEmpty else {
            return false
        }
        return applyEdit(
            .applyLookToClip(lookID: lookID, target: target, newNodeIDs: newNodeIDs)
        )
    }

    @discardableResult
    func beginCanvasTitleTextEditing(_ reference: CanvasTitleBoxReference) -> Bool {
        guard let layout = canvasTitleLayout(for: reference), layout.isEditable else {
            return false
        }

        selectClip(trackID: reference.trackID, clipID: reference.clipID, mode: .replace)
        selectedCanvasTitleBoxReference = reference
        editingCanvasTitleBoxReference = reference
        canvasTitleEditingUndoBaseline = editHistory?.undoCount
        return true
    }

    /// Ends the active canvas-title text session.
    ///
    /// When `reference` is provided, teardown is a no-op if another box already
    /// owns the session — so a late `textDidEndEditing` commit from box A cannot
    /// clobber a session that already moved to box B (direct click-to-other-box).
    func endCanvasTitleTextEditing(for reference: CanvasTitleBoxReference? = nil) {
        if let reference, editingCanvasTitleBoxReference != reference {
            return
        }
        editingCanvasTitleBoxReference = nil
        canvasTitleEditingUndoBaseline = nil
    }

    @discardableResult
    func selectCanvasTitleBox(_ reference: CanvasTitleBoxReference) -> Bool {
        guard let layout = canvasTitleLayout(for: reference), layout.isEditable else {
            return false
        }

        if editingCanvasTitleBoxReference != reference {
            endCanvasTitleTextEditing()
        }
        selectClip(trackID: reference.trackID, clipID: reference.clipID, mode: .replace)
        selectedCanvasTitleBoxReference = reference
        return true
    }

    @discardableResult
    func editAdjacentCanvasTitleBox(
        from reference: CanvasTitleBoxReference,
        reverse: Bool
    ) -> CanvasTitleBoxReference? {
        let editable = visibleCanvasTitleBoxes.filter(\.isEditable)
        guard !editable.isEmpty,
              let currentIndex = editable.firstIndex(where: { $0.reference == reference })
        else {
            return nil
        }

        let offset = reverse ? editable.count - 1 : 1
        let nextIndex = (currentIndex + offset) % editable.count
        let nextReference = editable[nextIndex].reference
        endCanvasTitleTextEditing()
        return beginCanvasTitleTextEditing(nextReference) ? nextReference : nil
    }

    @discardableResult
    func updateCanvasTitleText(
        _ text: String,
        reference: CanvasTitleBoxReference
    ) -> Bool {
        guard let layout = canvasTitleLayout(for: reference),
              layout.isEditable,
              layout.box.text != text
        else {
            return canvasTitleLayout(for: reference)?.box.text == text
        }

        let replacement = CanvasTitleBoxEditor.copying(layout.box, text: text)
        let shouldCoalesce = canCoalesceCanvasTitleTextEdit(for: reference)
        return applyEdit(
            .setTitleTextBox(
                sequenceID: reference.sequenceID,
                trackID: reference.trackID,
                clipID: reference.clipID,
                box: replacement
            ),
            coalescingWithPrevious: shouldCoalesce
        )
    }

    @discardableResult
    func dragCanvasTitleBox(
        _ reference: CanvasTitleBoxReference,
        translationX: Double,
        translationY: Double,
        canvasScale: Double
    ) -> Bool {
        guard let layout = canvasTitleLayout(for: reference), layout.isEditable else {
            return false
        }

        let origin = CanvasTitlePositioning.draggedOrigin(
            for: layout,
            translationX: translationX,
            translationY: translationY,
            canvasScale: canvasScale
        )
        return setCanvasTitleBoxOrigin(origin, layout: layout)
    }

    @discardableResult
    func nudgeCanvasTitleBox(
        _ reference: CanvasTitleBoxReference,
        direction: CanvasTitleNudgeDirection,
        largeStep: Bool
    ) -> Bool {
        guard let layout = canvasTitleLayout(for: reference), layout.isEditable else {
            return false
        }

        let origin = CanvasTitlePositioning.nudgedOrigin(
            for: layout,
            direction: direction,
            step: largeStep ? 10 : 1
        )
        return setCanvasTitleBoxOrigin(origin, layout: layout)
    }

    func toggleCanvasSafeAreaGuides() {
        canvasSafeAreaGuidesVisible.toggle()
    }

    /// Preferred canvas title for menu / keyboard commands (selected, editing, or first visible).
    var primaryCanvasTitleBoxReference: CanvasTitleBoxReference? {
        selectedCanvasTitleBoxReference
            ?? editingCanvasTitleBoxReference
            ?? visibleCanvasTitleBoxes.first?.reference
    }

    @discardableResult
    func editPrimaryCanvasTitleBox() -> Bool {
        guard let reference = primaryCanvasTitleBoxReference else {
            return false
        }
        return beginCanvasTitleTextEditing(reference)
    }

    @discardableResult
    func nudgePrimaryCanvasTitleBox(
        direction: CanvasTitleNudgeDirection,
        largeStep: Bool
    ) -> Bool {
        guard let reference = primaryCanvasTitleBoxReference else {
            return false
        }
        return nudgeCanvasTitleBox(reference, direction: direction, largeStep: largeStep)
    }

    func selectAllClips(on trackID: UUID) {
        guard let sequence = activeSequence else {
            return
        }
        let selectedClips = TimelineInteraction.clipReferences(in: sequence)
            .filter { $0.trackID == trackID }
        timelineState.selectedClips = Set(selectedClips)
        timelineState.selectionAnchor = selectedClips.first
        timelineState.selectedMarkerID = nil
        persistActiveSequenceContext()
    }

    func transformFieldValue(_ field: TransformInspectorField) -> String {
        guard let transform = selectedTransformInspector?.transform else {
            return ""
        }
        return TransformFieldValueMapper.stringValue(for: field, in: transform)
    }

    func selectedTrackOpacityPercentValue() -> String {
        guard let state = selectedTrackCompositingInspector else {
            return ""
        }
        return TrackCompositingValueMapper.percentString(from: state.opacity)
    }

    @discardableResult
    func updateSelectedTransformField(_ field: TransformInspectorField, rawValue: String) -> Bool {
        guard let transform = selectedTransformInspector?.transform,
              let replacement = TransformFieldValueMapper.updatedTransform(
                field,
                rawValue: rawValue,
                in: transform
              )
        else {
            return false
        }

        return updateSelectedClipTransform(replacement)
    }

    @discardableResult
    func updateSelectedClipBlendMode(_ blendMode: ClipBlendMode) -> Bool {
        guard let transform = selectedTransformInspector?.transform else {
            return false
        }

        return updateSelectedClipTransform(
            TransformEditor.copying(transform, blendMode: blendMode)
        )
    }

    @discardableResult
    func updateSelectedTrackOpacityPercent(rawValue: String) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let reference = selectedTransformClipReference,
              let opacity = TrackCompositingValueMapper.percent(rawValue)
        else {
            return false
        }

        return applyEdit(
            .setTrackCompositing(
                sequenceID: sequenceID,
                trackID: reference.trackID,
                compositing: TrackCompositingPatch(opacity: .constant(opacity))
            )
        )
    }

    @discardableResult
    func updateSelectedTrackBlendMode(_ blendMode: ClipBlendMode) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let reference = selectedTransformClipReference
        else {
            return false
        }

        return applyEdit(
            .setTrackCompositing(
                sequenceID: sequenceID,
                trackID: reference.trackID,
                compositing: TrackCompositingPatch(blendMode: blendMode)
            )
        )
    }

    @discardableResult
    func updateSelectedClipFlip(horizontal: Bool? = nil, vertical: Bool? = nil) -> Bool {
        guard let transform = selectedTransformInspector?.transform else {
            return false
        }
        let flip = ClipFlip(
            horizontal: horizontal ?? transform.flip.horizontal,
            vertical: vertical ?? transform.flip.vertical
        )
        return updateSelectedClipTransform(TransformEditor.copying(transform, flip: flip))
    }

    @discardableResult
    func applyCanvasTransformGesture(_ gesture: CanvasTransformGesture) -> Bool {
        guard let layout = selectedCanvasTransformLayout else {
            return false
        }

        let transform = CanvasTransformGestureMapper.updatedTransform(
            from: layout.transform,
            gesture: gesture,
            clipSize: layout.clipSize
        )
        return updateSelectedClipTransform(transform)
    }

    func selectedTransformHasKeyframe(_ parameter: ClipTransformParameter) -> Bool {
        guard let sequence = activeSequence,
              let time = playheadTime(in: sequence),
              let selectedClip
        else {
            return false
        }

        return TransformKeyframeLookup.keyframe(
            parameter: parameter,
            at: time,
            in: selectedClip.transformAnimation
        ) != nil
    }

    @discardableResult
    func toggleSelectedTransformKeyframe(_ parameter: ClipTransformParameter) -> Bool {
        guard let sequence = activeSequence,
              let time = playheadTime(in: sequence)
        else {
            return false
        }

        if selectedTransformHasKeyframe(parameter) {
            return deleteSelectedTransformKeyframe(parameter: parameter, at: time)
        }
        return addSelectedTransformKeyframe(parameter: parameter, at: time)
    }

    @discardableResult
    func addSelectedTransformKeyframe(
        parameter: ClipTransformParameter,
        atFrame frame: Int64
    ) -> Bool {
        guard let sequence = activeSequence,
              let time = try? RationalTime.atFrame(frame, frameRate: sequence.timebase)
        else {
            return false
        }
        return addSelectedTransformKeyframe(parameter: parameter, at: time)
    }

    @discardableResult
    func moveSelectedTransformKeyframe(
        parameter: ClipTransformParameter,
        fromFrame: Int64,
        toFrame: Int64
    ) -> Bool {
        guard let sequence = activeSequence,
              let fromTime = try? RationalTime.atFrame(fromFrame, frameRate: sequence.timebase),
              let toTime = try? RationalTime.atFrame(
                max(0, min(toFrame, max(0, durationFrames - 1))),
                frameRate: sequence.timebase
              )
        else {
            return false
        }

        return moveSelectedTransformKeyframe(parameter: parameter, from: fromTime, to: toTime)
    }

    @discardableResult
    func deleteSelectedTransformKeyframe(
        parameter: ClipTransformParameter,
        atFrame frame: Int64
    ) -> Bool {
        guard let sequence = activeSequence,
              let time = try? RationalTime.atFrame(frame, frameRate: sequence.timebase)
        else {
            return false
        }

        return deleteSelectedTransformKeyframe(parameter: parameter, at: time)
    }

    func isMarkerSelected(_ markerID: UUID) -> Bool {
        timelineState.selectedMarkerID == markerID
    }

    func selectMarker(_ markerID: UUID) {
        guard activeSequence?.markers.contains(where: { $0.id == markerID }) == true else {
            return
        }

        timelineState.selectedMarkerID = markerID
        timelineState.selectedClips = []
        timelineState.selectionAnchor = nil
        persistActiveSequenceContext()
    }

    func addTimelineMarkerAtPlayhead() {
        guard let sequence = activeSequence,
              let markerTime = try? RationalTime.atFrame(playheadFrame, frameRate: sequence.timebase)
        else {
            return
        }

        let marker = Marker(
            id: UUID(),
            time: markerTime,
            name: "Marker \(sequence.markers.count + 1)",
            color: .blue,
            note: "",
            anchor: .timeline
        )

        if applyEdit(.addMarker(sequenceID: sequence.id, marker: marker)) {
            selectMarker(marker.id)
        }
    }

    func deleteSelectedMarker() {
        // ⌘⌫ deletes to line start in a text field; never delete the marker being renamed.
        guard !isTextEditingActive,
              let sequenceID = activeSequence?.id,
              let markerID = timelineState.selectedMarkerID
        else {
            return
        }

        if applyEdit(.removeMarker(sequenceID: sequenceID, markerID: markerID)) {
            timelineState.selectedMarkerID = nil
            persistActiveSequenceContext()
        }
    }

    func updateSelectedMarker(
        name: String? = nil,
        color: MarkerColor? = nil,
        note: String? = nil
    ) {
        guard let sequence = activeSequence,
              let selectedMarker
        else {
            return
        }

        let marker = Marker(
            id: selectedMarker.id,
            time: selectedMarker.time,
            name: name ?? selectedMarker.name,
            color: color ?? selectedMarker.color,
            note: note ?? selectedMarker.note,
            anchor: selectedMarker.anchor
        )

        if applyEdit(.updateMarker(sequenceID: sequence.id, marker: marker)) {
            timelineState.selectedMarkerID = marker.id
            persistActiveSequenceContext()
        }
    }

    @discardableResult
    func detachAudioForSelectedClip() -> Bool {
        guard let sequenceID = activeSequence?.id,
              let linkGroupID = selectedClip?.linkGroupID
        else {
            return false
        }

        return applyEdit(.unlinkClips(sequenceID: sequenceID, linkGroupID: linkGroupID))
    }

    @discardableResult
    func moveSelectedClip(
        toStartFrame startFrame: Int64,
        destinationTrackID: UUID? = nil,
        linkedClipEditMode: LinkedClipEditMode = .linked
    ) -> Bool {
        guard let sequence = activeSequence,
              let selectedClipReference,
              let selectedClip,
              let start = try? RationalTime.atFrame(startFrame, frameRate: sequence.timebase),
              let timelineRange = try? TimeRange(
                start: start,
                duration: selectedClip.timelineRange.duration
              )
        else {
            return false
        }

        return applyEdit(
            .moveClip(
                sequenceID: sequence.id,
                sourceTrackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                destinationTrackID: destinationTrackID ?? selectedClipReference.trackID,
                timelineRange: timelineRange,
                linkedClipEditMode: linkedClipEditMode
            )
        )
    }

    /// Moves the entire timeline selection horizontally by `deltaFrames` in one undo step (#240).
    ///
    /// Extends single-clip move to multi-selection (FR-TL-007): every selected clip shifts by the
    /// same delta, and when `linkedClipEditMode` is `.linked` each selected clip's unselected A/V
    /// partners follow. The full set is deduplicated so a selected linked pair is never moved
    /// twice, and the moves apply as one atomic transaction — the reducer's central validation
    /// refuses the whole gesture with a typed error if the result would overlap clips, leaving the
    /// project unchanged. Vertical track changes remain a single-clip affordance.
    @discardableResult
    func moveSelectedClips(
        byFrames deltaFrames: Int64,
        linkedClipEditMode: LinkedClipEditMode = .linked
    ) -> Bool {
        guard deltaFrames != 0, let sequence = activeSequence else { return false }
        let selected = timelineState.selectedClips
        guard !selected.isEmpty else { return false }

        var references: [TimelineClipReference] = []
        var seen: Set<TimelineClipReference> = []
        func include(_ reference: TimelineClipReference) {
            if seen.insert(reference).inserted {
                references.append(reference)
            }
        }
        for reference in selected.sorted(by: { $0.clipID.uuidString < $1.clipID.uuidString }) {
            include(reference)
            if linkedClipEditMode == .linked {
                for partner in linkedPartnerReferences(of: reference) {
                    include(partner)
                }
            }
        }

        var commands: [EditCommand] = []
        for reference in references {
            guard let clip = Self.clip(reference, in: sequence),
                  let startFrame = try? clip.timelineRange.start.frameIndex(
                    at: sequence.timebase,
                    rounding: .nearestOrAwayFromZero
                  ),
                  let start = try? RationalTime.atFrame(
                    max(0, startFrame + deltaFrames),
                    frameRate: sequence.timebase
                  ),
                  let timelineRange = try? TimeRange(
                    start: start,
                    duration: clip.timelineRange.duration
                  )
            else {
                return false
            }
            commands.append(.moveClip(
                sequenceID: sequence.id,
                sourceTrackID: reference.trackID,
                clipID: reference.clipID,
                destinationTrackID: reference.trackID,
                timelineRange: timelineRange,
                linkedClipEditMode: .unlinked
            ))
        }
        return applyEditGroup(commands)
    }

    func previewTimelineGesture(frame: Int64, snapped: Bool) {
        timelineGestureFeedback = AppString.localized(
            "timeline.gesture.feedback", "Frame \(frame)"
        )
        timelineSnapIndicatorFrame = snapped ? frame : nil
    }

    func compatibleTrackID(for reference: TimelineClipReference, verticalLaneOffset: Int) -> UUID? {
        guard let sequence = activeSequence,
              let source = (sequence.videoTracks + sequence.audioTracks).first(where: { $0.id == reference.trackID })
        else { return nil }
        let tracks = source.kind == .video ? sequence.videoTracks : sequence.audioTracks
        guard let index = tracks.firstIndex(where: { $0.id == source.id }) else { return nil }
        let destination = min(max(0, index + verticalLaneOffset), tracks.count - 1)
        return tracks[destination].locked ? nil : tracks[destination].id
    }

    @discardableResult
    func rippleTrimSelectedClip(edge: TimelineTrimEdge, toFrame frame: Int64,
                                linkedClipEditMode: LinkedClipEditMode = .linked) -> Bool {
        guard let sequence = activeSequence, let reference = selectedClipReference,
              let clip = selectedClip else { return false }
        let startFrame = (try? clip.timelineRange.start.frameIndex(at: sequence.timebase, rounding: .nearestOrAwayFromZero)) ?? 0
        let endFrame = (try? clip.timelineRange.end().frameIndex(at: sequence.timebase, rounding: .nearestOrAwayFromZero)) ?? startFrame + 1
        let sourceStartFrame = (try? clip.sourceRange.start.frameIndex(at: sequence.timebase, rounding: .nearestOrAwayFromZero)) ?? 0
        let newStart = edge == .leading ? min(frame, endFrame - 1) : startFrame
        let newEnd = edge == .trailing ? max(frame, startFrame + 1) : endFrame
        let sourceStart = edge == .leading ? sourceStartFrame + (newStart - startFrame) : sourceStartFrame
        guard let sourceTime = try? RationalTime.atFrame(sourceStart, frameRate: sequence.timebase),
              let timelineTime = try? RationalTime.atFrame(newStart, frameRate: sequence.timebase),
              let duration = try? sequence.timebase.duration(ofFrames: newEnd - newStart),
              let sourceRange = try? TimeRange(start: sourceTime, duration: duration),
              let timelineRange = try? TimeRange(start: timelineTime, duration: duration)
        else { return false }
        return applyEdit(.rippleTrimClip(sequenceID: sequence.id, trackID: reference.trackID,
                                         clipID: reference.clipID, sourceRange: sourceRange,
                                         timelineRange: timelineRange,
                                         linkedClipEditMode: linkedClipEditMode))
    }

    @discardableResult
    func rollSelectedClip(edge: TimelineTrimEdge, toFrame frame: Int64) -> Bool {
        guard let sequence = activeSequence, let reference = selectedClipReference,
              let track = (sequence.videoTracks + sequence.audioTracks).first(where: { $0.id == reference.trackID })
        else { return false }
        let clips = track.items.compactMap { item -> Clip? in guard case .clip(let clip) = item else { return nil }; return clip }
        guard let index = clips.firstIndex(where: { $0.id == reference.clipID }) else { return false }
        let leftIndex = edge == .leading ? index - 1 : index
        let rightIndex = leftIndex + 1
        guard clips.indices.contains(leftIndex), clips.indices.contains(rightIndex),
              let time = try? RationalTime.atFrame(frame, frameRate: sequence.timebase)
        else { return false }
        return applyEdit(.rollEdit(sequenceID: sequence.id, trackID: track.id,
                                   leftClipID: clips[leftIndex].id,
                                   rightClipID: clips[rightIndex].id, editTime: time))
    }

    @discardableResult
    func trimSelectedClipToPlayhead(edge: TimelineTrimEdge) -> Bool {
        guard !isTextEditingActive else { return false }
        return rippleTrimSelectedClip(edge: edge, toFrame: playheadFrame)
    }

    @discardableResult
    func slipSelectedClip(byFrames delta: Int64) -> Bool {
        guard !isTextEditingActive else { return false }
        guard let sequence = activeSequence, let reference = selectedClipReference,
              let clip = selectedClip,
              let sourceFrame = try? clip.sourceRange.start.frameIndex(at: sequence.timebase, rounding: .nearestOrAwayFromZero),
              let sourceStart = try? RationalTime.atFrame(max(0, sourceFrame + delta), frameRate: sequence.timebase),
              let range = try? TimeRange(start: sourceStart, duration: clip.sourceRange.duration)
        else { return false }
        return applyEdit(.slipClip(sequenceID: sequence.id, trackID: reference.trackID,
                                   clipID: reference.clipID, sourceRange: range))
    }

    @discardableResult
    func slideSelectedClip(byFrames delta: Int64) -> Bool {
        guard !isTextEditingActive else { return false }
        guard let sequence = activeSequence, let reference = selectedClipReference,
              let clip = selectedClip,
              let startFrame = try? clip.timelineRange.start.frameIndex(at: sequence.timebase, rounding: .nearestOrAwayFromZero),
              let start = try? RationalTime.atFrame(max(0, startFrame + delta), frameRate: sequence.timebase),
              let range = try? TimeRange(start: start, duration: clip.timelineRange.duration)
        else { return false }
        return applyEdit(.slideClip(sequenceID: sequence.id, trackID: reference.trackID,
                                    clipID: reference.clipID, timelineRange: range))
    }

    func snappedTimelineFrame(_ proposedFrame: Int64, momentarilyDisabled: Bool) -> Int64 {
        guard timelineState.snappingEnabled, !momentarilyDisabled, let sequence = activeSequence
        else { return max(0, proposedFrame) }
        return TimelineInteraction.snappedFrame(
            proposedFrame: max(0, proposedFrame),
            targets: TimelineInteraction.snapTargets(in: sequence, playheadFrame: playheadFrame),
            toleranceFrames: timelineState.snapToleranceFrames
        )
    }

    @discardableResult
    func bladeSelectedClipAtPlayhead() -> Bool {
        guard !isTextEditingActive, let reference = selectedClipReference else { return false }
        return bladeClip(reference: reference, atFrame: playheadFrame)
    }

    /// Blades a clip at the timeline x-coordinate under the pointer (FR-TL-004, #240).
    ///
    /// The blade tool splits at the exact click position, not the playhead: the local x is mapped
    /// to a timeline frame through the current zoom before the split.
    @discardableResult
    func bladeClip(reference: TimelineClipReference, atTimelineX x: Double) -> Bool {
        let pixelsPerFrame = max(1, timelineState.pixelsPerFrame)
        let frame = Int64((max(0, x) / pixelsPerFrame).rounded())
        return bladeClip(reference: reference, atFrame: frame)
    }

    @discardableResult
    func bladeClip(reference: TimelineClipReference, atFrame frame: Int64) -> Bool {
        guard let sequence = activeSequence,
              let time = try? RationalTime.atFrame(frame, frameRate: sequence.timebase)
        else { return false }
        // A linked A/V clip blades together with its partners in one undo step (#240): the same
        // timeline cut is applied to every partner that spans it, atomically.
        var commands: [EditCommand] = [
            .bladeClip(
                sequenceID: sequence.id,
                trackID: reference.trackID,
                clipID: reference.clipID,
                atTime: time,
                rightClipID: UUID()
            )
        ]
        for partner in linkedPartnerReferences(of: reference) {
            guard let clip = Self.clip(partner, in: sequence),
                  let end = try? clip.timelineRange.end(),
                  clip.timelineRange.start < time, time < end
            else {
                continue
            }
            commands.append(.bladeClip(
                sequenceID: sequence.id,
                trackID: partner.trackID,
                clipID: partner.clipID,
                atTime: time,
                rightClipID: UUID()
            ))
        }
        return applyEditGroup(commands)
    }

    @discardableResult
    func rippleDeleteSelection() -> Bool {
        applyDestructiveSelectionEdit(ripple: true)
    }

    @discardableResult
    func liftSelection() -> Bool {
        applyDestructiveSelectionEdit(ripple: false)
    }

    private func applyDestructiveSelectionEdit(ripple: Bool) -> Bool {
        guard timelineHasFocus, !isTextEditingActive, let sequence = activeSequence else { return false }
        let references = timelineState.selectedClips.sorted { $0.clipID.uuidString < $1.clipID.uuidString }
        guard !references.isEmpty else { return false }
        // One undo step per gesture (#240): a multi-clip delete/lift is one atomic transaction.
        let commands = references.map { reference -> EditCommand in
            ripple
                ? .rippleDeleteClip(sequenceID: sequence.id, trackID: reference.trackID, clipID: reference.clipID)
                : .liftClip(sequenceID: sequence.id, trackID: reference.trackID, clipID: reference.clipID)
        }
        let changed = applyEditGroup(commands)
        if changed {
            timelineState.selectedClips = []
            timelineState.selectionAnchor = nil
        }
        return changed
    }

    @discardableResult
    func copyTimelineClips() -> Bool {
        guard timelineHasFocus, !isTextEditingActive, let sequence = activeSequence else { return false }
        let copied = timelineState.selectedClips.compactMap { reference -> TimelineClipboardItem? in
            guard let track = (sequence.videoTracks + sequence.audioTracks).first(where: { $0.id == reference.trackID }),
                  let clip = track.items.compactMap({ item -> Clip? in
                      guard case .clip(let clip) = item else { return nil }
                      return clip.id == reference.clipID ? clip : nil
                  }).first
            else { return nil }
            return TimelineClipboardItem(sourceTrackID: track.id, clip: clip)
        }
        guard !copied.isEmpty else { return false }
        timelineClipboard = copied
        return true
    }

    @discardableResult
    func cutTimelineClips() -> Bool {
        guard copyTimelineClips() else { return false }
        return liftSelection()
    }

    @discardableResult
    func pasteTimelineClips() -> Bool {
        guard timelineHasFocus, !isTextEditingActive,
              let sequence = activeSequence, !timelineClipboard.isEmpty,
              let earliest = timelineClipboard.map(\.clip.timelineRange.start).min()
        else { return false }
        guard let target = try? RationalTime.atFrame(playheadFrame, frameRate: sequence.timebase)
        else { return false }
        // Pasted copies never keep source link groups (#240 review, finding 5): a pasted A/V
        // pair gets one fresh shared group so it stays linked to itself, not to the originals;
        // a lone pasted member of a group is unlinked.
        var pastedGroupMemberCounts: [UUID: Int] = [:]
        for item in timelineClipboard {
            if let group = item.clip.linkGroupID {
                pastedGroupMemberCounts[group, default: 0] += 1
            }
        }
        var remappedLinkGroups: [UUID: UUID] = [:]
        for (group, memberCount) in pastedGroupMemberCounts where memberCount >= 2 {
            remappedLinkGroups[group] = UUID()
        }
        // One undo step per gesture (#240): pasting every clipboard item is one atomic transaction.
        var commands: [EditCommand] = []
        for item in timelineClipboard {
            let tracks = item.clip.kind == .video ? sequence.videoTracks : sequence.audioTracks
            guard let track = tracks.first(where: { $0.id == item.sourceTrackID && !$0.locked })
                    ?? tracks.first(where: { !$0.locked }),
                  let offset = try? item.clip.timelineRange.start.subtracting(earliest),
                  let start = try? target.adding(offset),
                  let range = try? TimeRange(start: start, duration: item.clip.timelineRange.duration)
            else { continue }
            let clip = item.clip.copyingForTimeline(
                id: UUID(),
                timelineRange: range,
                linkGroupID: item.clip.linkGroupID.flatMap { remappedLinkGroups[$0] }
            )
            commands.append(.insertClip(sequenceID: sequence.id, trackID: track.id, clip: clip))
        }
        return applyEditGroup(commands)
    }

    func selectForwardFromPlayhead() {
        guard !isTextEditingActive, let sequence = activeSequence else { return }
        let selected = (sequence.videoTracks + sequence.audioTracks).flatMap { track in
            TimelineInteraction.clipLayouts(for: track, frameRate: sequence.timebase, pixelsPerFrame: 1)
                .filter { $0.startFrame >= playheadFrame }
                .map(\.reference)
        }
        timelineState.selectedClips = Set(selected)
        timelineState.selectionAnchor = selected.first
        timelineHasFocus = true
        persistActiveSequenceContext()
    }

    @discardableResult
    func addTrack(kind: TrackKind) -> Bool {
        guard let sequence = activeSequence else { return false }
        return applyEdit(.addTrack(sequenceID: sequence.id, track: Track(id: UUID(), kind: kind, items: [])))
    }

    @discardableResult
    func removeSelectedEmptyTrack() -> Bool {
        guard let sequence = activeSequence, let trackID = selectedTimelineTrackID,
              let track = (sequence.videoTracks + sequence.audioTracks).first(where: { $0.id == trackID }),
              track.items.isEmpty
        else { return false }
        let removed = applyEdit(.removeTrack(sequenceID: sequence.id, trackID: trackID))
        if removed { selectedTimelineTrackID = nil }
        return removed
    }

    @discardableResult
    func editSelectedMedia(_ mode: TimelineMediaEditMode) -> Bool {
        guard !isTextEditingActive, let mediaID = selectedMediaIDs.first else { return false }
        switch mode {
        case .insert: return insertMediaOnTimeline(mediaID: mediaID)
        case .overwrite: return placeMediaOnTimeline(mediaID: mediaID, overwrite: true, append: false)
        case .append: return placeMediaOnTimeline(mediaID: mediaID, overwrite: false, append: true)
        case .replace:
            guard let sequence = activeSequence, let reference = selectedClipReference,
                  let media = project?.mediaPool.first(where: { $0.id == mediaID }),
                  let sourceRange = try? TimeRange(start: .zero, duration: media.metadata.duration)
            else { return false }
            return applyEdit(.replaceClipSource(sequenceID: sequence.id, trackID: reference.trackID, clipID: reference.clipID, source: .media(id: mediaID), sourceRange: sourceRange))
        }
    }

    /// Whether a three-point edit can run now: both timeline marks and a browser selection exist.
    var canPerformThreePointEdit: Bool {
        guard isProjectEditable,
              !isTextEditingActive,
              let inFrame = timelineState.selectionInFrame,
              let outFrame = timelineState.selectionOutFrame,
              outFrame > inFrame,
              let mediaID = selectedMediaIDs.first,
              let media = project?.mediaPool.first(where: { $0.id == mediaID })
        else {
            return false
        }
        return !media.isOffline
    }

    /// Fits the browser selection into the marked timeline range as a three-point edit (FR-TL-003).
    ///
    /// With in/out marks set and a media-browser selection, the marked span supplies the timeline
    /// start and the duration; the source is taken from the selection's start. `mode` chooses an
    /// insert (ripple later items) or overwrite fit. Refuses (returns `false`) when marks or a
    /// selection are missing, the marks are empty/inverted, or the marked span exceeds the media's
    /// available source.
    @discardableResult
    func performThreePointEdit(mode: ThreePointEditMode) -> Bool {
        guard !isTextEditingActive,
              let sequence = activeSequence,
              let inFrame = timelineState.selectionInFrame,
              let outFrame = timelineState.selectionOutFrame,
              outFrame > inFrame,
              let mediaID = selectedMediaIDs.first,
              let media = project?.mediaPool.first(where: { $0.id == mediaID }),
              !media.isOffline
        else {
            return false
        }
        let kind: TrackKind = media.metadata.pixelDimensions == nil ? .audio : .video
        let tracks = kind == .video ? sequence.videoTracks : sequence.audioTracks
        guard let track = tracks.first(where: { !$0.locked }),
              let timelineStart = try? RationalTime.atFrame(inFrame, frameRate: sequence.timebase),
              let duration = try? sequence.timebase.duration(ofFrames: outFrame - inFrame),
              duration <= media.metadata.duration,
              let sourceRange = try? TimeRange(start: .zero, duration: duration)
        else {
            return false
        }
        let name = media.sourceURL?.deletingPathExtension().lastPathComponent
            ?? AppString.localized("timeline.media.untitled", "Media")
        return applyEdit(.threePointEdit(
            sequenceID: sequence.id,
            trackID: track.id,
            clipID: UUID(),
            source: .media(id: mediaID),
            sourceRange: sourceRange,
            timelineStart: timelineStart,
            kind: kind,
            name: name,
            mode: mode
        ))
    }

    @discardableResult
    func trimSelectedClip(
        sourceStartFrame: Int64,
        timelineStartFrame: Int64,
        durationFrames: Int64,
        linkedClipEditMode: LinkedClipEditMode = .linked
    ) -> Bool {
        guard durationFrames > 0,
              let sequence = activeSequence,
              let selectedClipReference,
              let sourceStart = try? RationalTime.atFrame(
                sourceStartFrame,
                frameRate: sequence.timebase
              ),
              let timelineStart = try? RationalTime.atFrame(
                timelineStartFrame,
                frameRate: sequence.timebase
              ),
              let duration = try? sequence.timebase.duration(ofFrames: durationFrames),
              let sourceRange = try? TimeRange(start: sourceStart, duration: duration),
              let timelineRange = try? TimeRange(start: timelineStart, duration: duration)
        else {
            return false
        }

        return applyEdit(
            .trimClip(
                sequenceID: sequence.id,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                sourceRange: sourceRange,
                timelineRange: timelineRange,
                linkedClipEditMode: linkedClipEditMode
            )
        )
    }

    func jumpToNextMarker() {
        guard let sequence = activeSequence,
              let currentTime = try? RationalTime.atFrame(playheadFrame, frameRate: sequence.timebase),
              let marker = MarkerNavigation.nextMarker(in: sequence, after: currentTime)
        else {
            return
        }

        jump(to: marker, in: sequence)
    }

    func jumpToPreviousMarker() {
        guard let sequence = activeSequence,
              let currentTime = try? RationalTime.atFrame(playheadFrame, frameRate: sequence.timebase),
              let marker = MarkerNavigation.previousMarker(in: sequence, before: currentTime)
        else {
            return
        }

        jump(to: marker, in: sequence)
    }

    func setTimelineRangeIn() {
        guard !isTextEditingActive else { return }
        timelineState.selectionInFrame = playheadFrame
        refreshLoopRange()
        persistActiveSequenceContext()
    }

    func setTimelineRangeOut() {
        guard !isTextEditingActive else { return }
        timelineState.selectionOutFrame = playheadFrame
        refreshLoopRange()
        persistActiveSequenceContext()
    }

    func clearTimelineRange() {
        timelineState.selectionInFrame = nil
        timelineState.selectionOutFrame = nil
        isLoopRangeEnabled = false
        playbackController?.setLoopRange(nil)
        persistActiveSequenceContext()
    }

    private func refreshLoopRange() {
        guard isLoopRangeEnabled,
              let lower = timelineState.selectionInFrame,
              let upper = timelineState.selectionOutFrame else { return }
        playbackController?.setLoopRange(min(lower, upper)...max(lower, upper))
    }

    func setTimelineSnappingEnabled(_ isEnabled: Bool) {
        timelineState.snappingEnabled = isEnabled
        persistActiveSequenceContext()
    }

    func zoomTimelineIn() {
        timelineState.pixelsPerFrame = TimelineInteraction.zoomedPixelsPerFrame(
            timelineState.pixelsPerFrame,
            factor: 1.25
        )
        persistActiveSequenceContext()
    }

    func zoomTimelineOut() {
        timelineState.pixelsPerFrame = TimelineInteraction.zoomedPixelsPerFrame(
            timelineState.pixelsPerFrame,
            factor: 0.8
        )
        persistActiveSequenceContext()
    }

    func zoomTimelineVerticallyIn() {
        timelineState.laneHeight = TimelineInteraction.zoomedLaneHeight(
            timelineState.laneHeight,
            factor: 1.18
        )
        persistActiveSequenceContext()
    }

    func zoomTimelineVerticallyOut() {
        timelineState.laneHeight = TimelineInteraction.zoomedLaneHeight(
            timelineState.laneHeight,
            factor: 0.85
        )
        persistActiveSequenceContext()
    }

    func fitTimeline(toWidth availableWidth: Double) {
        timelineState.pixelsPerFrame = TimelineInteraction.fittedPixelsPerFrame(
            durationFrames: durationFrames,
            availableWidth: availableWidth
        )
        persistActiveSequenceContext()
    }

    func zoomTimelineToSelection(toWidth availableWidth: Double) {
        guard let sequence = activeSequence,
              let frameRange = TimelineInteraction.selectedFrameRange(
                in: sequence,
                selectedClips: timelineState.selectedClips
              )
        else {
            return
        }
        timelineState.pixelsPerFrame = TimelineInteraction.fittedPixelsPerFrame(
            durationFrames: frameRange.durationFrames,
            availableWidth: availableWidth
        )
        persistActiveSequenceContext()
    }

    func setTrackState(
        sequenceID: UUID,
        trackID: UUID,
        enabled: Bool? = nil,
        locked: Bool? = nil,
        muted: Bool? = nil,
        solo: Bool? = nil,
        hidden: Bool? = nil
    ) {
        applyEdit(
            .setTrackState(
                sequenceID: sequenceID,
                trackID: trackID,
                state: TrackStatePatch(
                    enabled: enabled,
                    locked: locked,
                    muted: muted,
                    solo: solo,
                    hidden: hidden
                )
            )
        )
    }

    @discardableResult
    private func updateSelectedClipTransform(_ transform: ClipTransform) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference
        else {
            return false
        }

        return applyEdit(
            .setClipTransform(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                transform: transform
            )
        )
    }

    @discardableResult
    private func addSelectedTransformKeyframe(
        parameter: ClipTransformParameter,
        at time: RationalTime
    ) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              let selectedClip
        else {
            return false
        }

        let transform = selectedClip.transformAnimation.value(at: time)
        let keyframe = ClipTransformKeyframe(
            time: time,
            value: TransformKeyframeLookup.value(parameter: parameter, in: transform),
            interpolation: .linear
        )

        return applyEdit(
            .addClipTransformKeyframe(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                parameter: parameter,
                keyframe: keyframe
            )
        )
    }

    @discardableResult
    private func moveSelectedTransformKeyframe(
        parameter: ClipTransformParameter,
        from fromTime: RationalTime,
        to toTime: RationalTime
    ) -> Bool {
        guard fromTime != toTime,
              let sequenceID = activeSequence?.id,
              let selectedClipReference,
              let selectedClip,
              let existingKeyframe = TransformKeyframeLookup.keyframe(
                parameter: parameter,
                at: fromTime,
                in: selectedClip.transformAnimation
              )
        else {
            return false
        }

        let movedKeyframe = ClipTransformKeyframe(
            time: toTime,
            value: existingKeyframe.value,
            interpolation: existingKeyframe.interpolation
        )
        return applyEdit(
            .moveClipTransformKeyframe(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                parameter: parameter,
                fromTime: fromTime,
                keyframe: movedKeyframe
            )
        )
    }

    @discardableResult
    private func deleteSelectedTransformKeyframe(
        parameter: ClipTransformParameter,
        at time: RationalTime
    ) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference
        else {
            return false
        }

        return applyEdit(
            .deleteClipTransformKeyframe(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                parameter: parameter,
                time: time
            )
        )
    }

    func undo() {
        endCanvasTitleTextEditing()
        guard var history = editHistory, let project = history.undo() else {
            return
        }

        editHistory = history
        updateProject(project)
        scheduleAutosaveCheckpoint(project: project)
    }

    func redo() {
        endCanvasTitleTextEditing()
        guard var history = editHistory else {
            return
        }

        do {
            guard let project = try history.redo() else {
                return
            }
            editHistory = history
            updateProject(project)
            scheduleAutosaveCheckpoint(project: project)
        } catch {
            loadMessage = "Redo failed: \(error)"
        }
    }

    private func refuseReplacementWhenDirty() throws {
        if isDocumentDirty, !mayDiscardChangesForNextReplacement {
            throw EditorAjarDocumentLifecycleError.unsavedChanges
        }
        mayDiscardChangesForNextReplacement = false
    }

    private func requireEditableSaveMode() throws {
        if case .readOnly(let reason) = projectOpenMode {
            throw EditorAjarDocumentLifecycleError.projectOpenedReadOnly(reason)
        }
    }

    /// Turns typed lifecycle failures into localized, ordinary-language details.
    ///
    /// Raw enum descriptions can contain implementation case names and full filesystem paths.
    /// Those are useful to developers but inappropriate in a document alert.
    private func localizedDocumentErrorDetail(_ error: Error) -> String {
        if let lifecycleError = error as? EditorAjarDocumentLifecycleError {
            switch lifecycleError {
            case .unsavedChanges:
                return AppString.localized(
                    "document.error.detail.unsavedChanges",
                    "The current project has unsaved changes."
                )
            case .noProject:
                return AppString.localized(
                    "document.error.detail.noProject",
                    "No project is open."
                )
            case .documentHasNoURL:
                return AppString.localized(
                    "document.error.detail.noURL",
                    "Choose a name and location for the project first."
                )
            case .projectOpenedReadOnly(let reason):
                switch reason {
                case .newerSchemaMinor(let found, let supported):
                    return AppString.localized(
                        "document.error.detail.readOnlyNewerMinor",
                        "Format \(found) is newer than supported format \(supported). Saving is unavailable."
                    )
                }
            }
        }

        if let storeError = error as? EditorAjarDocumentStoreError {
            switch storeError {
            case .invalidPackageExtension:
                return AppString.localized(
                    "document.error.detail.invalidExtension",
                    "Choose an Editor Ajar project ending in .ajar."
                )
            case .packageNotFound:
                return AppString.localized(
                    "document.error.detail.notFound",
                    "The selected project could not be found."
                )
            case .packageIsNotDirectory:
                return AppString.localized(
                    "document.error.detail.notPackage",
                    "The selected .ajar item is not a project package."
                )
            case .codec:
                return AppString.localized(
                    "document.error.detail.codec",
                    "The project data is damaged or uses an unsupported format."
                )
            case .persistence:
                return AppString.localized(
                    "document.error.detail.persistence",
                    "The project package could not be read or written safely."
                )
            case .fileOperation(let path, _):
                return AppString.localized(
                    "document.error.detail.fileOperation",
                    "A file operation failed for \(URL(fileURLWithPath: path).lastPathComponent)."
                )
            }
        }

        return AppString.localized(
            "document.error.detail.unknown",
            "An unexpected error occurred."
        )
    }

    private func didSave(project: Project, at url: URL) {
        documentURL = url.standardizedFileURL
        projectPackageRootURL = documentURL
        savedProjectBaseline = project
        unsavedDocumentName = nil
        refreshDirtyState()
        bindRenderPackageRoot()
        recentProjectURLs = recentProjectsStore.record(url)
        loadMessage = AppString.localized(
            "status.projectSaved",
            "Saved \(url.deletingPathExtension().lastPathComponent)"
        )
        resetAutosaveForInstalledProject()
    }

    /// Single installation boundary for recovery, New, Open, Revert, and the Help sample.
    private func installProjectSession(
        _ loadResult: AjarProjectLoadResult,
        documentURL: URL?,
        savedBaseline: Project?,
        unsavedName: String?
    ) {
        displayLinkDriver?.stop()
        audioCoordinator?.stop()
        mediaResolutionTask?.cancel()
        cancelAllMediaPreviews()
        mediaThumbnailData = [:]
        mediaWaveformSummary = [:]
        mediaPreviewCache = nil
        renderGeneration += 1
        isPlaying = false
        project = loadResult.project
        projectOpenMode = loadResult.openMode
        editHistory = EditHistory(loadResult: loadResult)
        self.documentURL = documentURL
        if documentURL == nil {
            documentSecurityScope = nil
        }
        savedProjectBaseline = savedBaseline
        unsavedDocumentName = unsavedName
        projectPackageRootURL = documentURL
        autosaveCommandCount = 0
        sequenceContexts = [:]
        timelineState = TimelineInteractionState()
        activeSequenceID = nil
        selectedCanvasTitleBoxReference = nil
        editingCanvasTitleBoxReference = nil
        copiedGradeSource = nil
        canvasTitleEditingUndoBaseline = nil
        hasSurfacedReadOnlyEditRefusal = false
        isReadOnlyBannerVisible = !loadResult.openMode.allowsEditing

        if let sequence = loadResult.project.sequences.first {
            activeSequenceID = sequence.id
            durationFrames = Self.durationFrames(for: sequence)
            playheadFrame = 0
            playbackController = EditorAjarPlaybackController(
                frameRate: sequence.timebase,
                durationFrames: durationFrames
            )
            persistActiveSequenceContext()
        } else {
            durationFrames = 1
            playheadFrame = 0
            playbackController = nil
            presentedTexture = nil
        }

        refreshDirtyState()
        bindRenderPackageRoot()
        startAutosaveLoop()
        requestRenderForCurrentFrame()
        startMediaResolution(for: loadResult)
    }

    private func refreshDirtyState() {
        guard projectOpenMode.allowsEditing, let project else {
            isDocumentDirty = false
            return
        }
        if let savedProjectBaseline {
            isDocumentDirty = project != savedProjectBaseline
        } else {
            // New/recovered documents have user work but no explicit saved baseline yet.
            isDocumentDirty = true
        }
    }

    private func resetAutosaveForInstalledProject() {
        guard let autosaveCoordinator, let project else {
            return
        }
        let openMode = projectOpenMode
        let shouldPersistRecovery = isDocumentDirty && openMode.allowsEditing
        let previousWriteTask = autosaveWriteTask
        autosaveWriteTask = Task {
            [weak self, autosaveCoordinator, openMode, project, shouldPersistRecovery] in
            await previousWriteTask?.value
            let message = await autosaveCoordinator.resetSession(
                project: project,
                openMode: openMode,
                shouldPersistRecovery: shouldPersistRecovery
            )
            await MainActor.run {
                if let message {
                    self?.loadMessage = message
                }
            }
        }
    }

    static func makeSampleProject() -> Result<Project, Error> {
        do {
            return .success(try EditorAjarSampleProjectFactory.makeSampleProject())
        } catch {
            return .failure(error)
        }
    }

    static func defaultAutosavePackageURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return supportDirectory
            .appendingPathComponent("EditorAjar", isDirectory: true)
            .appendingPathComponent("Autosave.ajar", isDirectory: true)
    }

    private static func makeAudioCoordinator() -> (any EditorAjarAudioCoordinating)? {
        do {
            return try EditorAjarLiveAudioCoordinator()
        } catch {
            return nil
        }
    }

    func autosaveCheckpointForTesting() async {
        await autosaveWriteTask?.value
        await autosaveCurrentProjectAndWait()
    }

    /// Test seam: applies an edit command through the normal undoable boundary.
    @discardableResult
    func applyEditForTesting(_ command: EditCommand) -> Bool {
        applyEdit(command)
    }

    /// Test seam: replaces the open project while preserving edit history (availability flips).
    func replaceProjectPreservingHistoryForTesting(_ next: Project) {
        if var history = editHistory {
            project = history.replaceCurrentProjectPreservingHistory(next)
            editHistory = history
            refreshDirtyState()
        } else {
            project = next
            refreshDirtyState()
        }
    }

    /// Test seam: package root used by proxy/relink re-transcode paths.
    func setProjectPackageRootForTesting(_ url: URL?) {
        projectPackageRootURL = url
    }

    private func displayLinkTick(_ deltaSeconds: Double) {
        guard isPlaying, playbackController?.advance(by: deltaSeconds) == true else {
            return
        }

        syncPlayheadFromController()
        ensureAudioPlanForPlayback()
        requestRenderForCurrentFrame()
    }

    private func syncPlayheadFromController() {
        playheadFrame = playbackController?.playheadFrame ?? 0
        persistActiveSequenceContext()
    }

    private func startAudioPlayback() {
        guard let audioCoordinator,
              let project,
              let sequence = activeSequence
        else {
            return
        }

        do {
            try audioCoordinator.start(
                project: project,
                sequence: sequence,
                playheadFrame: playheadFrame,
                durationFrames: durationFrames
            )
        } catch {
            loadMessage = "Audio playback unavailable: \(error)"
        }
    }

    private func stopAudioPlayback() {
        audioCoordinator?.stop()
    }

    private func publishAudioPlanForCurrentFrame() {
        guard isPlaying,
              let audioCoordinator,
              let project,
              let sequence = activeSequence
        else {
            return
        }

        do {
            try audioCoordinator.publishSeek(
                project: project,
                sequence: sequence,
                playheadFrame: playheadFrame,
                durationFrames: durationFrames
            )
        } catch {
            loadMessage = "Audio seek unavailable: \(error)"
        }
    }

    private func ensureAudioPlanForPlayback() {
        guard isPlaying,
              let audioCoordinator,
              let project,
              let sequence = activeSequence
        else {
            return
        }

        do {
            try audioCoordinator.ensurePlaybackPlan(
                project: project,
                sequence: sequence,
                playheadFrame: playheadFrame,
                durationFrames: durationFrames
            )
        } catch {
            loadMessage = "Audio playback unavailable: \(error)"
        }
    }

    private func requestRenderForCurrentFrame() {
        guard let project,
              let sequence = activeSequence,
              let renderPipeline
        else {
            return
        }

        renderGeneration += 1
        let generation = renderGeneration
        let frame = playheadFrame
        let allowDiskWriteBehind = playbackRate == 0
        loadMessage = AppString.localized("status.renderingFrame", "Rendering frame \(frame)")

        Task { [
            weak self,
            project,
            sequence,
            renderPipeline,
            frame,
            generation,
            allowDiskWriteBehind
        ] in
            do {
                let renderedFrame = try await renderPipeline.renderFrame(
                    project: project,
                    sequence: sequence,
                    frame: frame,
                    allowDiskWriteBehind: allowDiskWriteBehind
                )
                await MainActor.run {
                    guard self?.renderGeneration == generation else {
                        return
                    }
                    self?.applyRuntimeOfflineState(
                        mediaIDs: renderedFrame.runtimeOfflineMediaIDs,
                        expectedProject: project
                    )
                    // FR-MED-004: missing/stale proxy falls back to original and re-enqueues.
                    if !renderedFrame.mediaIDsNeedingProxyGeneration.isEmpty {
                        self?.enqueueProxyGeneration(
                            for: renderedFrame.mediaIDsNeedingProxyGeneration
                        )
                    }
                    self?.presentedTexture = renderedFrame.texture
                    self?.loadMessage = AppString.localized(
                        "status.renderedFrame", "Rendered \(sequence.name), frame \(frame)"
                    )
                }
            } catch {
                await MainActor.run {
                    guard self?.renderGeneration == generation else {
                        return
                    }
                    self?.loadMessage = "Render failed at frame \(frame): \(error)"
                }
            }
        }
    }

    /// Still-export sample frame for a playhead on a half-open timeline `[0, durationFrames)`.
    ///
    /// When the playhead sits on the exclusive end (`playheadFrame == durationFrames`), clamps to
    /// the last valid frame so `StillFrameExportRequest` validation does not throw.
    static func clampedStillExportFrame(playheadFrame: Int64, durationFrames: Int64) -> Int64 {
        min(playheadFrame, max(0, durationFrames - 1))
    }

    private func applyRuntimeOfflineState(
        mediaIDs: Set<UUID>,
        expectedProject: Project
    ) {
        guard !mediaIDs.isEmpty, var history = editHistory else {
            return
        }
        let resolvedMedia = expectedProject.updatingMediaAvailability(
            .offline,
            for: mediaIDs
        ).mediaPool
        do {
            let mergedProject = try history.reconcileMediaReferences(
                expected: expectedProject.mediaPool,
                resolved: resolvedMedia
            )
            editHistory = history
            updateProject(mergedProject)
            if projectOpenMode.allowsEditing {
                scheduleAutosaveCheckpoint(project: mergedProject)
            }
        } catch {
            loadMessage = "Media offline-state update unavailable: \(error)"
        }
    }

    private static func durationFrames(for sequence: Sequence) -> Int64 {
        let frameRate = sequence.timebase
        var lastFrame: Int64 = 1
        for track in sequence.videoTracks + sequence.audioTracks {
            for item in track.items {
                guard let endTime = try? item.timelineRange.end(),
                      let endFrame = try? endTime.frameIndex(at: frameRate, rounding: .up)
                else {
                    continue
                }
                lastFrame = max(lastFrame, endFrame)
            }
        }
        return max(1, lastFrame)
    }

    private static func emptySequence(name: String, frameRate: FrameRate) -> Sequence {
        Sequence(
            id: UUID(),
            name: name,
            videoTracks: [Track(id: UUID(), kind: .video, items: [])],
            audioTracks: [Track(id: UUID(), kind: .audio, items: [])],
            markers: [],
            timebase: frameRate
        )
    }

    private static func nextSequenceName(in project: Project) -> String {
        let existingNames = Set(project.sequences.map(\.name))
        var index = project.sequences.count + 1
        while existingNames.contains("Sequence \(index)") {
            index += 1
        }
        return "Sequence \(index)"
    }

    private static func replacementSequenceID(
        afterRemoving sequenceID: UUID,
        from project: Project
    ) -> UUID? {
        guard let index = project.sequences.firstIndex(where: { $0.id == sequenceID }) else {
            return activeSequenceFallbackID(in: project)
        }
        let nextIndex = project.sequences.index(after: index)
        if nextIndex < project.sequences.endIndex {
            return project.sequences[nextIndex].id
        }
        if index > project.sequences.startIndex {
            let previousIndex = project.sequences.index(before: index)
            return project.sequences[previousIndex].id
        }
        return nil
    }

    private static func activeSequenceFallbackID(in project: Project) -> UUID? {
        project.sequences.first?.id
    }

    private static func clip(_ reference: TimelineClipReference, in sequence: Sequence) -> Clip? {
        for track in sequence.videoTracks + sequence.audioTracks {
            guard track.id == reference.trackID else {
                continue
            }
            for item in track.items {
                if case .clip(let clip) = item, clip.id == reference.clipID {
                    return clip
                }
            }
        }
        return nil
    }

    private static func clip(_ reference: ProjectClipReference, in project: Project) -> Clip? {
        guard let sequence = project.sequences.first(where: { $0.id == reference.sequenceID })
        else {
            return nil
        }
        return clip(
            TimelineClipReference(trackID: reference.trackID, clipID: reference.clipID),
            in: sequence
        )
    }

    private static func nextLookName(in project: Project) -> String {
        let names = Set(
            project.looks.map { look in
                look.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        )
        var suffix = 1
        while names.contains("look \(suffix)") {
            suffix += 1
        }
        return "Look \(suffix)"
    }

    private static func mediaDimensions(for clip: Clip, in project: Project) -> PixelDimensions? {
        guard case .media(let mediaID) = clip.source else {
            return nil
        }
        return project.mediaPool.first { $0.id == mediaID }?.metadata.pixelDimensions
    }

    private func playheadTime(in sequence: Sequence) -> RationalTime? {
        try? RationalTime.atFrame(playheadFrame, frameRate: sequence.timebase)
    }

    private func editMenuTitle(prefix: String, command: EditCommand?) -> String {
        guard let command else {
            return prefix
        }
        return "\(prefix) \(command.actionName)"
    }

    @discardableResult
    private func applyEdit(
        _ command: EditCommand,
        coalescingWithPrevious: Bool = false
    ) -> Bool {
        if case .readOnly(let reason) = projectOpenMode {
            surfaceReadOnlyEditRefusalOnce(reason: reason)
            return false
        }

        guard var history = editHistory else {
            return false
        }

        do {
            persistActiveSequenceContext()
            let project: Project
            if coalescingWithPrevious {
                project = try history.applyCoalescingWithPrevious(command)
            } else {
                project = try history.apply(command)
            }
            editHistory = history
            updateProject(project)
            scheduleAutosave(command: command, project: project)
            return true
        } catch let error as EditHistoryError {
            if case .projectOpenedReadOnly(let reason) = error {
                surfaceReadOnlyEditRefusalOnce(reason: reason)
                return false
            }
            loadMessage = "Edit failed: \(error)"
            return false
        } catch {
            loadMessage = "Edit failed: \(error)"
            return false
        }
    }

    /// Applies an ordered list of engine commands as a single undo step (#240).
    ///
    /// Zero commands is a no-op; one command applies directly so common single-clip gestures stay
    /// plain journal records; two or more are wrapped in one atomic `EditCommand.transaction` so a
    /// multi-command gesture (linked A/V blade, multi-clip delete/lift/paste, multi-selection move)
    /// undoes in one step and refuses atomically on any typed sub-command error.
    @discardableResult
    private func applyEditGroup(_ commands: [EditCommand]) -> Bool {
        switch commands.count {
        case 0:
            return false
        case 1:
            return applyEdit(commands[0])
        default:
            return applyEdit(.transaction(commands))
        }
    }

    /// Timeline references of a clip's linked A/V partners in the active sequence, excluding
    /// `reference` itself. Empty when the clip is unlinked or the sequence is unavailable.
    private func linkedPartnerReferences(
        of reference: TimelineClipReference
    ) -> [TimelineClipReference] {
        guard let sequence = activeSequence,
              let clip = Self.clip(reference, in: sequence),
              let linkGroupID = clip.linkGroupID
        else {
            return []
        }
        return (sequence.videoTracks + sequence.audioTracks).flatMap { track in
            track.items.compactMap { item -> TimelineClipReference? in
                guard case .clip(let candidate) = item,
                      candidate.linkGroupID == linkGroupID
                else {
                    return nil
                }
                let candidateReference = TimelineClipReference(
                    trackID: track.id,
                    clipID: candidate.id
                )
                return candidateReference == reference ? nil : candidateReference
            }
        }
    }

    /// Surfaces the read-only refusal message once so UI edit paths stay quiet after the first try.
    private func surfaceReadOnlyEditRefusalOnce(reason: AjarProjectReadOnlyReason) {
        presentReadOnlyBannerIfNeeded()
        guard !hasSurfacedReadOnlyEditRefusal else {
            return
        }
        hasSurfacedReadOnlyEditRefusal = true
        loadMessage = AppString.readOnlyProjectMessage(for: reason)
    }

    private func canvasTitleLayout(
        for reference: CanvasTitleBoxReference
    ) -> CanvasTitleBoxLayout? {
        visibleCanvasTitleBoxes.first { $0.reference == reference }
    }

    private func canCoalesceCanvasTitleTextEdit(
        for reference: CanvasTitleBoxReference
    ) -> Bool {
        guard editingCanvasTitleBoxReference == reference,
              let baseline = canvasTitleEditingUndoBaseline,
              let history = editHistory,
              history.undoCount > baseline,
              let previousCommand = history.nextUndoCommand,
              case .setTitleTextBox(
                let sequenceID,
                let trackID,
                let clipID,
                let box
              ) = previousCommand
        else {
            return false
        }
        return sequenceID == reference.sequenceID
            && trackID == reference.trackID
            && clipID == reference.clipID
            && box.id == reference.boxID
    }

    private func setCanvasTitleBoxOrigin(
        _ origin: CanvasPoint,
        layout: CanvasTitleBoxLayout
    ) -> Bool {
        guard origin != layout.box.origin else {
            return true
        }

        endCanvasTitleTextEditing()
        selectedCanvasTitleBoxReference = layout.reference
        selectClip(
            trackID: layout.reference.trackID,
            clipID: layout.reference.clipID,
            mode: .replace
        )
        return applyEdit(
            .setTitleTextBox(
                sequenceID: layout.reference.sequenceID,
                trackID: layout.reference.trackID,
                clipID: layout.reference.clipID,
                box: CanvasTitleBoxEditor.copying(layout.box, origin: origin)
            )
        )
    }

    private func jump(to marker: Marker, in sequence: Sequence) {
        guard let frame = try? marker.time.frameIndex(
            at: sequence.timebase,
            rounding: .nearestOrAwayFromZero
        ) else {
            return
        }

        scrub(to: frame)
        selectMarker(marker.id)
    }

    private func updateProject(_ project: Project) {
        persistActiveSequenceContext()
        self.project = project
        refreshDirtyState()
        bindRenderPackageRoot()
        let sequenceIDs = Set(project.sequences.map(\.id))
        sequenceContexts = sequenceContexts.filter { sequenceIDs.contains($0.key) }

        if let activeSequenceID,
           let sequence = project.sequences.first(where: { $0.id == activeSequenceID })
        {
            restoreActiveSequenceContext(for: sequence)
        } else if let sequence = project.sequences.first {
            restoreActiveSequenceContext(for: sequence)
        } else {
            activeSequenceID = nil
            durationFrames = 1
            playheadFrame = 0
            timelineState = TimelineInteractionState()
            playbackController = nil
            presentedTexture = nil
        }
        requestRenderForCurrentFrame()
        ensureAudioPlanForPlayback()
    }

    /// Assigns or clears `EditorAjarRenderPipeline.packageRootURL` from the open package.
    ///
    /// The package URL is known when the session opens (autosave / project package path). Without
    /// it, proxy path resolution and generation cannot run. Cleared when no project is open.
    private func bindRenderPackageRoot() {
        renderPipeline?.packageRootURL = project != nil ? projectPackageRootURL : nil
    }

    // MARK: - Proxy generation (FR-MED-004)

    /// Production proxy session factory: original-media decode via `MediaTranscodeFrameProvider`.
    private static func makeProxySessionFactory() -> ProxySessionFactory {
        { jobID, request, onProgress in
            do {
                let mediaProvider = MediaTranscodeFrameProvider(
                    mediaID: request.mediaID,
                    sourceURL: request.sourceURL,
                    frameRate: request.frameRate,
                    frameCount: request.frameCount,
                    outputResolution: request.resolution
                )
                let adapter = ClosureProxySourceFrameProvider { index, buffer in
                    try await mediaProvider.provideFrame(index: index, into: buffer)
                }
                return ProxyGenerationSession(
                    id: jobID,
                    request: request,
                    frameProvider: adapter,
                    onFrameProgress: onProgress
                )
            } catch {
                return ProxyGenerationSession(
                    id: jobID,
                    request: request,
                    frameProvider: FailingProxySourceFrameProvider(
                        reason: String(describing: error)
                    ),
                    onFrameProgress: onProgress
                )
            }
        }
    }

    private func startProxyQueueObservation() {
        proxyObserveTask?.cancel()
        let queue = proxyGenerationQueue
        proxyObserveTask = Task { [weak self] in
            let stream = await queue.snapshotStream()
            for await snapshots in stream {
                guard let self else {
                    return
                }
                await MainActor.run {
                    self.handleProxyJobSnapshots(snapshots)
                }
            }
        }
    }

    private func handleProxyJobSnapshots(_ snapshots: [ProxyJobSnapshot]) {
        var progress = proxyGenerationProgress
        var needsRerender = false

        for snapshot in snapshots {
            let mediaID = snapshot.mediaID
            switch snapshot.state {
            case .pending, .running, .pausedWillRestart:
                progress[mediaID] = snapshot.progress.fractionCompleted
                proxyJobsInFlight.insert(mediaID)
            case .done:
                progress.removeValue(forKey: mediaID)
                // Apply terminal outcomes only once per in-flight job (stream re-yields history).
                guard proxyJobsInFlight.remove(mediaID) != nil else {
                    continue
                }
                if let relative = snapshot.result?.relativePath {
                    applyProxyState(.ready(relativePath: relative), for: mediaID)
                    needsRerender = true
                }
            case .failed:
                progress.removeValue(forKey: mediaID)
                guard proxyJobsInFlight.remove(mediaID) != nil else {
                    continue
                }
                let message = snapshot.failure.map(String.init(describing:))
                applyProxyState(.failed(message: message), for: mediaID)
            case .cancelled:
                progress.removeValue(forKey: mediaID)
                guard proxyJobsInFlight.remove(mediaID) != nil else {
                    continue
                }
                applyProxyState(.failed(message: "cancelled"), for: mediaID)
            }
        }

        proxyGenerationProgress = progress
        if needsRerender {
            requestRenderForCurrentFrame()
        }
    }

    /// Enqueues real proxy jobs for media reported as needing generation during playback.
    private func enqueueProxyGeneration(for mediaIDs: Set<UUID>) {
        guard let project, let packageRoot = projectPackageRootURL else {
            for mediaID in mediaIDs {
                proxyGenerationProgress[mediaID] = 0
            }
            return
        }

        for mediaID in mediaIDs {
            guard !proxyJobsInFlight.contains(mediaID),
                  let media = project.mediaPool.first(where: { $0.id == mediaID }),
                  let sourceURL = media.sourceURL,
                  let frameRate = media.metadata.conformedFrameRate ?? media.metadata.frameRate,
                  let originalDims = media.metadata.pixelDimensions
            else {
                continue
            }
            // Skip media already generating (queue also dedupes pending/running).
            if case .generating = media.proxyState {
                proxyJobsInFlight.insert(mediaID)
                continue
            }

            let proxyDims = MediaProxyResolutionPolicy.proxyDimensions(for: originalDims)
            let relativePath = ProxyStorageLayout.relativePath(
                mediaID: mediaID,
                contentHash: media.contentHash,
                resolution: proxyDims
            )
            let destinationURL = ProxyStorageLayout.absoluteURL(
                packageRootURL: packageRoot,
                relativePath: relativePath
            )
            let frameCount: Int64
            do {
                let count = try media.metadata.duration.frameIndex(
                    at: frameRate,
                    rounding: .towardZero
                )
                frameCount = max(1, count)
            } catch {
                continue
            }
            let colorSpace = Self.exportColorSpace(for: media.metadata.colorSpace)

            do {
                try ProxyStorageLayout.ensureProxiesDirectory(packageRootURL: packageRoot)
            } catch {
                applyProxyState(
                    .failed(message: "could not create proxies directory: \(error)"),
                    for: mediaID
                )
                continue
            }

            // Durable proxy lifecycle is regeneratable cache state (ADR-0007), not a creative
            // edit — mutate via `replaceCurrentProjectPreservingHistory` (undo-exempt) so undo
            // does not resurrect stale readiness; still autosaved with the document.
            applyProxyState(.generating, for: mediaID)
            proxyGenerationProgress[mediaID] = 0
            proxyJobsInFlight.insert(mediaID)

            let request = ProxyGenerationRequest(
                mediaID: mediaID,
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                relativePath: relativePath,
                resolution: proxyDims,
                frameCount: frameCount,
                frameRate: frameRate,
                colorSpace: colorSpace
            )
            let job = ProxyGenerationJob(
                mediaID: mediaID,
                displayName: media.sourceURL?.lastPathComponent ?? mediaID.uuidString,
                request: request
            )
            let queue = proxyGenerationQueue
            Task {
                _ = await queue.enqueue(job)
            }
        }
    }

    /// Explicit media-browser proxy action; the queue and durable state remain centralized here.
    func generateProxy(for mediaID: UUID) {
        guard isProjectEditable else { return }
        if proxyJobsInFlight.contains(mediaID) { return }
        applyProxyState(.none, for: mediaID)
        enqueueProxyGeneration(for: [mediaID])
    }

    /// Starts the native single-file relink seam.
    func presentRelinker(for mediaID: UUID) {
        guard isProjectEditable,
              project?.mediaPool.contains(where: { $0.id == mediaID && $0.isOffline }) == true
        else { return }
        pendingRelinkMismatch = nil
        mediaIDAwaitingRelink = mediaID
    }

    func dismissRelinker() { mediaIDAwaitingRelink = nil }

    /// Opens the batch relink-by-folder picker when any offline media is present (FR-MED-007).
    func presentBatchRelinker() {
        guard isProjectEditable,
              project?.mediaPool.contains(where: \.isOffline) == true
        else { return }
        isBatchRelinkFolderPickerPresented = true
    }

    func dismissBatchRelinker() {
        isBatchRelinkFolderPickerPresented = false
    }

    /// Whether the library should offer batch relink (editable project with offline items).
    var canBatchRelinkOfflineMedia: Bool {
        isProjectEditable && (project?.mediaPool.contains(where: \.isOffline) == true)
    }

    func handleRelinkerResult(_ result: Result<URL, Error>) {
        guard let mediaID = mediaIDAwaitingRelink, let project else { return }
        mediaIDAwaitingRelink = nil
        guard case .success(let url) = result else { return }
        performSingleFileRelink(
            mediaID: mediaID,
            url: url,
            project: project,
            mismatchPolicy: .warn
        )
    }

    /// Explicit hash-mismatch override after the user confirms the alert (FR-MED-007).
    func overridePendingRelinkMismatch() {
        guard let pending = pendingRelinkMismatch, let project else {
            pendingRelinkMismatch = nil
            return
        }
        pendingRelinkMismatch = nil
        performSingleFileRelink(
            mediaID: pending.mediaID,
            url: pending.candidateURL,
            project: project,
            mismatchPolicy: .override
        )
    }

    func dismissPendingRelinkMismatch() {
        pendingRelinkMismatch = nil
    }

    private func performSingleFileRelink(
        mediaID: UUID,
        url: URL,
        project: Project,
        mismatchPolicy: MediaRelinkMismatchPolicy
    ) {
        // Package root is required so provenance-aware relink can re-run FFmpeg into
        // `.ajar/transcodes/` when the chosen file matches a fallback import's original
        // (`MediaRelinkDecision.matchedOriginalRequiresTranscode` → prepare re-transcodes).
        let projectPackageURL = projectPackageRootURL
        Task { [weak self] in
            guard let self else { return }
            do {
                let preparation = try await Task.detached(priority: .userInitiated) {
                    // `prepare` is async: hash/bookmark I/O, and when the candidate matches
                    // stored `transcodeProvenance.originalContentHash` it routes through the
                    // FFmpeg import transcoder before returning `.ready`.
                    try await MediaRelinkCommand().prepare(
                        mediaReferenceID: mediaID,
                        newFileURL: url,
                        in: project,
                        projectPackageURL: projectPackageURL,
                        mismatchPolicy: mismatchPolicy
                    )
                }.value
                switch preparation {
                case .ready(let command, _):
                    // Covers both direct hash/filename matches and successful re-transcode of a
                    // matched original (the latter is not a separate preparation case — prepare
                    // absorbs `matchedOriginalRequiresTranscode` into `.ready` or throws).
                    _ = self.applyEdit(command)
                    self.requestMediaPreview(forID: mediaID)
                    self.loadMessage = AppString.localized(
                        "library.relink.success",
                        "Media relinked"
                    )
                case .warning(let warning):
                    // Hash mismatch / missing stored or candidate hash — surface Override alert;
                    // no silent accept of different bytes.
                    self.pendingRelinkMismatch = EditorAjarPendingRelinkMismatch(
                        mediaID: mediaID,
                        candidateURL: url,
                        warning: warning
                    )
                    self.loadMessage = AppString.localized(
                        "library.relink.mismatch",
                        "Relink file does not match the original media"
                    )
                }
            } catch let error as MediaRelinkCommandError {
                // Includes `.retranscodeFailed` (FFmpeg missing/failed/timed out/cancelled, or
                // package URL unavailable) with #238-aligned guidance.
                self.loadMessage = AppString.mediaRelinkFailureMessage(for: error)
            } catch {
                self.loadMessage = AppString.localized(
                    "library.relink.failed",
                    "Relink failed: \(String(describing: error))"
                )
            }
        }
    }

    /// Batch relink offline media by recursive filename + content-hash match (FR-MED-007 / #218).
    func handleBatchRelinkerResult(_ result: Result<[URL], Error>) {
        isBatchRelinkFolderPickerPresented = false
        guard case .success(let urls) = result, let folderURL = urls.first, let project else {
            return
        }
        do {
            let batch = try MediaRelinkCommand().prepareBatch(folderURL: folderURL, in: project)
            if let command = batch.command {
                _ = applyEdit(command)
                for mediaID in batch.relinkedMediaIDs {
                    requestMediaPreview(forID: mediaID)
                }
            }
            batchRelinkSummary = batch
            isBatchRelinkSummaryPresented = true
            loadMessage = AppString.localized(
                "library.relink.batch.status",
                "Batch relink: \(batch.relinkedMediaIDs.count) relinked, \(batch.unresolvedMediaIDs.count) unmatched"
            )
        } catch let error as MediaRelinkCommandError {
            loadMessage = AppString.mediaRelinkFailureMessage(for: error)
        } catch {
            loadMessage = AppString.localized(
                "library.relink.failed",
                "Relink failed: \(String(describing: error))"
            )
        }
    }

    func dismissBatchRelinkSummary() {
        batchRelinkSummary = nil
        isBatchRelinkSummaryPresented = false
    }

    /// Incremental thumbnail/waveform request. Offline items deliberately skip extraction.
    func requestMediaPreview(for media: MediaRef) async {
        guard !media.isOffline, media.contentHash != nil else { return }
        if mediaPreviewTasks[media.id] != nil { return }
        guard let cache = ensureMediaPreviewCache() else { return }
        let mediaID = media.id
        let task = Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.mediaPreviewTasks[mediaID] = nil
                }
            }
            if media.metadata.pixelDimensions != nil {
                guard let data = try? await cache.data(for: media, kind: .thumbnail),
                      !Task.isCancelled
                else { return }
                await MainActor.run { self?.mediaThumbnailData[mediaID] = data }
            } else if media.metadata.audioChannelLayout != nil
                || media.metadata.pixelDimensions == nil
            {
                guard let data = try? await cache.data(for: media, kind: .waveform),
                      !Task.isCancelled,
                      let summary = try? JSONDecoder().decode(AudioWaveformSummary.self, from: data)
                else { return }
                await MainActor.run { self?.mediaWaveformSummary[mediaID] = summary }
            }
        }
        mediaPreviewTasks[mediaID] = task
        // Propagate SwiftUI `.task` cancellation into the per-id extraction task (M1).
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func requestMediaPreview(forID mediaID: UUID) {
        guard let media = project?.mediaPool.first(where: { $0.id == mediaID }) else { return }
        Task { await requestMediaPreview(for: media) }
    }

    /// Cancels per-id preview extraction (tile disappear) and notifies the cache (M1).
    func cancelMediaPreview(for mediaID: UUID) {
        mediaPreviewTasks[mediaID]?.cancel()
        mediaPreviewTasks[mediaID] = nil
        if let media = project?.mediaPool.first(where: { $0.id == mediaID }),
           let cache = mediaPreviewCache
        {
            Task {
                await cache.cancel(for: media, kind: .thumbnail)
                await cache.cancel(for: media, kind: .waveform)
            }
        }
    }

    /// Panel close / project swap — drop all preview and hover work.
    func cancelAllMediaPreviews() {
        for (_, task) in mediaPreviewTasks {
            task.cancel()
        }
        mediaPreviewTasks.removeAll()
        cancelMediaHoverPreview()
        if let cache = mediaPreviewCache {
            Task { await cache.cancelAll() }
        }
    }

    /// Throttled grid hover decode via the bounded cache scheduler (M5); transient store only (M4).
    func requestMediaHoverPreview(mediaID: UUID, fraction: Double) {
        mediaHoverTask?.cancel()
        mediaHoverMediaID = mediaID
        guard let media = project?.mediaPool.first(where: { $0.id == mediaID }),
              !media.isOffline,
              media.metadata.pixelDimensions != nil,
              let cache = ensureMediaPreviewCache()
        else { return }
        mediaHoverTask = Task { [weak self] in
            guard let scaled = try? media.metadata.duration.multiplied(
                by: Int64((fraction * 1_000).rounded())
            ),
                let time = try? scaled.divided(by: 1_000),
                !Task.isCancelled
            else { return }
            guard let data = try? await cache.hoverFramePNG(for: media, at: time),
                  !Task.isCancelled
            else { return }
            await MainActor.run {
                guard self?.mediaHoverMediaID == mediaID else { return }
                self?.mediaHoverPreviewData = [mediaID: data]
            }
        }
    }

    func cancelMediaHoverPreview() {
        mediaHoverTask?.cancel()
        mediaHoverTask = nil
        mediaHoverMediaID = nil
        // Restore durable thumbnail display by clearing the transient hover store (M4).
        if !mediaHoverPreviewData.isEmpty {
            mediaHoverPreviewData = [:]
        }
    }

    /// Package root for previews: saved project, else autosave package for untitled work (M3).
    /// Internal for tests that assert the untitled fallback.
    var mediaPreviewPackageRootURL: URL? {
        projectPackageRootURL ?? autosavePackageRootURL
    }

    private func ensureMediaPreviewCache() -> MediaPreviewCache? {
        if let mediaPreviewCache {
            return mediaPreviewCache
        }
        guard let root = mediaPreviewPackageRootURL else {
            return nil
        }
        let cache = MediaPreviewCache(packageURL: root)
        mediaPreviewCache = cache
        return cache
    }

    /// Simple #235 drop behavior: insert/ripple at the playhead on the first compatible track.
    @discardableResult
    func insertMediaOnTimeline(mediaID: UUID) -> Bool {
        guard let media = project?.mediaPool.first(where: { $0.id == mediaID }),
              !media.isOffline, let sequence = activeSequence else { return false }
        let kind: TrackKind = media.metadata.pixelDimensions == nil ? .audio : .video
        let tracks = kind == .video ? sequence.videoTracks : sequence.audioTracks
        guard let track = tracks.first(where: { !$0.locked }) else { return false }
        let start = (try? RationalTime.atFrame(playheadFrame, frameRate: sequence.timebase)) ?? .zero
        // Stills declare a large source extent for trim/extend; initial placement is 5 s.
        let isStill = StillMediaDefaults.isStillCodec(media.metadata.codecID)
            || media.sourceURL.map(StillMediaDefaults.isStillImageFile) == true
        let duration: RationalTime
        if isStill, let placement = try? StillMediaDefaults.defaultDuration() {
            duration = placement
        } else {
            duration = media.metadata.duration
        }
        guard let range = try? TimeRange(start: start, duration: duration),
              let sourceRange = try? TimeRange(start: .zero, duration: duration)
        else {
            return false
        }
        let clipName = media.sourceURL?
            .deletingPathExtension()
            .lastPathComponent ?? "Media"
        let clip = Clip(
            id: UUID(),
            source: .media(id: mediaID),
            sourceRange: sourceRange,
            timelineRange: range,
            kind: kind,
            name: clipName
        )
        return applyEdit(.insertClip(sequenceID: sequence.id, trackID: track.id, clip: clip))
    }

    private func placeMediaOnTimeline(mediaID: UUID, overwrite: Bool, append: Bool) -> Bool {
        guard let media = project?.mediaPool.first(where: { $0.id == mediaID }),
              !media.isOffline, let sequence = activeSequence else { return false }
        let kind: TrackKind = media.metadata.pixelDimensions == nil ? .audio : .video
        let tracks = kind == .video ? sequence.videoTracks : sequence.audioTracks
        guard let track = tracks.first(where: { !$0.locked }) else { return false }
        let start: RationalTime
        if append {
            start = track.items.compactMap { try? $0.timelineRange.end() }.max() ?? .zero
        } else {
            start = (try? RationalTime.atFrame(playheadFrame, frameRate: sequence.timebase)) ?? .zero
        }
        guard let timelineRange = try? TimeRange(start: start, duration: media.metadata.duration),
              let sourceRange = try? TimeRange(start: .zero, duration: media.metadata.duration)
        else { return false }
        let clip = Clip(
            id: UUID(), source: .media(id: mediaID), sourceRange: sourceRange,
            timelineRange: timelineRange, kind: kind,
            name: media.sourceURL?.deletingPathExtension().lastPathComponent
                ?? AppString.localized("timeline.media.untitled", "Media")
        )
        let command: EditCommand = overwrite
            ? .overwriteClip(sequenceID: sequence.id, trackID: track.id, clip: clip)
            : .appendClip(sequenceID: sequence.id, trackID: track.id, clip: clip)
        return applyEdit(command)
    }

    /// Applies durable `MediaRef.proxyState` without creating an undo entry (cache/derived state).
    private func applyProxyState(_ proxyState: MediaProxyState, for mediaID: UUID) {
        guard let project else {
            return
        }
        // Skip no-op writes to avoid autosave thrash.
        if let current = project.mediaPool.first(where: { $0.id == mediaID }),
           current.proxyState == proxyState {
            return
        }
        let updated = project.updatingMediaProxyState(proxyState, for: [mediaID])
        if var history = editHistory {
            self.project = history.replaceCurrentProjectPreservingHistory(updated)
            editHistory = history
            refreshDirtyState()
            if projectOpenMode.allowsEditing {
                scheduleAutosaveCheckpoint(project: updated)
            }
        } else {
            self.project = updated
            refreshDirtyState()
        }
    }

    private static func exportColorSpace(for media: MediaColorSpace) -> ExportColorSpace {
        switch media {
        case .displayP3:
            return .displayP3
        case .rec709, .sRGB, .rec2020, .unspecified, .unknown:
            return .rec709
        }
    }

    private func persistActiveSequenceContext() {
        guard let activeSequenceID else {
            return
        }

        sequenceContexts[activeSequenceID] = SequenceEditingContext(
            playheadFrame: playheadFrame,
            timelineState: timelineState
        )
    }

    private func restoreActiveSequenceContext(for sequence: Sequence) {
        let context = sequenceContexts[sequence.id] ?? SequenceEditingContext()
        let nextDurationFrames = Self.durationFrames(for: sequence)
        activeSequenceID = sequence.id
        durationFrames = nextDurationFrames
        playheadFrame = min(max(0, context.playheadFrame), max(0, nextDurationFrames - 1))
        timelineState = Self.validTimelineState(context.timelineState, for: sequence)
        playbackController = EditorAjarPlaybackController(
            frameRate: sequence.timebase,
            durationFrames: nextDurationFrames,
            playheadFrame: playheadFrame
        )
        persistActiveSequenceContext()
    }

    private static func validTimelineState(
        _ state: TimelineInteractionState,
        for sequence: Sequence
    ) -> TimelineInteractionState {
        var nextState = state
        let availableClipIDs = Set(TimelineInteraction.clipReferences(in: sequence))
        let availableMarkerIDs = Set(sequence.markers.map(\.id))
        nextState.selectedClips = nextState.selectedClips.intersection(availableClipIDs)
        if let anchor = nextState.selectionAnchor,
           !availableClipIDs.contains(anchor)
        {
            nextState.selectionAnchor = nextState.selectedClips.first
        }
        if let selectedMarkerID = nextState.selectedMarkerID,
           !availableMarkerIDs.contains(selectedMarkerID)
        {
            nextState.selectedMarkerID = nil
        }
        return nextState
    }

    private func startAutosaveLoop() {
        autosaveLoopTask?.cancel()
        autosaveLoopTask = nil
        guard autosaveCoordinator != nil,
              autosaveIntervalSeconds.isFinite,
              autosaveIntervalSeconds > 0,
              projectOpenMode.allowsEditing
        else {
            return
        }

        let nanoseconds = UInt64(max(0.1, autosaveIntervalSeconds) * 1_000_000_000)
        autosaveLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                self?.autosaveCurrentProject()
            }
        }
    }

    private func scheduleAutosave(command: EditCommand, project: Project) {
        guard let autosaveCoordinator, projectOpenMode.allowsEditing else {
            return
        }

        let openMode = projectOpenMode
        autosaveCommandCount += 1
        let commandCount = autosaveCommandCount
        let previousWriteTask = autosaveWriteTask
        autosaveWriteTask = Task {
            [
                weak self,
                autosaveCoordinator,
                command,
                commandCount,
                project,
                openMode,
                previousWriteTask
            ] in
            await previousWriteTask?.value
            let message = await autosaveCoordinator.recordSignificantEdit(
                command: command,
                sequenceNumber: commandCount,
                project: project,
                openMode: openMode
            )
            await MainActor.run {
                if let message {
                    self?.loadMessage = message
                }
            }
        }
    }

    private func scheduleAutosaveCheckpoint(project: Project) {
        guard let autosaveCoordinator, projectOpenMode.allowsEditing else {
            return
        }

        guard isDocumentDirty else {
            resetAutosaveForInstalledProject()
            return
        }

        let openMode = projectOpenMode
        let commandCount = autosaveCommandCount
        let previousWriteTask = autosaveWriteTask
        autosaveWriteTask = Task {
            [weak self, autosaveCoordinator, commandCount, project, openMode, previousWriteTask] in
            await previousWriteTask?.value
            let message = await autosaveCoordinator.writeSnapshot(
                project: project,
                appliedCommandCount: commandCount,
                openMode: openMode
            )
            await MainActor.run {
                if let message {
                    self?.loadMessage = message
                }
            }
        }
    }

    private func autosaveCurrentProject() {
        guard let project, projectOpenMode.allowsEditing, isDocumentDirty else {
            return
        }
        scheduleAutosaveCheckpoint(project: project)
    }

    private func autosaveCurrentProjectAndWait() async {
        guard let project,
              let autosaveCoordinator,
              projectOpenMode.allowsEditing,
              isDocumentDirty
        else {
            return
        }

        await autosaveWriteTask?.value
        let message = await autosaveCoordinator.writeSnapshot(
            project: project,
            appliedCommandCount: autosaveCommandCount,
            openMode: projectOpenMode
        )
        if let message {
            loadMessage = message
        }
    }
}

private actor EditorAjarAutosaveCoordinator {
    private let packageURL: URL

    init(packageURL: URL) {
        self.packageURL = packageURL
    }

    /// Starts recovery state for a newly installed app document.
    ///
    /// Dirty editable sessions replace both checkpoint and journal. Clean/read-only sessions
    /// remove stale recovery so the next normal launch stays at New/Open.
    ///
    /// The package **root directory is kept** (or recreated) so untitled sessions can still host
    /// regeneratable package-local caches such as ADR-0007 `thumbnails/` (media browser previews).
    /// Only recovery/document identity files are cleared — never leave callers with a missing root.
    func resetSession(
        project: Project,
        openMode: AjarProjectOpenMode,
        shouldPersistRecovery: Bool
    ) -> String? {
        do {
            if shouldPersistRecovery, openMode.allowsEditing {
                try AjarAutosaveStore.writeSnapshot(
                    project,
                    appliedCommandCount: 0,
                    openMode: openMode,
                    to: packageURL
                )
                try AjarAutosaveStore.replaceJournal(with: [], in: packageURL)
            } else {
                try Self.clearRecoverableContentPreservingPackageRoot(at: packageURL)
            }
            return nil
        } catch {
            let detail = String(describing: error)
            return AppString.localized("status.autosaveFailed", "Autosave failed: \(detail)")
        }
    }

    /// Drops files that make `AjarAutosaveStore.hasRecoverableSnapshot` true while keeping the
    /// package directory (and any `thumbnails/` cache) intact for untitled preview fallbacks.
    private static func clearRecoverableContentPreservingPackageRoot(at packageURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        for relativePath in ["project.json", "media.json", "recovery"] {
            let url = packageURL.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    func recordSignificantEdit(
        command: EditCommand,
        sequenceNumber: Int,
        project: Project,
        openMode: AjarProjectOpenMode
    ) -> String? {
        do {
            try AjarAutosaveStore.appendJournalEntry(
                command: command,
                sequenceNumber: sequenceNumber,
                to: packageURL
            )
            try AjarAutosaveStore.writeSnapshot(
                project,
                appliedCommandCount: sequenceNumber,
                openMode: openMode,
                to: packageURL
            )
            return nil
        } catch {
            let detail = String(describing: error)
            return AppString.localized("status.autosaveFailed", "Autosave failed: \(detail)")
        }
    }

    func writeSnapshot(
        project: Project,
        appliedCommandCount: Int,
        openMode: AjarProjectOpenMode
    ) -> String? {
        do {
            try AjarAutosaveStore.writeSnapshot(
                project,
                appliedCommandCount: appliedCommandCount,
                openMode: openMode,
                to: packageURL
            )
            return nil
        } catch {
            let detail = String(describing: error)
            return AppString.localized("status.autosaveFailed", "Autosave failed: \(detail)")
        }
    }
}

struct SequenceTab: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let isActive: Bool
    let canClose: Bool
}

private struct SequenceEditingContext: Equatable, Sendable {
    var playheadFrame: Int64
    var timelineState: TimelineInteractionState

    init(
        playheadFrame: Int64 = 0,
        timelineState: TimelineInteractionState = TimelineInteractionState()
    ) {
        self.playheadFrame = playheadFrame
        self.timelineState = timelineState
    }
}

struct TimelineInteractionState: Equatable, Sendable {
    static let minimumPixelsPerFrame = 1.0
    static let maximumPixelsPerFrame = 48.0
    static let minimumLaneHeight = 36.0
    static let maximumLaneHeight = 96.0

    var pixelsPerFrame: Double
    var laneHeight: Double
    var snappingEnabled: Bool
    var snapToleranceFrames: Int64
    var selectedClips: Set<TimelineClipReference>
    var selectionAnchor: TimelineClipReference?
    var selectedMarkerID: UUID?
    var selectionInFrame: Int64?
    var selectionOutFrame: Int64?

    init(
        pixelsPerFrame: Double = 8.0,
        laneHeight: Double = 46.0,
        snappingEnabled: Bool = true,
        snapToleranceFrames: Int64 = 2,
        selectedClips: Set<TimelineClipReference> = [],
        selectionAnchor: TimelineClipReference? = nil,
        selectedMarkerID: UUID? = nil,
        selectionInFrame: Int64? = nil,
        selectionOutFrame: Int64? = nil
    ) {
        self.pixelsPerFrame = pixelsPerFrame
        self.laneHeight = laneHeight
        self.snappingEnabled = snappingEnabled
        self.snapToleranceFrames = snapToleranceFrames
        self.selectedClips = selectedClips
        self.selectionAnchor = selectionAnchor
        self.selectedMarkerID = selectedMarkerID
        self.selectionInFrame = selectionInFrame
        self.selectionOutFrame = selectionOutFrame
    }
}

struct TimelineClipReference: Hashable, Sendable {
    let trackID: UUID
    let clipID: UUID
}

enum TimelineTool: Equatable, Sendable {
    case selection
    case blade
}

enum TimelineMediaEditMode: Equatable, Sendable {
    case insert
    case overwrite
    case append
    case replace
}

enum TimelineTrimEdge: Equatable, Sendable {
    case leading
    case trailing
}

private struct TimelineClipboardItem: Sendable {
    let sourceTrackID: UUID
    let clip: Clip
}

private extension Clip {
    /// Copy for paste: fresh clip ID, new placement, and an explicit link group.
    ///
    /// `linkGroupID` is required (no default) so paste call sites must decide group identity —
    /// pasted copies never silently inherit the source's link group (#240 review, finding 5).
    func copyingForTimeline(id: UUID, timelineRange: TimeRange, linkGroupID: UUID?) -> Clip {
        Clip(
            id: id,
            source: source,
            sourceRange: sourceRange,
            timelineRange: timelineRange,
            kind: kind,
            name: name,
            linkGroupID: linkGroupID,
            transform: transform,
            transformAnimation: transformAnimation,
            effects: effects,
            effectsAnimation: effectsAnimation,
            effectStack: effectStack,
            effectStackAnimation: effectStackAnimation,
            audioMix: audioMix,
            leadingTransition: leadingTransition,
            trailingTransition: trailingTransition,
            speed: speed,
            reverse: reverse,
            freezeFrame: freezeFrame,
            timeRemap: timeRemap,
            frameSampling: frameSampling
        )
    }
}

struct SelectedTransformInspectorState: Equatable, Sendable {
    let clipName: String
    let transform: ClipTransform
}

struct SelectedTrackCompositingInspectorState: Equatable, Sendable {
    let trackName: String
    let opacity: RationalValue
    let blendMode: ClipBlendMode
}

struct CanvasClipTransformLayout: Equatable, Sendable {
    let canvasSize: PixelDimensions
    let clipSize: PixelDimensions
    let transform: ClipTransform
}

enum TransformInspectorField: String, CaseIterable, Identifiable, Sendable {
    case positionX
    case positionY
    case scaleXPercent
    case scaleYPercent
    case anchorX
    case anchorY
    case rotationDegrees
    case opacityPercent
    case cropLeft
    case cropTop
    case cropRight
    case cropBottom

    var id: String { rawValue }

    /// English title. Backs the stable, non-localized accessibility identifier (NFR-I18N-001).
    var title: String {
        switch self {
        case .positionX:
            return "Position X"
        case .positionY:
            return "Position Y"
        case .scaleXPercent:
            return "Scale X %"
        case .scaleYPercent:
            return "Scale Y %"
        case .anchorX:
            return "Anchor X"
        case .anchorY:
            return "Anchor Y"
        case .rotationDegrees:
            return "Rotation"
        case .opacityPercent:
            return "Opacity %"
        case .cropLeft:
            return "Crop Left"
        case .cropTop:
            return "Crop Top"
        case .cropRight:
            return "Crop Right"
        case .cropBottom:
            return "Crop Bottom"
        }
    }

    /// Localized title for visible text / VoiceOver labels.
    var localizedTitle: String {
        switch self {
        case .positionX:
            return AppString.localized("transform.field.positionX", "Position X")
        case .positionY:
            return AppString.localized("transform.field.positionY", "Position Y")
        case .scaleXPercent:
            return AppString.localized("transform.field.scaleX", "Scale X %")
        case .scaleYPercent:
            return AppString.localized("transform.field.scaleY", "Scale Y %")
        case .anchorX:
            return AppString.localized("transform.field.anchorX", "Anchor X")
        case .anchorY:
            return AppString.localized("transform.field.anchorY", "Anchor Y")
        case .rotationDegrees:
            return AppString.localized("transform.field.rotation", "Rotation")
        case .opacityPercent:
            return AppString.localized("transform.field.opacity", "Opacity %")
        case .cropLeft:
            return AppString.localized("transform.field.cropLeft", "Crop Left")
        case .cropTop:
            return AppString.localized("transform.field.cropTop", "Crop Top")
        case .cropRight:
            return AppString.localized("transform.field.cropRight", "Crop Right")
        case .cropBottom:
            return AppString.localized("transform.field.cropBottom", "Crop Bottom")
        }
    }

    var accessibilityIdentifier: String {
        "Transform \(title)"
    }
}

enum TransformFieldValueMapper {
    static func stringValue(for field: TransformInspectorField, in transform: ClipTransform) -> String {
        switch field {
        case .positionX:
            return string(from: transform.position.x)
        case .positionY:
            return string(from: transform.position.y)
        case .scaleXPercent:
            return percentString(from: transform.scale.x)
        case .scaleYPercent:
            return percentString(from: transform.scale.y)
        case .anchorX:
            return string(from: transform.anchorPoint.x)
        case .anchorY:
            return string(from: transform.anchorPoint.y)
        case .rotationDegrees:
            return string(from: transform.rotation.degrees)
        case .opacityPercent:
            return percentString(from: transform.opacity)
        case .cropLeft:
            return "\(transform.crop.left)"
        case .cropTop:
            return "\(transform.crop.top)"
        case .cropRight:
            return "\(transform.crop.right)"
        case .cropBottom:
            return "\(transform.crop.bottom)"
        }
    }

    static func updatedTransform(
        _ field: TransformInspectorField,
        rawValue: String,
        in transform: ClipTransform
    ) -> ClipTransform? {
        switch field {
        case .positionX:
            return rational(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    position: CanvasPoint(x: value, y: transform.position.y)
                )
            }
        case .positionY:
            return rational(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    position: CanvasPoint(x: transform.position.x, y: value)
                )
            }
        case .scaleXPercent:
            return percent(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    scale: ClipScale(x: value, y: transform.scale.y)
                )
            }
        case .scaleYPercent:
            return percent(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    scale: ClipScale(x: transform.scale.x, y: value)
                )
            }
        case .anchorX:
            return rational(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    anchorPoint: CanvasPoint(x: value, y: transform.anchorPoint.y)
                )
            }
        case .anchorY:
            return rational(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    anchorPoint: CanvasPoint(x: transform.anchorPoint.x, y: value)
                )
            }
        case .rotationDegrees:
            return rational(rawValue).map { value in
                TransformEditor.copying(transform, rotation: ClipRotation(degrees: value))
            }
        case .opacityPercent:
            return percent(rawValue).map { value in
                TransformEditor.copying(transform, opacity: value)
            }
        case .cropLeft:
            return int64(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    crop: ClipCropInsets(
                        left: value,
                        top: transform.crop.top,
                        right: transform.crop.right,
                        bottom: transform.crop.bottom
                    )
                )
            }
        case .cropTop:
            return int64(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    crop: ClipCropInsets(
                        left: transform.crop.left,
                        top: value,
                        right: transform.crop.right,
                        bottom: transform.crop.bottom
                    )
                )
            }
        case .cropRight:
            return int64(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    crop: ClipCropInsets(
                        left: transform.crop.left,
                        top: transform.crop.top,
                        right: value,
                        bottom: transform.crop.bottom
                    )
                )
            }
        case .cropBottom:
            return int64(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    crop: ClipCropInsets(
                        left: transform.crop.left,
                        top: transform.crop.top,
                        right: transform.crop.right,
                        bottom: value
                    )
                )
            }
        }
    }

    private static func string(from value: RationalValue) -> String {
        formatted(value.doubleValue)
    }

    private static func percentString(from value: RationalValue) -> String {
        formatted(value.doubleValue * 100.0)
    }

    private static func formatted(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.000_001 {
            return "\(Int64(value.rounded()))"
        }
        return String(format: "%.2f", value)
    }

    private static func rational(_ rawValue: String) -> RationalValue? {
        double(rawValue).map(RationalValue.approximating)
    }

    private static func percent(_ rawValue: String) -> RationalValue? {
        double(rawValue).map { RationalValue.approximating($0 / 100.0) }
    }

    private static func int64(_ rawValue: String) -> Int64? {
        double(rawValue).map { Int64($0.rounded()) }
    }

    private static func double(_ rawValue: String) -> Double? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              let value = Double(trimmedValue),
              value.isFinite
        else {
            return nil
        }
        return value
    }
}

enum TrackCompositingValueMapper {
    static func percentString(from value: RationalValue) -> String {
        formatted(value.doubleValue * 100.0)
    }

    static func percent(_ rawValue: String) -> RationalValue? {
        double(rawValue).map { RationalValue.approximating($0 / 100.0) }
    }

    private static func formatted(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.000_001 {
            return "\(Int64(value.rounded()))"
        }
        return String(format: "%.2f", value)
    }

    private static func double(_ rawValue: String) -> Double? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              let value = Double(trimmedValue),
              value.isFinite
        else {
            return nil
        }
        return value
    }
}

enum TransformEditor {
    static func copying(
        _ transform: ClipTransform,
        position: CanvasPoint? = nil,
        scale: ClipScale? = nil,
        anchorPoint: CanvasPoint? = nil,
        rotation: ClipRotation? = nil,
        opacity: RationalValue? = nil,
        blendMode: ClipBlendMode? = nil,
        crop: ClipCropInsets? = nil,
        flip: ClipFlip? = nil
    ) -> ClipTransform {
        ClipTransform(
            position: position ?? transform.position,
            scale: scale ?? transform.scale,
            anchorPoint: anchorPoint ?? transform.anchorPoint,
            rotation: rotation ?? transform.rotation,
            opacity: opacity ?? transform.opacity,
            blendMode: blendMode ?? transform.blendMode,
            crop: crop ?? transform.crop,
            flip: flip ?? transform.flip
        )
    }
}

enum CanvasTransformHandle: String, CaseIterable, Identifiable, Sendable {
    case move
    case scaleBottomRight
    case rotate
    case anchor

    var id: String { rawValue }
}

struct CanvasTransformGesture: Equatable, Sendable {
    let handle: CanvasTransformHandle
    let translationX: Double
    let translationY: Double
    let canvasScale: Double
}

enum CanvasTransformGestureMapper {
    static func updatedTransform(
        from transform: ClipTransform,
        gesture: CanvasTransformGesture,
        clipSize: PixelDimensions
    ) -> ClipTransform {
        switch gesture.handle {
        case .move:
            return moved(transform, gesture: gesture)
        case .scaleBottomRight:
            return scaled(transform, gesture: gesture, clipSize: clipSize)
        case .rotate:
            return rotated(transform, gesture: gesture)
        case .anchor:
            return anchored(transform, gesture: gesture)
        }
    }

    private static func moved(
        _ transform: ClipTransform,
        gesture: CanvasTransformGesture
    ) -> ClipTransform {
        TransformEditor.copying(
            transform,
            position: CanvasPoint(
                x: offset(transform.position.x, gesture.translationX, canvasScale: gesture.canvasScale),
                y: offset(transform.position.y, gesture.translationY, canvasScale: gesture.canvasScale)
            )
        )
    }

    private static func scaled(
        _ transform: ClipTransform,
        gesture: CanvasTransformGesture,
        clipSize: PixelDimensions
    ) -> ClipTransform {
        let width = max(1.0, Double(clipSize.width))
        let height = max(1.0, Double(clipSize.height))
        let scaleX = max(0.01, transform.scale.x.doubleValue + gesture.translationX / gesture.canvasScale / width)
        let scaleY = max(0.01, transform.scale.y.doubleValue + gesture.translationY / gesture.canvasScale / height)
        return TransformEditor.copying(
            transform,
            scale: ClipScale(
                x: RationalValue.approximating(scaleX),
                y: RationalValue.approximating(scaleY)
            )
        )
    }

    private static func rotated(
        _ transform: ClipTransform,
        gesture: CanvasTransformGesture
    ) -> ClipTransform {
        let degrees = transform.rotation.degrees.doubleValue + gesture.translationX / 2.0
        return TransformEditor.copying(
            transform,
            rotation: ClipRotation(degrees: RationalValue.approximating(degrees))
        )
    }

    private static func anchored(
        _ transform: ClipTransform,
        gesture: CanvasTransformGesture
    ) -> ClipTransform {
        TransformEditor.copying(
            transform,
            anchorPoint: CanvasPoint(
                x: offset(transform.anchorPoint.x, gesture.translationX, canvasScale: gesture.canvasScale),
                y: offset(transform.anchorPoint.y, gesture.translationY, canvasScale: gesture.canvasScale)
            )
        )
    }

    private static func offset(
        _ value: RationalValue,
        _ delta: Double,
        canvasScale: Double
    ) -> RationalValue {
        RationalValue.approximating(value.doubleValue + delta / max(0.000_001, canvasScale))
    }
}

struct TransformKeyframeLane: Identifiable, Equatable, Sendable {
    let parameter: ClipTransformParameter
    let title: String
    let keyframes: [TransformKeyframePoint]

    var id: String { parameter.rawValue }

    static func makeLanes(
        animation: AnimatableClipTransform,
        frameRate: FrameRate,
        pixelsPerFrame: Double
    ) -> [TransformKeyframeLane] {
        ClipTransformParameter.allCases.map { parameter in
            TransformKeyframeLane(
                parameter: parameter,
                title: parameter.displayName,
                keyframes: TransformKeyframeLookup.keyframes(
                    parameter: parameter,
                    in: animation,
                    frameRate: frameRate,
                    pixelsPerFrame: pixelsPerFrame
                )
            )
        }
    }
}

struct TransformKeyframePoint: Identifiable, Equatable, Sendable {
    let parameter: ClipTransformParameter
    let frame: Int64
    let xPosition: Double
    let keyframe: ClipTransformKeyframe

    var id: String {
        "\(parameter.rawValue)-\(frame)"
    }
}

enum TransformKeyframeLookup {
    static func keyframes(
        parameter: ClipTransformParameter,
        in animation: AnimatableClipTransform,
        frameRate: FrameRate,
        pixelsPerFrame: Double
    ) -> [TransformKeyframePoint] {
        keyframes(parameter: parameter, in: animation).compactMap { keyframe in
            guard let frame = try? keyframe.time.frameIndex(
                at: frameRate,
                rounding: .nearestOrAwayFromZero
            ) else {
                return nil
            }
            return TransformKeyframePoint(
                parameter: parameter,
                frame: frame,
                xPosition: TimelineInteraction.xPosition(
                    frame: frame,
                    pixelsPerFrame: pixelsPerFrame
                ),
                keyframe: keyframe
            )
        }
    }

    static func keyframe(
        parameter: ClipTransformParameter,
        at time: RationalTime,
        in animation: AnimatableClipTransform
    ) -> ClipTransformKeyframe? {
        keyframes(parameter: parameter, in: animation).first { $0.time == time }
    }

    static func value(
        parameter: ClipTransformParameter,
        in transform: ClipTransform
    ) -> ClipTransformKeyframeValue {
        switch parameter {
        case .position:
            return .position(transform.position)
        case .scale:
            return .scale(transform.scale)
        case .anchorPoint:
            return .anchorPoint(transform.anchorPoint)
        case .rotation:
            return .rotation(transform.rotation)
        case .opacity:
            return .opacity(transform.opacity)
        case .crop:
            return .crop(transform.crop)
        }
    }

    private static func keyframes(
        parameter: ClipTransformParameter,
        in animation: AnimatableClipTransform
    ) -> [ClipTransformKeyframe] {
        switch parameter {
        case .position:
            return animation.position.keyframes.map { keyframe in
                ClipTransformKeyframe(
                    time: keyframe.time,
                    value: .position(keyframe.value),
                    interpolation: keyframe.interpolation
                )
            }
        case .scale:
            return animation.scale.keyframes.map { keyframe in
                ClipTransformKeyframe(
                    time: keyframe.time,
                    value: .scale(keyframe.value),
                    interpolation: keyframe.interpolation
                )
            }
        case .anchorPoint:
            return animation.anchorPoint.keyframes.map { keyframe in
                ClipTransformKeyframe(
                    time: keyframe.time,
                    value: .anchorPoint(keyframe.value),
                    interpolation: keyframe.interpolation
                )
            }
        case .rotation:
            return animation.rotation.keyframes.map { keyframe in
                ClipTransformKeyframe(
                    time: keyframe.time,
                    value: .rotation(keyframe.value),
                    interpolation: keyframe.interpolation
                )
            }
        case .opacity:
            return animation.opacity.keyframes.map { keyframe in
                ClipTransformKeyframe(
                    time: keyframe.time,
                    value: .opacity(keyframe.value),
                    interpolation: keyframe.interpolation
                )
            }
        case .crop:
            return animation.crop.keyframes.map { keyframe in
                ClipTransformKeyframe(
                    time: keyframe.time,
                    value: .crop(keyframe.value),
                    interpolation: keyframe.interpolation
                )
            }
        }
    }
}

extension ClipTransformParameter {
    /// English name. Backs stable, non-localized accessibility identifiers (NFR-I18N-001).
    var displayName: String {
        switch self {
        case .position:
            return "Position"
        case .scale:
            return "Scale"
        case .anchorPoint:
            return "Anchor"
        case .rotation:
            return "Rotation"
        case .opacity:
            return "Opacity"
        case .crop:
            return "Crop"
        }
    }

    /// Localized name for visible text / VoiceOver labels.
    var localizedName: String {
        switch self {
        case .position:
            return AppString.localized("transform.param.position", "Position")
        case .scale:
            return AppString.localized("transform.param.scale", "Scale")
        case .anchorPoint:
            return AppString.localized("transform.param.anchor", "Anchor")
        case .rotation:
            return AppString.localized("transform.param.rotation", "Rotation")
        case .opacity:
            return AppString.localized("transform.param.opacity", "Opacity")
        case .crop:
            return AppString.localized("transform.param.crop", "Crop")
        }
    }
}

struct TimelineClipLayout: Equatable, Sendable {
    let reference: TimelineClipReference
    let name: String
    let startFrame: Int64
    let endFrame: Int64
    let xPosition: Double
    let width: Double

    var durationFrames: Int64 {
        max(0, endFrame - startFrame)
    }
}

struct TimelineMarkerLayout: Equatable, Sendable {
    let markerID: UUID
    let name: String
    let note: String
    let color: MarkerColor
    let frame: Int64
    let xPosition: Double
}

enum TimelineSelectionMode: Equatable, Sendable {
    case replace
    case toggle
    case rangeOnTrack
}

struct TimelineSelectionResult: Equatable, Sendable {
    let selectedClips: Set<TimelineClipReference>
    let anchor: TimelineClipReference?
}

struct TimelineFrameRange: Equatable, Sendable {
    let startFrame: Int64
    let endFrame: Int64

    var durationFrames: Int64 {
        max(1, endFrame - startFrame)
    }
}

enum TimelineSnapTargetKind: Equatable, Sendable {
    case playhead
    case marker(UUID)
    case clipEdge(TimelineClipReference)
    case keyframe(TimelineClipReference)
}

struct TimelineSnapTarget: Equatable, Sendable {
    let frame: Int64
    let kind: TimelineSnapTargetKind
}

enum TimelineInteraction {
    static func xPosition(frame: Int64, pixelsPerFrame: Double) -> Double {
        Double(max(0, frame)) * max(TimelineInteractionState.minimumPixelsPerFrame, pixelsPerFrame)
    }

    static func frame(atX xPosition: Double, pixelsPerFrame: Double, durationFrames: Int64) -> Int64 {
        guard xPosition.isFinite, pixelsPerFrame.isFinite, pixelsPerFrame > 0 else {
            return 0
        }

        let roundedFrame = Int64((xPosition / pixelsPerFrame).rounded())
        return min(max(0, roundedFrame), max(0, durationFrames - 1))
    }

    static func contentWidth(
        durationFrames: Int64,
        pixelsPerFrame: Double,
        minimumWidth: Double
    ) -> Double {
        max(minimumWidth, Double(max(1, durationFrames)) * pixelsPerFrame)
    }

    static func zoomedPixelsPerFrame(_ currentValue: Double, factor: Double) -> Double {
        clamped(
            currentValue * factor,
            minimum: TimelineInteractionState.minimumPixelsPerFrame,
            maximum: TimelineInteractionState.maximumPixelsPerFrame
        )
    }

    static func zoomedLaneHeight(_ currentValue: Double, factor: Double) -> Double {
        clamped(
            currentValue * factor,
            minimum: TimelineInteractionState.minimumLaneHeight,
            maximum: TimelineInteractionState.maximumLaneHeight
        )
    }

    static func fittedPixelsPerFrame(durationFrames: Int64, availableWidth: Double) -> Double {
        guard availableWidth.isFinite, availableWidth > 0 else {
            return TimelineInteractionState.minimumPixelsPerFrame
        }

        return clamped(
            availableWidth / Double(max(1, durationFrames)),
            minimum: TimelineInteractionState.minimumPixelsPerFrame,
            maximum: TimelineInteractionState.maximumPixelsPerFrame
        )
    }

    static func clipLayouts(
        for track: Track,
        frameRate: FrameRate,
        pixelsPerFrame: Double
    ) -> [TimelineClipLayout] {
        track.items.compactMap { item in
            guard case .clip(let clip) = item,
                  let startFrame = try? clip.timelineRange.start.frameIndex(
                    at: frameRate,
                    rounding: .down
                  ),
                  let endTime = try? clip.timelineRange.end(),
                  let endFrame = try? endTime.frameIndex(at: frameRate, rounding: .up)
            else {
                return nil
            }

            let durationFrames = max(1, endFrame - startFrame)
            return TimelineClipLayout(
                reference: TimelineClipReference(trackID: track.id, clipID: clip.id),
                name: clip.name,
                startFrame: startFrame,
                endFrame: endFrame,
                xPosition: xPosition(frame: startFrame, pixelsPerFrame: pixelsPerFrame),
                width: Double(durationFrames) * pixelsPerFrame
            )
        }
    }

    static func clipReferences(in sequence: Sequence) -> [TimelineClipReference] {
        (sequence.videoTracks + sequence.audioTracks).flatMap { track in
            track.items.compactMap { item in
                guard case .clip(let clip) = item else {
                    return nil
                }
                return TimelineClipReference(trackID: track.id, clipID: clip.id)
            }
        }
    }

    static func reducedSelection(
        currentSelection: Set<TimelineClipReference>,
        anchor: TimelineClipReference?,
        visibleClipReferences: [TimelineClipReference],
        reference: TimelineClipReference,
        mode: TimelineSelectionMode
    ) -> TimelineSelectionResult {
        switch mode {
        case .replace:
            return TimelineSelectionResult(selectedClips: [reference], anchor: reference)
        case .toggle:
            var nextSelection = currentSelection
            if nextSelection.contains(reference) {
                nextSelection.remove(reference)
            } else {
                nextSelection.insert(reference)
            }
            let nextAnchor = nextSelection.contains(reference) ? reference : nextSelection.first
            return TimelineSelectionResult(selectedClips: nextSelection, anchor: nextAnchor)
        case .rangeOnTrack:
            guard let anchor,
                  anchor.trackID == reference.trackID,
                  let anchorIndex = visibleClipReferences.firstIndex(of: anchor),
                  let referenceIndex = visibleClipReferences.firstIndex(of: reference)
            else {
                return TimelineSelectionResult(selectedClips: [reference], anchor: reference)
            }

            let lowerIndex = min(anchorIndex, referenceIndex)
            let upperIndex = max(anchorIndex, referenceIndex)
            let selectedRange = visibleClipReferences[lowerIndex...upperIndex]
                .filter { $0.trackID == reference.trackID }
            return TimelineSelectionResult(selectedClips: Set(selectedRange), anchor: anchor)
        }
    }

    static func snapTargets(in sequence: Sequence, playheadFrame: Int64) -> [TimelineSnapTarget] {
        var targets = [TimelineSnapTarget(frame: playheadFrame, kind: .playhead)]
        for marker in sequence.markers {
            guard let frame = try? marker.time.frameIndex(at: sequence.timebase, rounding: .nearestOrAwayFromZero)
            else {
                continue
            }
            targets.append(TimelineSnapTarget(frame: frame, kind: .marker(marker.id)))
        }

        for track in sequence.videoTracks + sequence.audioTracks {
            for layout in clipLayouts(
                for: track,
                frameRate: sequence.timebase,
                pixelsPerFrame: 1.0
            ) {
                targets.append(TimelineSnapTarget(frame: layout.startFrame, kind: .clipEdge(layout.reference)))
                targets.append(TimelineSnapTarget(frame: layout.endFrame, kind: .clipEdge(layout.reference)))
            }
            for item in track.items {
                guard case .clip(let clip) = item else { continue }
                let reference = TimelineClipReference(trackID: track.id, clipID: clip.id)
                for parameter in ClipTransformParameter.allCases {
                    for point in TransformKeyframeLookup.keyframes(
                        parameter: parameter,
                        in: clip.transformAnimation,
                        frameRate: sequence.timebase,
                        pixelsPerFrame: 1
                    ) {
                        targets.append(TimelineSnapTarget(frame: point.frame, kind: .keyframe(reference)))
                    }
                }
            }
        }
        return targets
    }

    static func snappedFrame(
        proposedFrame: Int64,
        targets: [TimelineSnapTarget],
        toleranceFrames: Int64
    ) -> Int64 {
        var nearestFrame = proposedFrame
        var nearestDistance = max(0, toleranceFrames) + 1

        for target in targets {
            let distance = abs(target.frame - proposedFrame)
            if distance <= toleranceFrames,
               distance < nearestDistance
                   || (distance == nearestDistance && target.frame < nearestFrame)
            {
                nearestDistance = distance
                nearestFrame = target.frame
            }
        }

        return nearestFrame
    }

    static func selectedFrameRange(
        in sequence: Sequence,
        selectedClips: Set<TimelineClipReference>
    ) -> TimelineFrameRange? {
        let layouts = (sequence.videoTracks + sequence.audioTracks)
            .flatMap { clipLayouts(for: $0, frameRate: sequence.timebase, pixelsPerFrame: 1.0) }
            .filter { selectedClips.contains($0.reference) }

        guard let firstLayout = layouts.first else {
            return nil
        }

        var startFrame = firstLayout.startFrame
        var endFrame = firstLayout.endFrame
        for layout in layouts.dropFirst() {
            startFrame = min(startFrame, layout.startFrame)
            endFrame = max(endFrame, layout.endFrame)
        }
        return TimelineFrameRange(startFrame: startFrame, endFrame: endFrame)
    }

    private static func clamped(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(max(minimum, value), maximum)
    }
}
