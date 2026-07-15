// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Chooses the launch welcome or the editing workspace and hosts document-level sheets/alerts.
struct EditorAjarRootView: View {
    @ObservedObject var model: EditorAjarAppModel
    let presentOpenPanel: () -> Void
    let openRecentProject: (URL) -> Void
    let shouldCloseWindow: () -> Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if model.project == nil {
                    EditorAjarWelcomeView(
                        model: model,
                        presentOpenPanel: presentOpenPanel,
                        openRecentProject: openRecentProject
                    )
                } else {
                    EditorAjarWorkspaceView(model: model)
                }
            }

            if model.isConsolidatingMedia {
                EditorAjarMediaConsolidationProgressView(model: model)
                    .padding(16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .frame(minWidth: 1_100, minHeight: 720)
        .sheet(isPresented: newProjectSheetPresented) {
            EditorAjarNewProjectSettingsView(model: model)
        }
        .alert(
            AppString.localized("document.error.title", "Project Error"),
            isPresented: documentErrorPresented
        ) {
            Button(AppString.localized("document.error.dismiss", "OK")) {
                model.dismissDocumentError()
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(model.documentErrorMessage ?? "")
        }
        .alert(
            AppString.localized(
                "document.warning.saveAsCleanup.title",
                "Project Saved with Cleanup Warning"
            ),
            isPresented: documentWarningPresented
        ) {
            Button(AppString.localized("document.warning.dismiss", "OK")) {
                model.dismissDocumentWarning()
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(model.documentWarningMessage ?? "")
        }
        .alert(
            AppString.localized("consolidate.summary.title", "Media Consolidation"),
            isPresented: mediaConsolidationSummaryPresented
        ) {
            Button(AppString.localized("consolidate.summary.dismiss", "OK")) {
                model.dismissMediaConsolidationSummary()
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(model.mediaConsolidationSummaryMessage ?? "")
        }
        .background(
            EditorAjarWindowStateBridge(
                title: model.documentDisplayName,
                representedURL: model.documentURL,
                isDocumentEdited: model.isDocumentDirty,
                shouldCloseWindow: shouldCloseWindow
            )
        )
    }

    private var newProjectSheetPresented: Binding<Bool> {
        Binding(
            get: { model.isNewProjectSheetPresented },
            set: { isPresented in
                if !isPresented {
                    model.dismissNewProjectSheet()
                }
            }
        )
    }

    private var documentErrorPresented: Binding<Bool> {
        Binding(
            get: { model.documentErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.dismissDocumentError()
                }
            }
        )
    }

    private var mediaConsolidationSummaryPresented: Binding<Bool> {
        Binding(
            get: { model.mediaConsolidationSummaryMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.dismissMediaConsolidationSummary()
                }
            }
        )
    }

    private var documentWarningPresented: Binding<Bool> {
        Binding(
            get: { model.documentWarningMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.dismissDocumentWarning()
                }
            }
        )
    }
}

/// Empty launch state for New/Open (FR-PROJ-001).
private struct EditorAjarWelcomeView: View {
    @ObservedObject var model: EditorAjarAppModel
    let presentOpenPanel: () -> Void
    let openRecentProject: (URL) -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "film.stack")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(AppString.localized("welcome.title", "Welcome to Editor Ajar"))
                    .font(.largeTitle.weight(.semibold))
                Text(AppString.localized(
                    "welcome.subtitle",
                    "Create a project or open an existing .ajar package."
                ))
                .font(.title3)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(AppString.localized("document.new.title", "New Project…")) {
                    model.presentNewProjectSheet()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: [.command])
                .help(AppString.localized(
                    "document.new.help",
                    "Create a project and choose its video and audio settings"
                ))
                .accessibilityLabel(AppString.localized(
                    "document.new.ax",
                    "Create a new project"
                ))
                .accessibilityIdentifier("Welcome New Project")

                Button(AppString.localized("document.open.title", "Open…")) {
                    presentOpenPanel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("o", modifiers: [.command])
                .help(AppString.localized(
                    "document.open.help",
                    "Open an Editor Ajar project package"
                ))
                .accessibilityLabel(AppString.localized(
                    "document.open.ax",
                    "Open an existing project"
                ))
                .accessibilityIdentifier("Welcome Open Project")
            }

            if !model.recentProjectURLs.isEmpty {
                recentProjects
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppString.localized(
            "welcome.ax",
            "Editor Ajar project welcome"
        ))
        .accessibilityIdentifier("Welcome View")
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppString.localized("document.openRecent.title", "Recent Projects"))
                .font(.headline)
            ForEach(Array(model.recentProjectURLs.prefix(5).enumerated()), id: \.element) {
                entry in
                let index = entry.offset
                let url = entry.element
                Button {
                    openRecentProject(url)
                } label: {
                    HStack {
                        Image(systemName: "doc")
                            .accessibilityHidden(true)
                        Text(url.deletingPathExtension().lastPathComponent)
                        Spacer()
                        Text(url.deletingLastPathComponent().path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppString.localized(
                    "document.openRecent.item.ax",
                    "Open recent project \(url.deletingPathExtension().lastPathComponent)"
                ))
                .accessibilityIdentifier("Recent Project \(index)")
            }
        }
        .frame(maxWidth: 560)
        .padding(.top, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppString.localized(
            "document.openRecent.ax",
            "Recent projects"
        ))
    }
}

