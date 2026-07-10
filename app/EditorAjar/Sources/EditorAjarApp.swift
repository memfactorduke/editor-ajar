// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct EditorAjarApp: App {
    @StateObject private var model: EditorAjarAppModel

    init() {
        _model = StateObject(
            wrappedValue: EditorAjarAppModel(
                autosavePackageURL: EditorAjarAppModel.defaultAutosavePackageURL()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            EditorAjarWorkspaceView(model: model)
                .frame(minWidth: 1_100, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
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
            CommandMenu("Sequences") {
                Button("New Sequence") {
                    model.addSequence()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Close Sequence") {
                    model.closeActiveSequence()
                }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(!model.canCloseActiveSequence)
            }
            CommandMenu("Markers") {
                Button("Add Marker") {
                    model.addTimelineMarkerAtPlayhead()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("Previous Marker") {
                    model.jumpToPreviousMarker()
                }
                .keyboardShortcut("[", modifiers: [.command])

                Button("Next Marker") {
                    model.jumpToNextMarker()
                }
                .keyboardShortcut("]", modifiers: [.command])

                Button("Delete Marker") {
                    model.deleteSelectedMarker()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.selectedMarker == nil)
            }
            CommandMenu("Clip") {
                Button("Copy Grade") {
                    model.copyGradeFromSelectedClip()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!model.canCopyGrade)
                .accessibilityLabel("Copy Grade from Selected Clip")

                Button("Paste Grade") {
                    model.pasteGradeToSelectedClip()
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!model.canPasteGrade)
                .accessibilityLabel("Paste Grade to Selected Clip")

                Divider()

                Button("Save Look") {
                    model.saveLookFromSelectedClip()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!model.canSaveLook)
                .accessibilityLabel("Save Look from Selected Clip")

                Menu("Apply Look") {
                    ForEach(model.savedLooks, id: \.id) { look in
                        Button(look.name) {
                            model.applyLookToSelectedClip(lookID: look.id)
                        }
                        .accessibilityLabel("Apply Look \(look.name)")
                    }
                }
                .disabled(!model.canApplyLook)
                .accessibilityLabel("Apply Look to Selected Clip")

                Divider()

                Button("Detach Audio") {
                    model.detachAudioForSelectedClip()
                }
                .disabled(!model.selectedClipIsLinked)
            }
        }
    }
}
