// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import AjarCore
import SwiftUI
import UniformTypeIdentifiers

/// Adds the document save review that a custom SwiftUI window does not receive automatically.
final class EditorAjarApplicationDelegate: NSObject, NSApplicationDelegate {
    var shouldTerminate: (() -> Bool)?
    var prepareForTermination: (() async -> Void)?

    private var isPreparingTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shouldTerminate?() != false else {
            return .terminateCancel
        }
        guard let prepareForTermination else {
            return .terminateNow
        }
        guard !isPreparingTermination else {
            return .terminateLater
        }
        isPreparingTermination = true
        Task {
            await prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct EditorAjarApp: App {
    @NSApplicationDelegateAdaptor(EditorAjarApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var model: EditorAjarAppModel

    init() {
        let isRunningUISmoke = ProcessInfo.processInfo.environment["EDITOR_AJAR_UI_TESTING"] == "1"
        _model = StateObject(
            wrappedValue: EditorAjarAppModel(
                autosavePackageURL: isRunningUISmoke
                    ? nil
                    : EditorAjarAppModel.defaultAutosavePackageURL()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            EditorAjarRootView(
                model: model,
                presentOpenPanel: presentOpenPanel,
                openRecentProject: openRecentProject,
                shouldCloseWindow: shouldCloseCurrentDocument
            )
            .onAppear {
                applicationDelegate.shouldTerminate = shouldCloseCurrentDocument
                applicationDelegate.prepareForTermination = {
                    await model.finishPendingDocumentWrites()
                }
            }
            .onOpenURL { url in
                prepareForDocumentReplacement {
                    openRecentProject(url)
                }
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(AppString.localized("document.new.title", "New Project…")) {
                    prepareForDocumentReplacement {
                        model.presentNewProjectSheet()
                    }
                }
                .keyboardShortcut("n", modifiers: [.command])
                .accessibilityLabel(AppString.localized(
                    "document.new.ax",
                    "Create a new project"
                ))

                Button(AppString.localized("document.open.title", "Open…")) {
                    prepareForDocumentReplacement {
                        presentOpenPanel()
                    }
                }
                .keyboardShortcut("o", modifiers: [.command])
                .accessibilityLabel(AppString.localized(
                    "document.open.ax",
                    "Open an existing project"
                ))

                Menu(AppString.localized("document.openRecent.title", "Recent Projects")) {
                    if model.recentProjectURLs.isEmpty {
                        Text(AppString.localized(
                            "document.openRecent.empty",
                            "No Recent Projects"
                        ))
                    } else {
                        ForEach(model.recentProjectURLs, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                prepareForDocumentReplacement {
                                    openRecentProject(url)
                                }
                            }
                            .accessibilityLabel(AppString.localized(
                                "document.openRecent.item.ax",
                                "Open recent project \(url.deletingPathExtension().lastPathComponent)"
                            ))
                        }
                    }
                }
                .accessibilityLabel(AppString.localized(
                    "document.openRecent.ax",
                    "Recent projects"
                ))

                Button(AppString.localized("menu.import.media", "Import Media…")) {
                    model.presentMediaImporter()
                }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(!model.canImportMedia)
                .accessibilityLabel(
                    AppString.localized("menu.import.media.ax", "Import media files or folders")
                )
            }
            CommandGroup(replacing: .saveItem) {
                Button(AppString.localized("document.save.title", "Save")) {
                    _ = saveCurrentProject()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!model.canSaveProject)
                .accessibilityLabel(AppString.localized(
                    "document.save.ax",
                    "Save project"
                ))

                Button(AppString.localized("document.saveAs.title", "Save As…")) {
                    _ = presentSavePanel()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.canSaveProjectAs)
                .accessibilityLabel(AppString.localized(
                    "document.saveAs.ax",
                    "Save project as"
                ))

                Button(AppString.localized("document.revert.title", "Revert to Saved")) {
                    confirmAndRevertProject()
                }
                .disabled(!model.canRevertProject)
                .accessibilityLabel(AppString.localized(
                    "document.revert.ax",
                    "Revert project to its last saved version"
                ))
            }
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoMenuTitle) {
                    model.undo()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!model.canUndo)
                .accessibilityLabel(model.undoMenuTitle)

                Button(model.redoMenuTitle) {
                    model.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
                .accessibilityLabel(model.redoMenuTitle)
            }
            CommandMenu(Text(AppString.localized("menu.sequences.title", "Sequences"))) {
                Button(AppString.localized("menu.sequences.new", "New Sequence")) {
                    model.addSequence()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .accessibilityLabel(AppString.localized("menu.sequences.new", "New Sequence"))

                Button(AppString.localized("menu.sequences.close", "Close Sequence")) {
                    model.closeActiveSequence()
                }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(!model.canCloseActiveSequence)
                .accessibilityLabel(AppString.localized("menu.sequences.close", "Close Sequence"))

                Divider()
                Button(AppString.localized("menu.sequences.addVideoTrack", "Add Video Track")) {
                    model.addTrack(kind: .video)
                }
                Button(AppString.localized("menu.sequences.addAudioTrack", "Add Audio Track")) {
                    model.addTrack(kind: .audio)
                }
                Button(AppString.localized("menu.sequences.removeTrack", "Remove Selected Empty Track")) {
                    model.removeSelectedEmptyTrack()
                }
            }
            CommandMenu(Text(AppString.localized("menu.markers.title", "Markers"))) {
                Button(AppString.localized("menu.markers.add", "Add Marker")) {
                    model.addTimelineMarkerAtPlayhead()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .accessibilityLabel(AppString.localized("menu.markers.add", "Add Marker"))

                Button(AppString.localized("menu.markers.previous", "Previous Marker")) {
                    model.jumpToPreviousMarker()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .accessibilityLabel(AppString.localized("menu.markers.previous", "Previous Marker"))

                Button(AppString.localized("menu.markers.next", "Next Marker")) {
                    model.jumpToNextMarker()
                }
                .keyboardShortcut("]", modifiers: [.command])
                .accessibilityLabel(AppString.localized("menu.markers.next", "Next Marker"))

                Button(AppString.localized("menu.markers.delete", "Delete Marker")) {
                    model.deleteSelectedMarker()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                // Disabled while text editing so ⌘⌫ deletes text, not the marker being renamed.
                .disabled(model.selectedMarker == nil || model.isTextEditingActive)
                .accessibilityLabel(AppString.localized("menu.markers.delete", "Delete Marker"))
            }
            // #245 playback commands. Modifier-less letter keys (J/K/L) are gated while text
            // editing so they reach the field editor instead of the shuttle.
            CommandMenu(Text(AppString.localized("menu.playback.title", "Playback"))) {
                Button(AppString.localized("playback.shuttle.reverse", "Shuttle Reverse")) {
                    model.shuttleBackward()
                }
                .keyboardShortcut("j", modifiers: [])
                .disabled(model.isTextEditingActive)
                .accessibilityLabel(AppString.localized("playback.shuttle.reverse", "Shuttle Reverse"))

                Button(AppString.localized("playback.shuttle.pause", "Shuttle Pause")) {
                    model.shuttlePause()
                }
                .keyboardShortcut("k", modifiers: [])
                .disabled(model.isTextEditingActive)
                .accessibilityLabel(AppString.localized("playback.shuttle.pause", "Shuttle Pause"))

                Button(AppString.localized("playback.shuttle.forward", "Shuttle Forward")) {
                    model.shuttleForward()
                }
                .keyboardShortcut("l", modifiers: [])
                .disabled(model.isTextEditingActive)
                .accessibilityLabel(AppString.localized("playback.shuttle.forward", "Shuttle Forward"))

                Divider()
                Button(AppString.localized("playback.loop.toggle", "Loop In/Out Range")) {
                    model.toggleLoopRange()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .accessibilityLabel(AppString.localized("playback.loop.toggle", "Loop In/Out Range"))

                Button(AppString.localized("playback.jump.in", "Jump to In")) { model.jumpToRangeIn() }
                    .keyboardShortcut("i", modifiers: [.option])
                Button(AppString.localized("playback.jump.out", "Jump to Out")) { model.jumpToRangeOut() }
                    .keyboardShortcut("o", modifiers: [.option])
                Button(AppString.localized("playback.jump.previousEdit", "Previous Edit Point")) {
                    model.jumpToPreviousEditPoint()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button(AppString.localized("playback.jump.nextEdit", "Next Edit Point")) {
                    model.jumpToNextEditPoint()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button(AppString.localized("playback.jump.start", "Jump to Start")) { model.jumpToStart() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                Button(AppString.localized("playback.jump.end", "Jump to End")) { model.jumpToEnd() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])

                Divider()
                Button(AppString.localized("playback.checkerboard.toggle", "Toggle Alpha Checkerboard")) {
                    model.toggleCheckerboardAlpha()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                Button(AppString.localized("playback.fullScreen.toggle", "Toggle Program Monitor Full Screen")) {
                    model.toggleProgramMonitorFullScreen()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }
            // Clip commands disable while a text editor is focused (#240 review): a disabled
            // menu item does not consume its key equivalent, so typing (E, [, ], ⌫) and native
            // clipboard shortcuts (⌘C/⌘X/⌘V) reach the text field instead of the timeline.
            // Union: #240 timeline editing + #245 speed/reverse/freeze + existing grade/look.
            CommandMenu(Text(AppString.localized("menu.clip.title", "Clip"))) {
                Button(AppString.localized("menu.clip.blade", "Blade at Playhead")) {
                    model.bladeSelectedClipAtPlayhead()
                }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.rippleDelete", "Ripple Delete")) {
                    model.rippleDeleteSelection()
                }
                .keyboardShortcut(.delete, modifiers: [.shift])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.lift", "Lift")) {
                    model.liftSelection()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.copy", "Copy Clips")) {
                    model.copyTimelineClips()
                }
                .keyboardShortcut("c", modifiers: [.command])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.cut", "Cut Clips")) {
                    model.cutTimelineClips()
                }
                .keyboardShortcut("x", modifiers: [.command])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.paste", "Paste Clips")) {
                    model.pasteTimelineClips()
                }
                .keyboardShortcut("v", modifiers: [.command])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.trimStart", "Trim Start to Playhead")) {
                    model.trimSelectedClipToPlayhead(edge: .leading)
                }
                .keyboardShortcut("[", modifiers: [])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.trimEnd", "Trim End to Playhead")) {
                    model.trimSelectedClipToPlayhead(edge: .trailing)
                }
                .keyboardShortcut("]", modifiers: [])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.slipEarlier", "Slip Clip Earlier One Frame")) {
                    model.slipSelectedClip(byFrames: -1)
                }
                .keyboardShortcut("[", modifiers: [.option])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.slipLater", "Slip Clip Later One Frame")) {
                    model.slipSelectedClip(byFrames: 1)
                }
                .keyboardShortcut("]", modifiers: [.option])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.slideEarlier", "Slide Clip Earlier One Frame")) {
                    model.slideSelectedClip(byFrames: -1)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.slideLater", "Slide Clip Later One Frame")) {
                    model.slideSelectedClip(byFrames: 1)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.selectForward", "Select Forward from Playhead")) {
                    model.selectForwardFromPlayhead()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.isTextEditingActive)
                Divider()
                Button(AppString.localized("menu.clip.insert", "Insert Selected Media")) {
                    model.editSelectedMedia(.insert)
                }
                .keyboardShortcut(KeyEquivalent("\u{F70C}"), modifiers: [])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.overwrite", "Overwrite with Selected Media")) {
                    model.editSelectedMedia(.overwrite)
                }
                .keyboardShortcut(KeyEquivalent("\u{F70D}"), modifiers: [])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.append", "Append Selected Media")) {
                    model.editSelectedMedia(.append)
                }
                .keyboardShortcut("e", modifiers: [])
                .disabled(model.isTextEditingActive)
                Button(AppString.localized("menu.clip.replace", "Replace with Selected Media")) {
                    model.editSelectedMedia(.replace)
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.isTextEditingActive)
                Button(
                    AppString.localized(
                        "menu.clip.threePointInsert", "Three-Point Insert (Fit Marks)"
                    )
                ) {
                    model.performThreePointEdit(mode: .insert)
                }
                .keyboardShortcut(KeyEquivalent("\u{F70C}"), modifiers: [.shift])
                .disabled(!model.canPerformThreePointEdit)
                .accessibilityLabel(
                    AppString.localized(
                        "menu.clip.threePointInsert.ax", "Three-Point Insert Fit to Marks"
                    )
                )
                Button(
                    AppString.localized(
                        "menu.clip.threePointOverwrite", "Three-Point Overwrite (Fit Marks)"
                    )
                ) {
                    model.performThreePointEdit(mode: .overwrite)
                }
                .keyboardShortcut(KeyEquivalent("\u{F70D}"), modifiers: [.shift])
                .disabled(!model.canPerformThreePointEdit)
                .accessibilityLabel(
                    AppString.localized(
                        "menu.clip.threePointOverwrite.ax", "Three-Point Overwrite Fit to Marks"
                    )
                )
                Divider()
                Menu(AppString.localized("menu.clip.speed", "Speed")) {
                    Button(AppString.localized("menu.clip.speed.half", "50%")) {
                        _ = model.updateSelectedClipSpeed(percentText: "50")
                    }
                    Button(AppString.localized("menu.clip.speed.normal", "100%")) {
                        _ = model.updateSelectedClipSpeed(percentText: "100")
                    }
                    Button(AppString.localized("menu.clip.speed.double", "200%")) {
                        _ = model.updateSelectedClipSpeed(percentText: "200")
                    }
                }
                .disabled(model.selectedClip == nil)

                Button(
                    model.selectedClip?.reverse == true
                        ? AppString.localized("menu.clip.reverse.disable", "Disable Reverse")
                        : AppString.localized("menu.clip.reverse.enable", "Enable Reverse")
                ) {
                    _ = model.setSelectedClipReverse(!(model.selectedClip?.reverse ?? false))
                }
                .disabled(model.selectedClip == nil)

                Button(
                    model.selectedClip?.freezeFrame == true
                        ? AppString.localized("menu.clip.freeze.disable", "Disable Freeze Frame")
                        : AppString.localized("menu.clip.freeze.enable", "Enable Freeze Frame")
                ) {
                    _ = model.setSelectedClipFreezeFrame(!(model.selectedClip?.freezeFrame ?? false))
                }
                .disabled(model.selectedClip == nil)

                Divider()
                Button(AppString.localized("menu.clip.copyGrade", "Copy Grade")) {
                    model.copyGradeFromSelectedClip()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!model.canCopyGrade)
                .accessibilityLabel(
                    AppString.localized("menu.clip.copyGrade.ax", "Copy Grade from Selected Clip")
                )

                Button(AppString.localized("menu.clip.pasteGrade", "Paste Grade")) {
                    model.pasteGradeToSelectedClip()
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!model.canPasteGrade)
                .accessibilityLabel(
                    AppString.localized("menu.clip.pasteGrade.ax", "Paste Grade to Selected Clip")
                )

                Divider()

                Button(AppString.localized("menu.clip.saveLook", "Save Look…")) {
                    model.presentSaveLookSheet()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!model.canSaveLook)
                .accessibilityLabel(
                    AppString.localized("menu.clip.saveLook.ax", "Save Look from Selected Clip")
                )

                Menu(AppString.localized("menu.clip.applyLook", "Apply Look")) {
                    ForEach(model.savedLooks, id: \.id) { look in
                        Button(look.name) {
                            model.applyLookToSelectedClip(lookID: look.id)
                        }
                        .accessibilityLabel(
                            AppString.localized("menu.clip.applyLook.item", "Apply Look \(look.name)")
                        )
                    }
                }
                .disabled(!model.canApplyLook)
                .accessibilityLabel(
                    AppString.localized("menu.clip.applyLook.ax", "Apply Look to Selected Clip")
                )

                Button(AppString.localized("menu.clip.importLUT", "Import LUT…")) {
                    model.presentLUTImporter()
                }
                .disabled(!model.canImportLUT)
                .accessibilityLabel(
                    AppString.localized("menu.clip.importLUT.ax", "Import cube LUT for Selected Clip")
                )

                Divider()

                Button(
                    model.isScopesPanelVisible
                        ? AppString.localized("menu.clip.hideScopes", "Hide Scopes")
                        : AppString.localized("menu.clip.showScopes", "Show Scopes")
                ) {
                    model.toggleScopesPanel()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .accessibilityLabel(
                    model.isScopesPanelVisible
                        ? AppString.localized("menu.clip.hideScopes", "Hide Scopes")
                        : AppString.localized("menu.clip.showScopes", "Show Scopes")
                )

                Divider()

                Button(AppString.localized("menu.clip.detachAudio", "Detach Audio")) {
                    model.detachAudioForSelectedClip()
                }
                .disabled(!model.selectedClipIsLinked)
                .accessibilityLabel(
                    AppString.localized("menu.clip.detachAudio.ax", "Detach Audio from Selected Clip")
                )

                Divider()

                Button(AppString.localized("menu.clip.fadeIn", "Apply Fade In")) {
                    _ = model.applyDefaultFadeInToSelectedAudioClip()
                }
                .disabled(model.selectedClip?.kind != .audio)
                .accessibilityLabel(
                    AppString.localized("menu.clip.fadeIn.ax", "Apply default fade in to audio clip")
                )

                Button(AppString.localized("menu.clip.fadeOut", "Apply Fade Out")) {
                    _ = model.applyDefaultFadeOutToSelectedAudioClip()
                }
                .disabled(model.selectedClip?.kind != .audio)
                .accessibilityLabel(
                    AppString.localized(
                        "menu.clip.fadeOut.ax",
                        "Apply default fade out to audio clip"
                    )
                )

                Button(AppString.localized("menu.clip.crossfade", "Add Crossfade")) {
                    _ = model.addCrossfadeAfterSelectedAudioClip()
                }
                .disabled(!model.canAddCrossfadeAfterSelectedAudioClip)
                .accessibilityLabel(
                    AppString.localized(
                        "menu.clip.crossfade.ax",
                        "Add audio crossfade after selected clip"
                    )
                )

                Button(AppString.localized("menu.clip.removeCrossfade", "Remove Crossfade")) {
                    _ = model.removeCrossfadeFromSelectedAudioClip()
                }
                .disabled(!model.selectedClipHasTrailingCrossfade)
                .accessibilityLabel(
                    AppString.localized(
                        "menu.clip.removeCrossfade.ax",
                        "Remove audio crossfade after selected clip"
                    )
                )
            }
            // Audio/Title/Export/Help are nested so `.commands` stays within
            // CommandsBuilder's 10-child limit (extra CommandMenus would otherwise
            // surface as "extra argument in call" on the 11th item).
            EditorAjarTrailingCommands(model: model) {
                prepareForDocumentReplacement {
                    do {
                        try model.openSampleProject()
                    } catch {
                        model.presentDocumentError(error, operation: .sample)
                    }
                }
            }
        }
    }

    private var ajarContentType: UTType {
        UTType(filenameExtension: "ajar", conformingTo: .package) ?? .package
    }

    private func prepareForDocumentReplacement(_ action: () -> Void) {
        guard confirmUnsavedChangesIfNeeded(authorizingReplacement: true) else {
            return
        }
        action()
    }

    private func shouldCloseCurrentDocument() -> Bool {
        confirmUnsavedChangesIfNeeded(authorizingReplacement: false)
    }

    private func confirmUnsavedChangesIfNeeded(authorizingReplacement: Bool) -> Bool {
        guard model.isDocumentDirty else {
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppString.localized(
            "document.unsavedChanges.title",
            "Save changes before continuing?"
        )
        alert.informativeText = AppString.localized(
            "document.unsavedChanges.message",
            "Your unsaved project changes will be lost if you continue without saving."
        )
        alert.addButton(withTitle: AppString.localized(
            "document.unsavedChanges.save",
            "Save"
        ))
        alert.addButton(withTitle: AppString.localized(
            "document.unsavedChanges.cancel",
            "Cancel"
        ))
        alert.addButton(withTitle: AppString.localized(
            "document.unsavedChanges.discard",
            "Discard Changes"
        ))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveCurrentProject()
        case .alertThirdButtonReturn:
            if authorizingReplacement {
                model.authorizeDiscardForNextDocumentReplacement()
            } else {
                model.discardUnsavedChangesForClosing()
            }
            return true
        default:
            model.cancelDocumentReplacementAuthorization()
            return false
        }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = AppString.localized("document.open.panelTitle", "Open Project")
        panel.prompt = AppString.localized("document.open.panelAction", "Open")
        panel.allowedContentTypes = [ajarContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else {
            model.cancelDocumentReplacementAuthorization()
            return
        }
        openRecentProject(url)
    }

    private func openRecentProject(_ url: URL) {
        do {
            try model.openRecentProject(at: url)
        } catch {
            model.presentDocumentError(error, operation: .open)
        }
    }

    @discardableResult
    private func saveCurrentProject() -> Bool {
        if model.documentURL == nil {
            return presentSavePanel()
        }
        do {
            try model.saveProject()
            return true
        } catch {
            model.presentDocumentError(error, operation: .save)
            return false
        }
    }

    @discardableResult
    private func presentSavePanel() -> Bool {
        let panel = NSSavePanel()
        panel.title = AppString.localized("document.saveAs.panelTitle", "Save Project")
        panel.prompt = AppString.localized("document.saveAs.panelAction", "Save")
        panel.allowedContentTypes = [ajarContentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(model.documentDisplayName).ajar"
        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }
        do {
            try model.saveProjectAs(to: url)
            return true
        } catch {
            model.presentDocumentError(error, operation: .save)
            return false
        }
    }

    private func confirmAndRevertProject() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppString.localized(
            "document.revertConfirm.title",
            "Revert to the last saved version?"
        )
        alert.informativeText = AppString.localized(
            "document.revertConfirm.message",
            "All changes since the last save will be discarded."
        )
        alert.addButton(withTitle: AppString.localized(
            "document.revertConfirm.action",
            "Revert"
        ))
        alert.addButton(withTitle: AppString.localized(
            "document.revertConfirm.cancel",
            "Cancel"
        ))
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        do {
            try model.revertProject()
        } catch {
            model.presentDocumentError(error, operation: .revert)
        }
    }
}

/// Audio / Title / Export / Help menus, factored out so the app's `.commands`
/// builder stays within `CommandsBuilder`'s 10-child arity limit.
private struct EditorAjarTrailingCommands: Commands {
    @ObservedObject var model: EditorAjarAppModel
    let openSampleProject: () -> Void

