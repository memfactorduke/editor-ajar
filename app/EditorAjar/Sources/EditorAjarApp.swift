// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct EditorAjarApp: App {
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
            EditorAjarWorkspaceView(model: model)
                .frame(minWidth: 1_100, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(AppString.localized("menu.import.media", "Import Media…")) {
                    model.presentMediaImporter()
                }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(!model.canImportMedia)
                .accessibilityLabel(
                    AppString.localized("menu.import.media.ax", "Import media files or folders")
                )
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
                .keyboardShortcut("n", modifiers: [.command])
                .accessibilityLabel(AppString.localized("menu.sequences.new", "New Sequence"))

                Button(AppString.localized("menu.sequences.close", "Close Sequence")) {
                    model.closeActiveSequence()
                }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(!model.canCloseActiveSequence)
                .accessibilityLabel(AppString.localized("menu.sequences.close", "Close Sequence"))
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
                .disabled(model.selectedMarker == nil)
                .accessibilityLabel(AppString.localized("menu.markers.delete", "Delete Marker"))
            }
            CommandMenu(Text(AppString.localized("menu.clip.title", "Clip"))) {
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

                Button(AppString.localized("menu.clip.saveLook", "Save Look")) {
                    model.saveLookFromSelectedClip()
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

                Divider()

                Button(AppString.localized("menu.clip.detachAudio", "Detach Audio")) {
                    model.detachAudioForSelectedClip()
                }
                .disabled(!model.selectedClipIsLinked)
                .accessibilityLabel(
                    AppString.localized("menu.clip.detachAudio.ax", "Detach Audio from Selected Clip")
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
        }
    }
}
