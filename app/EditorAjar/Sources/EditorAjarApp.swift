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
        }
    }
}