    var body: some Commands {
        CommandMenu(Text(AppString.localized("menu.audio.title", "Audio"))) {
            Button(
                model.isMixerPanelVisible
                    ? AppString.localized("menu.audio.hideMixer", "Hide Mixer")
                    : AppString.localized("menu.audio.showMixer", "Show Mixer")
            ) {
                model.toggleMixerPanel()
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
            .accessibilityLabel(
                model.isMixerPanelVisible
                    ? AppString.localized("menu.audio.hideMixer.ax", "Hide audio mixer")
                    : AppString.localized("menu.audio.showMixer.ax", "Show audio mixer")
            )
        }
        // FR-TXT-003: menu/keyboard paths for headless UI-smoke (same pattern as Undo).
        CommandMenu(Text(AppString.localized("menu.title.title", "Title"))) {
            Button(AppString.localized("menu.title.edit", "Edit Canvas Title")) {
                model.editPrimaryCanvasTitleBox()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(model.primaryCanvasTitleBoxReference == nil)
            .accessibilityLabel(AppString.localized("menu.title.edit", "Edit Canvas Title"))

            Button(AppString.localized("menu.title.nudgeRight", "Nudge Title Right")) {
                model.nudgePrimaryCanvasTitleBox(direction: .right, largeStep: true)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(model.primaryCanvasTitleBoxReference == nil)
            .accessibilityLabel(
                AppString.localized("menu.title.nudgeRight.ax", "Nudge Canvas Title Right")
            )

            Button(AppString.localized("menu.title.nudgeDown", "Nudge Title Down")) {
                model.nudgePrimaryCanvasTitleBox(direction: .down, largeStep: true)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(model.primaryCanvasTitleBoxReference == nil)
            .accessibilityLabel(
                AppString.localized("menu.title.nudgeDown.ax", "Nudge Canvas Title Down")
            )
        }
        CommandMenu(Text(AppString.localized("menu.export.title", "Export"))) {
            Button(AppString.localized("menu.export.open", "Export…")) {
                model.presentExportDialog()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .accessibilityLabel(AppString.localized("menu.export.open.ax", "Open export dialog"))

            Button(AppString.localized("menu.export.enqueue", "Export Active Sequence")) {
                model.enqueueActiveSequenceExport()
            }
            // ⌘⇧E is the export dialog; enqueue uses ⌘⌃⇧E to avoid collision.
            .keyboardShortcut("e", modifiers: [.command, .control, .shift])
            .accessibilityLabel(
                AppString.localized("menu.export.enqueue", "Export Active Sequence")
            )

            Button(
                model.isExportQueuePanelVisible
                    ? AppString.localized("menu.export.hideQueue", "Hide Export Queue")
                    : AppString.localized("menu.export.showQueue", "Show Export Queue")
            ) {
                model.toggleExportQueuePanel()
            }
            .keyboardShortcut("e", modifiers: [.command, .control])
            .accessibilityLabel(
                model.isExportQueuePanelVisible
                    ? AppString.localized("menu.export.hideQueue", "Hide Export Queue")
                    : AppString.localized("menu.export.showQueue", "Show Export Queue")
            )
        }
        CommandGroup(after: .help) {
            Button(AppString.localized(
                "help.openSampleProject.title",
                "Open Sample Project"
            )) {
                openSampleProject()
            }
            .accessibilityLabel(AppString.localized(
                "help.openSampleProject.ax",
                "Open the Editor Ajar sample project"
            ))
        }
    }
}
