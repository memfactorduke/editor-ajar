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
        }
    }
}