/// New Project settings sheet (FR-PROJ-003).
private struct EditorAjarNewProjectSettingsView: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(AppString.localized("document.newSettings.title", "New Project"))
                .font(.title2.weight(.semibold))

            Form {
                Picker(
                    AppString.localized("document.newSettings.resolution", "Resolution"),
                    selection: $model.newProjectSettings.resolutionChoice
                ) {
                    ForEach(EditorAjarProjectResolutionChoice.allCases) { choice in
                        Text(choice.localizedName).tag(choice)
                    }
                }
                .accessibilityLabel(AppString.localized(
                    "document.newSettings.resolution.ax",
                    "Project resolution"
                ))
                .accessibilityIdentifier("Project Resolution")

                Picker(
                    AppString.localized("document.newSettings.frameRate", "Frame Rate"),
                    selection: $model.newProjectSettings.frameRateChoice
                ) {
                    ForEach(EditorAjarProjectFrameRateChoice.allCases) { choice in
                        Text(choice.localizedName).tag(choice)
                    }
                }
                .accessibilityLabel(AppString.localized(
                    "document.newSettings.frameRate.ax",
                    "Project frame rate"
                ))
                .accessibilityIdentifier("Project Frame Rate")

                Picker(
                    AppString.localized("document.newSettings.colorSpace", "Color Space"),
                    selection: $model.newProjectSettings.colorSpaceChoice
                ) {
                    ForEach(EditorAjarProjectColorSpaceChoice.allCases) { choice in
                        Text(choice.localizedName).tag(choice)
                    }
                }
                .accessibilityLabel(AppString.localized(
                    "document.newSettings.colorSpace.ax",
                    "Project color space"
                ))
                .accessibilityIdentifier("Project Color Space")

                Picker(
                    AppString.localized("document.newSettings.audioRate", "Audio Rate"),
                    selection: $model.newProjectSettings.audioRateChoice
                ) {
                    ForEach(EditorAjarProjectAudioRateChoice.allCases) { choice in
                        Text(choice.localizedName).tag(choice)
                    }
                }
                .accessibilityLabel(AppString.localized(
                    "document.newSettings.audioRate.ax",
                    "Project audio sample rate"
                ))
                .accessibilityIdentifier("Project Audio Sample Rate")
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(AppString.localized("document.newSettings.cancel", "Cancel")) {
                    model.dismissNewProjectSheet()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(AppString.localized(
                    "document.newSettings.cancel.ax",
                    "Cancel new project"
                ))
                .accessibilityIdentifier("Cancel New Project")

                Button(AppString.localized("document.newSettings.create", "Create")) {
                    createProject()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(AppString.localized(
                    "document.newSettings.create.ax",
                    "Create new project"
                ))
                .accessibilityIdentifier("Create New Project")
            }
        }
        .padding(24)
        .frame(width: 500)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppString.localized(
            "document.newSettings.ax",
            "New project settings"
        ))
        .accessibilityIdentifier("New Project Settings")
    }

    private func createProject() {
        do {
            try model.createNewProject(settings: model.newProjectSettings)
        } catch {
            model.presentDocumentError(error, operation: .create)
        }
    }
}

/// Bridges SwiftUI document state to native macOS title/represented URL/edited indicator.
struct EditorAjarWindowStateBridge: NSViewRepresentable {
    let title: String
    let representedURL: URL?
    let isDocumentEdited: Bool
    let shouldCloseWindow: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldCloseWindow: shouldCloseWindow)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let title = title
        let representedURL = representedURL
        let isDocumentEdited = isDocumentEdited
        let coordinator = context.coordinator
        coordinator.shouldCloseWindow = shouldCloseWindow
        DispatchQueue.main.async { [weak nsView, weak coordinator] in
            guard let window = nsView?.window else {
                return
            }
            coordinator?.install(on: window)
            window.title = title
            window.representedURL = representedURL
            window.isDocumentEdited = isDocumentEdited
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    /// Keeps SwiftUI's existing window delegate behavior while adding a document close gate.
    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldCloseWindow: () -> Bool

        private weak var window: NSWindow?
        private weak var forwardedDelegate: (any NSWindowDelegate)?

        init(shouldCloseWindow: @escaping () -> Bool) {
            self.shouldCloseWindow = shouldCloseWindow
        }

        func install(on window: NSWindow) {
            if window.delegate === self {
                return
            }
            uninstall()
            self.window = window
            forwardedDelegate = window.delegate
            window.delegate = self
        }

        func uninstall() {
            if window?.delegate === self {
                window?.delegate = forwardedDelegate
            }
            window = nil
            forwardedDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard forwardedDelegate?.windowShouldClose?(sender) != false else {
                return false
            }
            return shouldCloseWindow()
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if forwardedDelegate?.responds(to: selector) == true {
                return forwardedDelegate
            }
            return super.forwardingTarget(for: selector)
        }
    }
}
