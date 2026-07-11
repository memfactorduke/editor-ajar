// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorAjarWorkspaceView: View {
    @ObservedObject var model: EditorAjarAppModel
    @State private var isMediaDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isReadOnlyBannerVisible {
                ReadOnlyProjectBanner(model: model)
            }
            header
            SequenceTabsBar(model: model)
            Divider()
            HStack(spacing: 0) {
                LibraryPanel(model: model)
                    .frame(width: 240)
                Divider()
                VStack(spacing: 0) {
                    ProgramMonitor(model: model)
                    TransportBar(model: model)
                }
                Divider()
                InspectorPanel(model: model)
                    .frame(width: 280)
            }
            .frame(maxHeight: .infinity)
            Divider()
            TimelineView(model: model)
                .frame(height: 250)
                .dropDestination(for: String.self) { values, _ in
                    guard let value = values.first, let mediaID = UUID(uuidString: value) else {
                        return false
                    }
                    return model.insertMediaOnTimeline(mediaID: mediaID)
                }
            if model.isExportQueuePanelVisible {
                Divider()
                ExportQueuePanel(
                    model: model,
                    controller: model.exportQueueController
                )
                .frame(height: 180)
            }
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.11))
        .foregroundStyle(.white)
        .sheet(isPresented: exportSheetPresented) {
            EditorAjarExportDialogView(model: model)
        }
        .sheet(isPresented: importSummaryPresented) {
            EditorAjarMediaImportSummaryView(model: model)
        }
        .fileImporter(
            isPresented: importPickerPresented,
            allowedContentTypes: [.data, .folder],
            allowsMultipleSelection: true,
            onCompletion: model.handleMediaImporterResult
        )
        .fileImporter(
            isPresented: relinkPickerPresented,
            allowedContentTypes: [.data, .movie, .audio, .image],
            allowsMultipleSelection: false
        ) { result in
            // Guard empty selection — never invent a path (L4).
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                model.handleRelinkerResult(.success(url))
            case .failure(let error):
                model.handleRelinkerResult(.failure(error))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canImportMedia, !urls.isEmpty else {
                return false
            }
            model.importMedia(from: urls)
            return true
        } isTargeted: { targeted in
            isMediaDropTargeted = targeted
        }
        .overlay {
            if isMediaDropTargeted && model.canImportMedia {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var exportSheetPresented: Binding<Bool> {
        Binding(
            get: { model.exportDialog.isPresented },
            set: { presented in
                if presented {
                    model.presentExportDialog()
                } else {
                    model.dismissExportDialog()
                }
            }
        )
    }

    private var importPickerPresented: Binding<Bool> {
        Binding(
            get: { model.isMediaImportPickerPresented },
            set: { presented in
                if presented {
                    model.presentMediaImporter()
                } else {
                    model.dismissMediaImporter()
                }
            }
        )
    }

    private var importSummaryPresented: Binding<Bool> {
        Binding(
            get: { model.isMediaImportSummaryPresented },
            set: { presented in
                if !presented {
                    model.dismissMediaImportSummary()
                }
            }
        )
    }

    private var relinkPickerPresented: Binding<Bool> {
        Binding(
            get: { model.mediaIDAwaitingRelink != nil },
            set: { if !$0 { model.dismissRelinker() } }
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(AppString.localized("app.name", "Editor Ajar"))
                .font(.headline)
            Spacer()
            Text(model.projectSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
            proxyPlaybackToggle
            Button(AppString.localized("workspace.header.export", "Export…")) {
                model.presentExportDialog()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .accessibilityLabel(AppString.localized("menu.export.open.ax", "Open export dialog"))
            .accessibilityIdentifier("Open Export Dialog")
            Button(
                model.isExportQueuePanelVisible
                    ? AppString.localized("workspace.header.hideExports", "Hide Exports")
                    : AppString.localized("workspace.header.exports", "Exports")
            ) {
                model.toggleExportQueuePanel()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("e", modifiers: [.command, .control])
            .help(AppString.localized(
                "workspace.header.exports.help", "Show or hide the background export queue"
            ))
            .accessibilityLabel(
                model.isExportQueuePanelVisible
                    ? AppString.localized("workspace.header.hideQueue.ax", "Hide export queue")
                    : AppString.localized("workspace.header.showQueue.ax", "Show export queue")
            )
            .accessibilityIdentifier("Toggle Export Queue")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppString.localized("workspace.header.ax", "Editor Ajar, \(model.projectSummary)")
        )
    }

    /// One-click proxy/original playback toggle (FR-MED-004).
    private var proxyPlaybackToggle: some View {
        Button(
            model.preferProxyPlayback
                ? AppString.localized("workspace.proxyToggle.proxy", "Proxy")
                : AppString.localized("workspace.proxyToggle.original", "Original")
        ) {
            model.togglePreferProxyPlayback()
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("p", modifiers: [.command, .option])
        .help(
            model.preferProxyPlayback
                ? AppString.localized(
                    "workspace.proxyToggle.proxy.help",
                    "Playback uses proxy media when ready. Export always uses originals."
                )
                : AppString.localized(
                    "workspace.proxyToggle.original.help",
                    "Playback uses original media. Turn on for faster scrubbing of heavy media."
                )
        )
        .accessibilityLabel(
            model.preferProxyPlayback
                ? AppString.localized("workspace.proxyToggle.proxyOn.ax", "Proxy playback on")
                : AppString.localized("workspace.proxyToggle.originalOn.ax", "Original playback on")
        )
        .accessibilityHint(AppString.localized(
            "workspace.proxyToggle.hint",
            "Toggles timeline playback between optimized proxy media and originals. Export always uses originals."
        ))
        .accessibilityValue(
            model.preferProxyPlayback
                ? AppString.localized("workspace.proxyToggle.proxy", "Proxy")
                : AppString.localized("workspace.proxyToggle.original", "Original")
        )
        .accessibilityIdentifier("Toggle Proxy Playback")
        .accessibilityAddTraits(.isButton)
    }
}

/// Workspace banner for FR-PROJ-005 read-only opens (higher schema minor / ADR-0018).
private struct ReadOnlyProjectBanner: View {
    @ObservedObject var model: EditorAjarAppModel

    private var message: String {
        model.readOnlyBannerMessage
            ?? AppString.localized("banner.readOnly.fallback", "This project is open read-only.")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.orange)
                .accessibilityHidden(true)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(AppString.localized("banner.readOnly.title", "Read-only project"))
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(AppString.localized("banner.readOnly.dismiss", "Dismiss")) {
                model.dismissReadOnlyBanner()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .help(AppString.localized("banner.readOnly.dismiss.help", "Dismiss read-only notice"))
            .accessibilityLabel(
                AppString.localized("banner.readOnly.dismiss.ax", "Dismiss read-only project notice")
            )
            .accessibilityIdentifier("Dismiss Read-Only Banner")
            .accessibilityHint(AppString.localized(
                "banner.readOnly.dismiss.hint",
                "Hides the read-only banner. Editing and saving remain disabled."
            ))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.18))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Read-Only Project Banner")
        .accessibilityLabel(AppString.localized("banner.readOnly.notice.ax", "Read-only project notice"))
        .accessibilityValue(message)
        .accessibilityAddTraits(.isStaticText)
    }
}

private struct SequenceTabsBar: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.sequenceTabs) { tab in
                        SequenceTabButton(tab: tab, model: model)
                    }
                }
                .padding(.horizontal, 12)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Sequence tabs")
            .accessibilityLabel(AppString.localized("sequenceTabs.list.ax", "Sequence tabs"))

            Button {
                model.addSequence()
            } label: {
                Label(AppString.localized("sequenceTabs.new", "New Sequence"), systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .frame(width: 30, height: 28)
            .help(AppString.localized("sequenceTabs.new", "New Sequence"))
            .accessibilityLabel(AppString.localized("sequenceTabs.new", "New Sequence"))
            .accessibilityIdentifier("New Sequence")

            Button {
                model.closeActiveSequence()
            } label: {
                Label(
                    AppString.localized("sequenceTabs.close", "Close Sequence"), systemImage: "xmark"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .frame(width: 30, height: 28)
            .help(AppString.localized("sequenceTabs.close", "Close Sequence"))
            .accessibilityLabel(AppString.localized("sequenceTabs.close", "Close Sequence"))
            .accessibilityIdentifier("Close Sequence")
            .disabled(!model.canCloseActiveSequence)
        }
        .padding(.trailing, 12)
        .frame(height: 38)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Sequence tab bar")
        .accessibilityLabel(AppString.localized("sequenceTabs.bar.ax", "Sequence tab bar"))
    }
}

private struct SequenceTabButton: View {
    let tab: SequenceTab
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.selectSequence(tab.id)
            } label: {
                Text(tab.title)
                    .font(.caption.weight(tab.isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(minWidth: 104, maxWidth: 170, alignment: .leading)
                    .padding(.leading, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .help(tab.title)
            .accessibilityLabel(AppString.localized("sequenceTabs.tab.ax", "Sequence tab \(tab.title)"))
            .accessibilityValue(
                tab.isActive
                    ? AppString.localized("state.selected", "Selected")
                    : AppString.localized("state.notSelected", "Not selected")
            )
            .accessibilityIdentifier("Sequence tab \(tab.title)")

            Button {
                model.closeSequence(tab.id)
            } label: {
                Label(
                    AppString.localized("sequenceTabs.tab.close", "Close \(tab.title)"),
                    systemImage: "xmark"
                )
                .labelStyle(.iconOnly)
                .font(.caption2.weight(.semibold))
                .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(AppString.localized("sequenceTabs.tab.close", "Close \(tab.title)"))
            .accessibilityLabel(AppString.localized("sequenceTabs.tab.close", "Close \(tab.title)"))
            .accessibilityIdentifier("Close \(tab.title)")
            .disabled(!tab.canClose)
            .padding(.trailing, 6)
        }
        .foregroundStyle(tab.isActive ? .white : Color.white.opacity(0.72))
        .background(
            tab.isActive ? Color.accentColor.opacity(0.56) : Color.white.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(tab.isActive ? Color.white.opacity(0.55) : Color.white.opacity(0.14))
        )
    }
}

private struct ProgramMonitor: View {
    @ObservedObject var model: EditorAjarAppModel

    /// Stable AX name used by UI-smoke (`otherElements[…]`). Identifier + label must match.
    private var programMonitorAccessibilityName: String {
        "Program monitor showing \(model.activeSequenceName)"
    }

    var body: some View {
        VStack(spacing: 12) {
            // Hosting container always present; AX anchor does not wait on first frame.
            monitorStage
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 4) {
                HStack {
                    Text(model.activeSequenceName)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(model.loadMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("\(model.frameRateDescription)")
                    Spacer()
                    Text(model.playheadDescription)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 18)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
    }

    private var monitorStage: some View {
        ZStack {
            programCanvasLayers
                .aspectRatio(model.canvasAspectRatio, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    CanvasSafeAreaGuidesToggleButton(model: model)
                }

            if model.presentedTexture == nil {
                VStack(spacing: 6) {
                    Text(model.activeSequenceName)
                        .font(.title3.weight(.semibold))
                    Text(model.loadMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
            }

            // Dedicated AX host (surfaces as Image + identifier). UI-smoke matches by
            // identifier via descendants(.any), not otherElements role.
            programMonitorAccessibilityAnchor
        }
    }

    /// Render-independent AX node for `Program monitor showing …`.
    private var programMonitorAccessibilityAnchor: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(programMonitorAccessibilityName)
            .accessibilityLabel(programMonitorAccessibilityName)
            .accessibilityAddTraits(.isImage)
            .allowsHitTesting(false)
            .accessibilitySortPriority(1_000)
    }

    /// Metal + chrome + FR-TXT/XFORM overlays as layered siblings (hit-test order preserved).
    private var programCanvasLayers: some View {
        ZStack {
            programCanvasBase
            CanvasTransformOverlay(model: model)
            // Title boxes above transform chrome so FR-TXT-003 keeps hit-testing.
            CanvasTitleEditingOverlay(model: model)
            programCanvasBorder
        }
    }

    private var programCanvasBase: some View {
        ProgramMetalView(device: model.metalDevice, texture: model.presentedTexture)
            .background {
                if model.checkerboardAlphaVisible {
                    CheckerboardBackground()
                } else {
                    Color.black
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
    }

    private var programCanvasBorder: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let cell = 12.0
            for row in 0...Int(size.height / cell) {
                for column in 0...Int(size.width / cell) where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(x: Double(column) * cell, y: Double(row) * cell,
                                    width: cell, height: cell)),
                        with: .color(Color.white.opacity(0.18))
                    )
                }
            }
        }
        .background(Color.black)
        .accessibilityHidden(true)
    }
}

/// FR-TXT-003 action-safe / title-safe guide toggle (app overlay only).
private struct CanvasSafeAreaGuidesToggleButton: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        Button(action: model.toggleCanvasSafeAreaGuides) {
            toggleLabel
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .padding(8)
        .help(helpText)
        .keyboardShortcut("g", modifiers: [.command, .option])
        .accessibilityIdentifier("Canvas Safe Area Guides Toggle")
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(model.canvasSafeAreaGuidesVisible ? "On" : "Off")
        .accessibilityHint(helpText)
    }

    private var toggleLabel: some View {
        Label(accessibilityTitle, systemImage: "rectangle.inset.filled")
    }

    private var accessibilityTitle: String {
        model.canvasSafeAreaGuidesVisible
            ? AppString.localized("monitor.guides.hide", "Hide Action and Title Safe Guides")
            : AppString.localized("monitor.guides.show", "Show Action and Title Safe Guides")
    }

    private var helpText: String {
        model.canvasSafeAreaGuidesVisible
            ? AppString.localized(
                "monitor.guides.hide.help", "Hide action-safe and title-safe guides"
            )
            : AppString.localized(
                "monitor.guides.show.help", "Show action-safe and title-safe guides"
            )
    }
}

private struct TransportBar: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            Button(action: model.stepBackward) {
                Label(
                    AppString.localized("transport.stepBackward", "Step Backward"),
                    systemImage: "backward.frame.fill"
                )
                .labelStyle(.iconOnly)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help(AppString.localized("transport.stepBackward", "Step Backward"))
            .accessibilityLabel(AppString.localized("transport.stepBackward", "Step Backward"))
            .accessibilityIdentifier("Step Backward")

            Button(action: model.togglePlayback) {
                Label(
                    model.isPlaying
                        ? AppString.localized("transport.pause", "Pause")
                        : AppString.localized("transport.play", "Play"),
                    systemImage: model.isPlaying ? "pause.fill" : "play.fill"
                )
                .labelStyle(.iconOnly)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(
                model.isPlaying
                    ? AppString.localized("transport.pause", "Pause")
                    : AppString.localized("transport.play", "Play")
            )
            .accessibilityLabel(
                model.isPlaying
                    ? AppString.localized("transport.pause", "Pause")
                    : AppString.localized("transport.play", "Play")
            )
            .accessibilityIdentifier(model.isPlaying ? "Pause" : "Play")

            Button(action: model.stepForward) {
                Label(
                    AppString.localized("transport.stepForward", "Step Forward"),
                    systemImage: "forward.frame.fill"
                )
                .labelStyle(.iconOnly)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help(AppString.localized("transport.stepForward", "Step Forward"))
            .accessibilityLabel(AppString.localized("transport.stepForward", "Step Forward"))
            .accessibilityIdentifier("Step Forward")

            Text(model.playheadDescription)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 96, alignment: .leading)
                .accessibilityIdentifier("Playhead readout")
                .accessibilityLabel(AppString.localized("transport.playhead.ax", "Playhead"))
                .accessibilityValue(model.playheadDescription)
            Spacer()
        }
        .overlay(alignment: .bottom) {
            Slider(
                value: Binding(
                    get: { Double(model.playheadFrame) },
                    set: { model.scrub(to: Int64($0.rounded())) }
                ),
                in: 0...Double(max(1, model.durationFrames - 1)),
                step: 1
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 3)
            .accessibilityLabel(AppString.localized("transport.scrub.ax", "Scrub playhead"))
            .accessibilityIdentifier("Scrub playhead")
            .accessibilityValue(model.playheadDescription)
            .accessibilityHint(AppString.localized(
                "transport.scrub.hint",
                "Adjusts the playhead frame. Left and Right arrows step one frame."
            ))
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Transport controls")
        .accessibilityLabel(AppString.localized("transport.controls.ax", "Transport controls"))
    }
}

private struct InspectorPanel: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelTitle(AppString.localized("inspector.title", "Inspector"))
            DetailRow(
                label: AppString.localized("inspector.row.sequence", "Sequence"),
                value: model.activeSequenceName
            )
            DetailRow(
                label: AppString.localized("inspector.row.frameRate", "Frame Rate"),
                value: model.frameRateDescription
            )
            DetailRow(
                label: AppString.localized("inspector.row.state", "State"),
                value: model.isPlaying
                    ? AppString.localized("inspector.state.playing", "Playing")
                    : AppString.localized("inspector.state.paused", "Paused")
            )
            Divider()
            if let marker = model.selectedMarker {
                MarkerInspector(marker: marker, model: model)
            } else if let transformState = model.selectedTransformInspector {
                // Clip playback is nested inside TransformInspector's ScrollView (NFR-A11Y-001).
                TransformInspector(state: transformState, model: model)
            } else {
                DetailRow(
                    label: AppString.localized("inspector.row.marker", "Marker"),
                    value: AppString.localized("inspector.marker.none", "None selected")
                )
                DetailRow(
                    label: AppString.localized("inspector.row.transform", "Transform"),
                    value: AppString.localized("inspector.transform.none", "Select one video clip")
                )
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppString.localized("inspector.panel.ax", "Inspector panel"))
    }
}

/// FR-SPD-001/003 clip retime controls (nested in `TransformInspector` ScrollView).
private struct ClipPlaybackInspector: View {
    @ObservedObject var model: EditorAjarAppModel
    @State private var speedPercent = "100"

    var body: some View {
        GroupBox(AppString.localized("inspector.playback.title", "Clip Playback")) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(
                    AppString.localized("inspector.playback.speed", "Speed %"),
                    text: $speedPercent
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(AppString.localized("inspector.playback.speed", "Speed %"))
                .accessibilityIdentifier("Speed %")
                .onSubmit { _ = model.updateSelectedClipSpeed(percentText: speedPercent) }
                Toggle(
                    AppString.localized("inspector.playback.reverse", "Reverse"),
                    isOn: Binding(
                        get: { model.selectedClip?.reverse ?? false },
                        set: { _ = model.setSelectedClipReverse($0) }
                    )
                )
                .accessibilityLabel(AppString.localized("inspector.playback.reverse", "Reverse"))
                .accessibilityIdentifier("Clip Reverse")
                Toggle(
                    AppString.localized("inspector.playback.freeze", "Freeze Frame"),
                    isOn: Binding(
                        get: { model.selectedClip?.freezeFrame ?? false },
                        set: { _ = model.setSelectedClipFreezeFrame($0) }
                    )
                )
                .accessibilityLabel(
                    AppString.localized("inspector.playback.freeze", "Freeze Frame")
                )
                .accessibilityIdentifier("Clip Freeze Frame")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Clip Playback Inspector")
        .accessibilityLabel(
            AppString.localized("inspector.playback.ax", "Clip Playback Inspector")
        )
        .onAppear { speedPercent = model.selectedClipSpeedPercent }
        .onChange(of: model.selectedClip?.id) { _ in
            speedPercent = model.selectedClipSpeedPercent
        }
    }
}

private struct MarkerInspector: View {
    let marker: Marker
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(AppString.localized("inspector.marker.heading", "Marker"), systemImage: "flag.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(marker.color.swatchColor)
                Spacer()
                Button(role: .destructive, action: model.deleteSelectedMarker) {
                    Label(
                        AppString.localized("marker.delete", "Delete Marker"), systemImage: "trash"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(AppString.localized("marker.delete", "Delete Marker"))
                .accessibilityLabel(AppString.localized("marker.delete", "Delete Marker"))
                .accessibilityIdentifier("Delete Marker")
            }

            TextField(
                AppString.localized("marker.name", "Marker Name"),
                text: Binding(
                    get: { model.selectedMarker?.name ?? "" },
                    set: { model.updateSelectedMarker(name: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .timelineTextEditingScope(model: model)
            .accessibilityLabel(AppString.localized("marker.name", "Marker Name"))
            .accessibilityIdentifier("Marker Name")

            Picker(
                AppString.localized("marker.color", "Marker Color"),
                selection: Binding(
                    get: { model.selectedMarker?.color ?? .blue },
                    set: { model.updateSelectedMarker(color: $0) }
                )
            ) {
                ForEach(MarkerColor.allCases, id: \.self) { color in
                    HStack {
                        Circle()
                            .fill(color.swatchColor)
                            .frame(width: 10, height: 10)
                        Text(color.displayName)
                    }
                    .tag(color)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(AppString.localized("marker.color", "Marker Color"))
            .accessibilityIdentifier("Marker Color")

            TextEditor(
                text: Binding(
                    get: { model.selectedMarker?.note ?? "" },
                    set: { model.updateSelectedMarker(note: $0) }
                )
            )
            .frame(minHeight: 70)
            .scrollContentBackground(.hidden)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .accessibilityLabel(AppString.localized("marker.note", "Marker Note"))
            .accessibilityIdentifier("Marker Note")

            DetailRow(
                label: AppString.localized("marker.position", "Position"),
                value: AppString.localized(
                    "marker.position.value", "Frame \(markerFrameDescription(marker))"
                )
            )
        }
    }

    private func markerFrameDescription(_ marker: Marker) -> String {
        guard let sequence = model.activeSequence,
            let frame = try? marker.time.frameIndex(
                at: sequence.timebase,
                rounding: .nearestOrAwayFromZero
            )
        else {
            return "--"
        }
        return "\(frame)"
    }
}

private struct TimelineView: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        GeometryReader { geometry in
            let availableContentWidth = max(
                320,
                geometry.size.width - TimelineLayoutMetrics.trackContentLeadingOffset - 28
            )
            let timelineContentWidth = model.timelineContentWidth(
                minimumWidth: availableContentWidth
            )
            let timelineWidth =
                TimelineLayoutMetrics.trackContentLeadingOffset + timelineContentWidth
            VStack(alignment: .leading, spacing: 10) {
                toolbar(availableWidth: availableContentWidth)
                if let sequence = model.activeSequence {
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 8) {
                            TimelineRuler(
                                model: model,
                                contentWidth: timelineContentWidth
                            )
                            ForEach(videoRows(in: sequence), id: \.track.id) { row in
                                TrackLane(
                                    sequenceID: sequence.id,
                                    row: row,
                                    model: model,
                                    timelineContentWidth: timelineContentWidth
                                )
                            }
                            ForEach(audioRows(in: sequence), id: \.track.id) { row in
                                TrackLane(
                                    sequenceID: sequence.id,
                                    row: row,
                                    model: model,
                                    timelineContentWidth: timelineContentWidth
                                )
                            }
                        }
                        .frame(width: timelineWidth, alignment: .leading)
                    }
                    .accessibilityIdentifier("Timeline track lanes")
                    .accessibilityLabel(AppString.localized("timeline.trackLanes.ax", "Timeline track lanes"))
                } else {
                    Text(AppString.localized("timeline.noSequence", "No sequence"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                footer
            }
            .padding(14)
            .background(Color(red: 0.12, green: 0.12, blue: 0.13))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Timeline")
            .accessibilityLabel(AppString.localized("timeline.group.ax", "Timeline"))
        }
    }

    private func toolbar(availableWidth: Double) -> some View {
        HStack(spacing: 8) {
            PanelTitle(AppString.localized("timeline.title", "Timeline"))
            Spacer()
            TimelineToolButton(
                title: model.timelineTool == .blade
                    ? AppString.localized("timeline.tool.selection", "Use Selection Tool")
                    : AppString.localized("timeline.tool.blade", "Use Blade Tool"),
                identifier: "Toggle Blade Tool",
                systemImage: "scissors"
            ) { model.toggleBladeTool() }
            .keyboardShortcut("b", modifiers: [])
            .disabled(model.isTextEditingActive)
            TimelineToolButton(
                title: AppString.localized("timeline.tool.addMarker", "Add Marker"),
                identifier: "Add Marker",
                systemImage: "flag.fill"
            ) {
                model.addTimelineMarkerAtPlayhead()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            TimelineToolButton(
                title: AppString.localized("timeline.tool.previousMarker", "Previous Marker"),
                identifier: "Previous Marker",
                systemImage: "arrow.left.to.line"
            ) {
                model.jumpToPreviousMarker()
            }
            .keyboardShortcut("[", modifiers: [.command])
            TimelineToolButton(
                title: AppString.localized("timeline.tool.nextMarker", "Next Marker"),
                identifier: "Next Marker",
                systemImage: "arrow.right.to.line"
            ) {
                model.jumpToNextMarker()
            }
            .keyboardShortcut("]", modifiers: [.command])
            TimelineToolButton(
                title: AppString.localized("timeline.tool.deleteMarker", "Delete Marker"),
                identifier: "Delete Marker",
                systemImage: "trash"
            ) {
                model.deleteSelectedMarker()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(model.selectedMarker == nil)
            TimelineToolButton(
                title: AppString.localized("timeline.tool.detachAudio", "Detach Audio"),
                identifier: "Detach Audio",
                systemImage: "speaker.slash.fill"
            ) {
                model.detachAudioForSelectedClip()
            }
            .disabled(!model.selectedClipIsLinked)
            TimelineToolButton(
                title: AppString.localized("timeline.tool.zoomOut", "Zoom Timeline Out"),
                identifier: "Zoom Timeline Out",
                systemImage: "minus.magnifyingglass"
            ) {
                model.zoomTimelineOut()
            }
            .keyboardShortcut("-", modifiers: [.command])
            TimelineToolButton(
                title: AppString.localized("timeline.tool.zoomIn", "Zoom Timeline In"),
                identifier: "Zoom Timeline In",
                systemImage: "plus.magnifyingglass"
            ) {
                model.zoomTimelineIn()
            }
            .keyboardShortcut("=", modifiers: [.command])
            TimelineToolButton(
                title: AppString.localized("timeline.tool.decreaseHeight", "Decrease Track Height"),
                identifier: "Decrease Track Height",
                systemImage: "arrow.down.to.line.compact"
            ) {
                model.zoomTimelineVerticallyOut()
            }
            TimelineToolButton(
                title: AppString.localized("timeline.tool.increaseHeight", "Increase Track Height"),
                identifier: "Increase Track Height",
                systemImage: "arrow.up.to.line.compact"
            ) {
                model.zoomTimelineVerticallyIn()
            }
            TimelineToolButton(
                title: AppString.localized("timeline.tool.fit", "Fit Timeline"),
                identifier: "Fit Timeline",
                systemImage: "arrow.left.and.right"
            ) {
                model.fitTimeline(toWidth: availableWidth)
            }
            TimelineToolButton(
                title: AppString.localized("timeline.tool.zoomToSelection", "Zoom to Selection"),
                identifier: "Zoom to Selection",
                systemImage: "selection.pin.in.out"
            ) {
                model.zoomTimelineToSelection(toWidth: availableWidth)
            }
            TimelineToolButton(
                title: AppString.localized("timeline.tool.setRangeIn", "Set Range In"),
                identifier: "Set Range In",
                systemImage: "inset.filled.leadinghalf.rectangle"
            ) {
                model.setTimelineRangeIn()
            }
            .keyboardShortcut("i", modifiers: [])
            .disabled(model.isTextEditingActive)
            TimelineToolButton(
                title: AppString.localized("timeline.tool.setRangeOut", "Set Range Out"),
                identifier: "Set Range Out",
                systemImage: "inset.filled.trailinghalf.rectangle"
            ) {
                model.setTimelineRangeOut()
            }
            .keyboardShortcut("o", modifiers: [])
            .disabled(model.isTextEditingActive)
            TimelineToolButton(
                title: AppString.localized("timeline.tool.clearRange", "Clear Timeline Range"),
                identifier: "Clear Timeline Range",
                systemImage: "xmark.rectangle"
            ) {
                model.clearTimelineRange()
            }
            TimelineToolButton(
                title: model.timelineSnappingEnabled
                    ? AppString.localized("timeline.tool.disableSnapping", "Disable Snapping")
                    : AppString.localized("timeline.tool.enableSnapping", "Enable Snapping"),
                identifier: model.timelineSnappingEnabled ? "Disable Snapping" : "Enable Snapping",
                systemImage: "link"
            ) {
                model.setTimelineSnappingEnabled(!model.timelineSnappingEnabled)
            }
        }
        .controlSize(.small)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.timelineRangeDescription)
            Text(AppString.localized(
                "timeline.footer.selectedCount", "\(model.timelineSelectedClipCount) selected"
            ))
            if let feedback = model.timelineGestureFeedback { Text(feedback) }
            Spacer()
            Text(model.loadMessage)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppString.localized(
            "timeline.footer.ax",
            "Timeline status, \(model.timelineRangeDescription), \(model.timelineSelectedClipCount) selected"
        ))
    }

    private func videoRows(in sequence: AjarCore.Sequence) -> [TrackLaneRow] {
        sequence.videoTracks.enumerated().reversed().map { index, track in
            TrackLaneRow(
                name: "V\(index + 1)",
                kind: .video,
                track: track,
                accessibilityLabel: "Video track \(index + 1)",
                localizedLabel: AppString.localized(
                    "timeline.track.video", "Video track \(index + 1)"
                )
            )
        }
    }

    private func audioRows(in sequence: AjarCore.Sequence) -> [TrackLaneRow] {
        sequence.audioTracks.enumerated().map { index, track in
            TrackLaneRow(
                name: "A\(index + 1)",
                kind: .audio,
                track: track,
                accessibilityLabel: "Audio track \(index + 1)",
                localizedLabel: AppString.localized(
                    "timeline.track.audio", "Audio track \(index + 1)"
                )
            )
        }
    }
}

private enum TimelineLayoutMetrics {
    static let trackHeaderWidth = 196.0
    static let trackLaneSpacing = 8.0
    static let trackContentLeadingOffset = trackHeaderWidth + trackLaneSpacing
}

private struct TimelineRuler: View {
    @ObservedObject var model: EditorAjarAppModel
    let contentWidth: Double

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.06))
            Text(AppString.localized("timeline.ruler.frameZero", "Frame 0"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .offset(x: TimelineLayoutMetrics.trackContentLeadingOffset + 8)
            ForEach(model.timelineMarkerLayouts(), id: \.markerID) { layout in
                TimelineMarkerButton(
                    layout: layout,
                    isSelected: model.isMarkerSelected(layout.markerID)
                ) {
                    model.selectMarker(layout.markerID)
                }
                .offset(
                    x: TimelineLayoutMetrics.trackContentLeadingOffset
                        + max(0, layout.xPosition - 9)
                )
            }
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
                .offset(
                    x: TimelineLayoutMetrics.trackContentLeadingOffset
                        + model.timelineXPosition(for: model.playheadFrame)
                )
        }
        .frame(
            width: TimelineLayoutMetrics.trackContentLeadingOffset + contentWidth,
            height: 28
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    model.scrubTimeline(
                        xPosition: value.location.x
                            - TimelineLayoutMetrics.trackContentLeadingOffset
                    )
                }
        )
        // Contain (not ignore): marker buttons must remain individual AX nodes.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Timeline ruler")
        .accessibilityLabel(AppString.localized("timeline.ruler.ax", "Timeline ruler"))
        .accessibilityValue(model.playheadDescription)
        .accessibilityHint(AppString.localized(
            "timeline.ruler.hint", "Drag to scrub. Markers are separate controls on this ruler."
        ))
        .help(AppString.localized("timeline.ruler.help", "Drag to scrub"))
    }
}

private struct TimelineMarkerButton: View {
    let layout: TimelineMarkerLayout
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "flag.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(layout.color.swatchColor)
                .frame(width: 18, height: 22)
                .background(
                    Color.black.opacity(isSelected ? 0.75 : 0.45),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.white : Color.white.opacity(0.24), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(AppString.localized("timeline.marker.help", "\(layout.name), frame \(layout.frame)"))
        .accessibilityLabel(AppString.localized("timeline.marker.ax", "Marker \(layout.name)"))
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("Timeline marker \(layout.markerID.uuidString)")
    }

    private var accessibilityValue: String {
        let note = layout.note.isEmpty
            ? AppString.localized("timeline.marker.noNote", "No note")
            : layout.note
        let selection = isSelected
            ? AppString.localized("state.selected", "Selected")
            : AppString.localized("state.notSelected", "Not selected")
        return AppString.localized(
            "timeline.marker.value",
            "\(selection), \(layout.color.displayName), frame \(layout.frame), \(note)"
        )
    }
}

private struct TimelineToolButton: View {
    /// Localized visible/spoken title (tooltip + VoiceOver label).
    let title: String
    /// Stable, non-localized identifier queried by UI tests (NFR-I18N-001: identifiers are literal).
    let identifier: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .frame(width: 28, height: 24)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

private extension MarkerColor {
    var displayName: String {
        switch self {
        case .gray:
            return AppString.localized("marker.color.gray", "Gray")
        case .red:
            return AppString.localized("marker.color.red", "Red")
        case .orange:
            return AppString.localized("marker.color.orange", "Orange")
        case .yellow:
            return AppString.localized("marker.color.yellow", "Yellow")
        case .green:
            return AppString.localized("marker.color.green", "Green")
        case .blue:
            return AppString.localized("marker.color.blue", "Blue")
        case .purple:
            return AppString.localized("marker.color.purple", "Purple")
        }
    }

    var swatchColor: Color {
        switch self {
        case .gray:
            return Color(red: 0.62, green: 0.64, blue: 0.68)
        case .red:
            return Color(red: 0.95, green: 0.25, blue: 0.25)
        case .orange:
            return Color(red: 0.95, green: 0.55, blue: 0.18)
        case .yellow:
            return Color(red: 0.95, green: 0.78, blue: 0.22)
        case .green:
            return Color(red: 0.28, green: 0.78, blue: 0.42)
        case .blue:
            return Color(red: 0.35, green: 0.62, blue: 0.95)
        case .purple:
            return Color(red: 0.70, green: 0.48, blue: 0.95)
        }
    }
}

private extension ClipBlendMode {
    var displayName: String {
        switch self {
        case .normal:
            return AppString.localized("blend.normal", "Normal")
        case .multiply:
            return AppString.localized("blend.multiply", "Multiply")
        case .screen:
            return AppString.localized("blend.screen", "Screen")
        case .overlay:
            return AppString.localized("blend.overlay", "Overlay")
        case .add:
            return AppString.localized("blend.add", "Add")
        case .darken:
            return AppString.localized("blend.darken", "Darken")
        case .lighten:
            return AppString.localized("blend.lighten", "Lighten")
        case .colorDodge:
            return AppString.localized("blend.colorDodge", "Color Dodge")
        case .colorBurn:
            return AppString.localized("blend.colorBurn", "Color Burn")
        case .hardLight:
            return AppString.localized("blend.hardLight", "Hard Light")
        case .softLight:
            return AppString.localized("blend.softLight", "Soft Light")
        case .difference:
            return AppString.localized("blend.difference", "Difference")
        case .exclusion:
            return AppString.localized("blend.exclusion", "Exclusion")
        case .subtract:
            return AppString.localized("blend.subtract", "Subtract")
        case .hue:
            return AppString.localized("blend.hue", "Hue")
        case .saturation:
            return AppString.localized("blend.saturation", "Saturation")
        case .color:
            return AppString.localized("blend.color", "Color")
        case .luminosity:
            return AppString.localized("blend.luminosity", "Luminosity")
        }
    }
}

private struct TrackLane: View {
    let sequenceID: UUID
    let row: TrackLaneRow
    @ObservedObject var model: EditorAjarAppModel
    let timelineContentWidth: Double

    var body: some View {
        HStack(spacing: TimelineLayoutMetrics.trackLaneSpacing) {
            trackHeader
            timelineContent
        }
        .frame(
            width: TimelineLayoutMetrics.trackContentLeadingOffset + timelineContentWidth,
            height: model.timelineState.laneHeight
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.fullAccessibilityLabel)
    }

    private var trackHeader: some View {
        HStack(spacing: 6) {
            Text(row.name)
                .font(.caption.weight(.semibold))
                .frame(width: 34)
                .accessibilityHidden(true)
            TrackStateButton(
                title: row.track.enabled
                    ? AppString.localized("timeline.track.disable", "Disable \(row.localizedLabel)")
                    : AppString.localized("timeline.track.enable", "Enable \(row.localizedLabel)"),
                identifier: row.track.enabled
                    ? "Disable \(row.accessibilityLabel)" : "Enable \(row.accessibilityLabel)",
                systemImage: "power",
                isOn: row.track.enabled
            ) {
                model.setTrackState(
                    sequenceID: sequenceID,
                    trackID: row.track.id,
                    enabled: !row.track.enabled
                )
            }
            TrackStateButton(
                title: row.track.locked
                    ? AppString.localized("timeline.track.unlock", "Unlock \(row.localizedLabel)")
                    : AppString.localized("timeline.track.lock", "Lock \(row.localizedLabel)"),
                identifier: row.track.locked
                    ? "Unlock \(row.accessibilityLabel)" : "Lock \(row.accessibilityLabel)",
                systemImage: row.track.locked ? "lock.fill" : "lock.open",
                isOn: row.track.locked
            ) {
                model.setTrackState(
                    sequenceID: sequenceID,
                    trackID: row.track.id,
                    locked: !row.track.locked
                )
            }
            if row.kind == .video {
                TrackStateButton(
                    title: row.track.hidden
                        ? AppString.localized("timeline.track.show", "Show \(row.localizedLabel)")
                        : AppString.localized("timeline.track.hide", "Hide \(row.localizedLabel)"),
                    identifier: row.track.hidden
                        ? "Show \(row.accessibilityLabel)" : "Hide \(row.accessibilityLabel)",
                    systemImage: row.track.hidden ? "eye.slash.fill" : "eye",
                    isOn: !row.track.hidden
                ) {
                    model.setTrackState(
                        sequenceID: sequenceID,
                        trackID: row.track.id,
                        hidden: !row.track.hidden
                    )
                }
            } else {
                TrackStateButton(
                    title: row.track.muted
                        ? AppString.localized("timeline.track.unmute", "Unmute \(row.localizedLabel)")
                        : AppString.localized("timeline.track.mute", "Mute \(row.localizedLabel)"),
                    identifier: row.track.muted
                        ? "Unmute \(row.accessibilityLabel)" : "Mute \(row.accessibilityLabel)",
                    systemImage: row.track.muted ? "speaker.slash.fill" : "speaker.wave.2",
                    isOn: row.track.muted
                ) {
                    model.setTrackState(
                        sequenceID: sequenceID,
                        trackID: row.track.id,
                        muted: !row.track.muted
                    )
                }
                TrackStateButton(
                    title: row.track.solo
                        ? AppString.localized("timeline.track.unsolo", "Unsolo \(row.localizedLabel)")
                        : AppString.localized("timeline.track.solo", "Solo \(row.localizedLabel)"),
                    identifier: row.track.solo
                        ? "Unsolo \(row.accessibilityLabel)" : "Solo \(row.accessibilityLabel)",
                    systemImage: row.track.solo ? "headphones.circle.fill" : "headphones",
                    isOn: row.track.solo
                ) {
                    model.setTrackState(
                        sequenceID: sequenceID,
                        trackID: row.track.id,
                        solo: !row.track.solo
                    )
                }
            }
            TrackStateButton(
                title: AppString.localized(
                    "timeline.track.selectAll", "Select all \(row.localizedLabel)"
                ),
                identifier: "Select all \(row.accessibilityLabel)",
                systemImage: "checkmark.circle",
                isOn: false
            ) {
                model.selectAllClips(on: row.track.id)
            }
        }
        .frame(width: TimelineLayoutMetrics.trackHeaderWidth, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.selectTimelineTrack(row.track.id) }
    }

    private var timelineContent: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08))
            ForEach(model.timelineClipLayouts(for: row.track), id: \.reference) { layout in
                TimelineClipBlock(
                    layout: layout,
                    isSelected: model.isClipSelected(layout.reference),
                    model: model,
                    keyframeLanes: transformKeyframeLanes(for: layout),
                    pixelsPerFrame: model.timelineState.pixelsPerFrame,
                    addKeyframe: { parameter, frame in
                        model.addSelectedTransformKeyframe(parameter: parameter, atFrame: frame)
                    },
                    moveKeyframe: { parameter, fromFrame, toFrame in
                        model.moveSelectedTransformKeyframe(
                            parameter: parameter,
                            fromFrame: fromFrame,
                            toFrame: toFrame
                        )
                    },
                    deleteKeyframe: { parameter, frame in
                        model.deleteSelectedTransformKeyframe(parameter: parameter, atFrame: frame)
                    }
                ) {
                    model.focusTimeline()
                    if model.timelineTool == .blade {
                        // Pointer-position blade is handled by the block's spatial-tap gesture
                        // (#240); keyboard / VoiceOver activation blades at the playhead via ⌘B.
                        return
                    }
                    model.selectClip(
                        trackID: layout.reference.trackID,
                        clipID: layout.reference.clipID,
                        mode: NSEvent.modifierFlags.contains(.command) ? .toggle : .replace
                    )
                }
                .frame(
                    width: layout.width,
                    height: max(24, model.timelineState.laneHeight - 12)
                )
                .offset(x: layout.xPosition)
            }
            Rectangle()
                .fill(Color.accentColor.opacity(0.75))
                .frame(width: 2)
                .offset(x: model.timelineXPosition(for: model.playheadFrame))
            if let snapFrame = model.timelineSnapIndicatorFrame {
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: 2)
                    .offset(x: model.timelineXPosition(for: snapFrame))
                    .accessibilityLabel(AppString.localized(
                        "timeline.snapIndicator.ax", "Snapped at frame \(snapFrame)"
                    ))
            }
        }
        .frame(
            width: max(1, timelineContentWidth), height: max(24, model.timelineState.laneHeight - 8)
        )
    }

    private func transformKeyframeLanes(for layout: TimelineClipLayout) -> [TransformKeyframeLane] {
        guard row.kind == .video,
            model.selectedTransformClipReference == layout.reference
        else {
            return []
        }

        return model.selectedTransformKeyframeLanes.filter { !$0.keyframes.isEmpty }
    }
}

private struct TimelineClipBlock: View {
    let layout: TimelineClipLayout
    let isSelected: Bool
    @ObservedObject var model: EditorAjarAppModel
    let keyframeLanes: [TransformKeyframeLane]
    let pixelsPerFrame: Double
    let addKeyframe: (ClipTransformParameter, Int64) -> Void
    let moveKeyframe: (ClipTransformParameter, Int64, Int64) -> Void
    let deleteKeyframe: (ClipTransformParameter, Int64) -> Void
    let action: () -> Void

    @State private var dragStartFrame: Int64?
    /// Set while a trim-handle drag is in flight so the clip-body move gesture stays inert
    /// (#240 review, finding 3): one edge drag is one trim, never trim + move.
    @State private var activeTrimEdge: TimelineTrimEdge?

    var body: some View {
        VStack(spacing: 2) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "film")
                        .font(.caption2)
                    Text(layout.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected ? .black : .white)
            .frame(maxWidth: .infinity, maxHeight: keyframeLanes.isEmpty ? .infinity : 24)
            .background(
                isSelected ? Color.accentColor : Color.white.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        isSelected ? Color.white.opacity(0.7) : Color.white.opacity(0.18),
                        lineWidth: 1)
            )
            .help(AppString.localized(
                "timeline.clip.help", "\(layout.name), frames \(layout.startFrame)-\(layout.endFrame)"
            ))
            .accessibilityLabel(AppString.localized("timeline.clip.ax", "Clip \(layout.name)"))
            .accessibilityValue(AppString.localized(
                "timeline.clip.value",
                "\(selectionState), frames \(layout.startFrame)-\(layout.endFrame)"
            ))
            .accessibilityIdentifier("Timeline clip \(layout.reference.clipID.uuidString)")
            .simultaneousGesture(moveGesture)
            .highPriorityGesture(model.timelineTool == .blade ? bladeTapGesture : nil)
            .overlay(alignment: .leading) { trimHandle(edge: .leading) }
            .overlay(alignment: .trailing) { trimHandle(edge: .trailing) }

            if !keyframeLanes.isEmpty {
                TransformKeyframeLanesView(
                    layout: layout,
                    lanes: keyframeLanes,
                    pixelsPerFrame: pixelsPerFrame,
                    addKeyframe: addKeyframe,
                    moveKeyframe: moveKeyframe,
                    deleteKeyframe: deleteKeyframe
                )
            }
        }
    }

    private var bladeTapGesture: some Gesture {
        // Blade tool splits at the exact pointer position (#240). Local x maps to a timeline
        // frame through the clip's on-screen origin and the current zoom.
        SpatialTapGesture(coordinateSpace: .local)
            .onEnded { value in
                model.focusTimeline()
                _ = model.bladeClip(
                    reference: layout.reference,
                    atTimelineX: layout.xPosition + value.location.x
                )
            }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStartFrame == nil {
                    // A drag that began on a trim handle is a trim, never a move (#240 review,
                    // finding 3). The handle's gesture (2px threshold) recognizes before this
                    // one (4px), so the flag is already set when a handle drag reaches here.
                    guard activeTrimEdge == nil else { return }
                    dragStartFrame = layout.startFrame
                    if !isSelected {
                        model.selectClip(trackID: layout.reference.trackID,
                                         clipID: layout.reference.clipID, mode: .replace)
                    }
                }
                guard activeTrimEdge == nil else { return }
                let delta = Int64((value.translation.width / max(1, pixelsPerFrame)).rounded())
                let proposed = max(0, layout.startFrame + delta)
                let disabled = NSEvent.modifierFlags.contains(.control)
                let frame = model.snappedTimelineFrame(proposed, momentarilyDisabled: disabled)
                model.previewTimelineGesture(frame: frame, snapped: frame != proposed)
            }
            .onEnded { value in
                // Trim drags suppress the move entirely: either the trim is still active, or it
                // ended without this gesture's onChanged ever arming dragStartFrame.
                guard activeTrimEdge == nil, dragStartFrame != nil else {
                    dragStartFrame = nil
                    return
                }
                let delta = Int64((value.translation.width / max(1, pixelsPerFrame)).rounded())
                let proposed = max(0, layout.startFrame + delta)
                let frame = model.snappedTimelineFrame(
                    proposed, momentarilyDisabled: NSEvent.modifierFlags.contains(.control)
                )
                let linkMode: LinkedClipEditMode = NSEvent.modifierFlags.contains(.option) ? .unlinked : .linked
                if model.timelineSelectedClipCount > 1 {
                    // Move the whole selection by the dragged clip's snapped delta in one undo
                    // step (#240); vertical track changes stay a single-clip affordance.
                    _ = model.moveSelectedClips(
                        byFrames: frame - layout.startFrame,
                        linkedClipEditMode: linkMode
                    )
                } else {
                    let laneOffset = Int((value.translation.height / max(1, model.timelineState.laneHeight)).rounded())
                    let destination = model.compatibleTrackID(for: layout.reference, verticalLaneOffset: laneOffset)
                    _ = model.moveSelectedClip(toStartFrame: frame, destinationTrackID: destination,
                                               linkedClipEditMode: linkMode)
                }
                dragStartFrame = nil
                model.cancelTimelineGesture()
            }
    }

    private func trimHandle(edge: TimelineTrimEdge) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2).onChanged { value in
                    activeTrimEdge = edge
                    let base = edge == .leading ? layout.startFrame : layout.endFrame
                    let delta = Int64((value.translation.width / max(1, pixelsPerFrame)).rounded())
                    let proposed = max(0, base + delta)
                    let frame = model.snappedTimelineFrame(
                        proposed, momentarilyDisabled: NSEvent.modifierFlags.contains(.control)
                    )
                    model.previewTimelineGesture(frame: frame, snapped: frame != proposed)
                }.onEnded { value in
                    let base = edge == .leading ? layout.startFrame : layout.endFrame
                    let delta = Int64((value.translation.width / max(1, pixelsPerFrame)).rounded())
                    let frame = model.snappedTimelineFrame(
                        max(0, base + delta),
                        momentarilyDisabled: NSEvent.modifierFlags.contains(.control)
                    )
                    if NSEvent.modifierFlags.contains(.command) {
                        _ = model.rollSelectedClip(edge: edge, toFrame: frame)
                    } else {
                        let linkMode: LinkedClipEditMode = NSEvent.modifierFlags.contains(.option)
                            ? .unlinked : .linked
                        _ = model.rippleTrimSelectedClip(edge: edge, toFrame: frame,
                                                         linkedClipEditMode: linkMode)
                    }
                    activeTrimEdge = nil
                    model.cancelTimelineGesture()
                }
            )
            .accessibilityHidden(true)
    }

    private var selectionState: String {
        isSelected
            ? AppString.localized("state.selected", "Selected")
            : AppString.localized("state.notSelected", "Not selected")
    }
}

private struct TransformInspector: View {
    let state: SelectedTransformInspectorState
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(state.clipName, systemImage: "slider.horizontal.3")
                    .font(.callout.weight(.semibold))
                TransformFieldGrid(
                    fields: [.positionX, .positionY],
                    keyframeParameter: .position,
                    model: model
                )
                TransformFieldGrid(
                    fields: [.scaleXPercent, .scaleYPercent],
                    keyframeParameter: .scale,
                    model: model
                )
                TransformFieldGrid(
                    fields: [.anchorX, .anchorY],
                    keyframeParameter: .anchorPoint,
                    model: model
                )
                TransformFieldGrid(
                    fields: [.rotationDegrees],
                    keyframeParameter: .rotation,
                    model: model
                )
                TransformFieldGrid(
                    fields: [.opacityPercent],
                    keyframeParameter: .opacity,
                    model: model
                )
                TransformBlendPicker(model: model)
                if let trackState = model.selectedTrackCompositingInspector {
                    TrackCompositingInspector(state: trackState, model: model)
                }
                TransformFieldGrid(
                    fields: [.cropLeft, .cropTop, .cropRight, .cropBottom],
                    keyframeParameter: .crop,
                    model: model
                )
                TransformFlipControls(model: model)
                ClipPlaybackInspector(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Keep offscreen scroll children in the AX tree (NFR-A11Y-001 / #187).
            .accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Transform Inspector")
        .accessibilityLabel(AppString.localized("inspector.transform.ax", "Transform Inspector"))
    }
}

private struct TransformFieldGrid: View {
    let fields: [TransformInspectorField]
    let keyframeParameter: ClipTransformParameter
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(keyframeParameter.localizedName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                TransformKeyframeToggle(parameter: keyframeParameter, model: model)
            }
            // Non-lazy 2-column grid so transform fields stay in the AX tree (not only
            // on-screen LazyVGrid cells).
            VStack(spacing: 8) {
                ForEach(Array(fieldRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(row) { field in
                            TransformNumberField(field: field, model: model)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if row.count == 1 {
                            Spacer().frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private var fieldRows: [[TransformInspectorField]] {
        stride(from: 0, to: fields.count, by: 2).map { start in
            Array(fields[start..<min(start + 2, fields.count)])
        }
    }
}

private struct TransformNumberField: View {
    let field: TransformInspectorField
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.localizedTitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(
                field.localizedTitle,
                text: Binding(
                    get: { model.transformFieldValue(field) },
                    set: { model.updateSelectedTransformField(field, rawValue: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .timelineTextEditingScope(model: model)
            .accessibilityLabel(field.localizedTitle)
            .accessibilityIdentifier(field.accessibilityIdentifier)
        }
    }
}

private struct TransformKeyframeToggle: View {
    let parameter: ClipTransformParameter
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        let hasKeyframe = model.selectedTransformHasKeyframe(parameter)
        Button {
            model.toggleSelectedTransformKeyframe(parameter)
        } label: {
            Label(
                hasKeyframe
                    ? AppString.localized(
                        "transform.keyframe.delete", "Delete \(parameter.localizedName) Keyframe"
                    )
                    : AppString.localized(
                        "transform.keyframe.add", "Add \(parameter.localizedName) Keyframe"
                    ),
                systemImage: hasKeyframe ? "diamond.fill" : "diamond"
            )
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(
            hasKeyframe
                ? AppString.localized(
                    "transform.keyframe.delete.help", "Delete keyframe at playhead"
                )
                : AppString.localized("transform.keyframe.add.help", "Add keyframe at playhead")
        )
        .accessibilityLabel(
            hasKeyframe
                ? AppString.localized(
                    "transform.keyframe.delete", "Delete \(parameter.localizedName) Keyframe"
                )
                : AppString.localized(
                    "transform.keyframe.add", "Add \(parameter.localizedName) Keyframe"
                )
        )
        .accessibilityIdentifier("Transform \(parameter.displayName) Keyframe Toggle")
    }
}

private struct TransformBlendPicker: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        Picker(
            AppString.localized("transform.blend", "Blend"),
            selection: Binding(
                get: { model.selectedTransformInspector?.transform.blendMode ?? .normal },
                set: { model.updateSelectedClipBlendMode($0) }
            )
        ) {
            ForEach(ClipBlendMode.allCases, id: \.self) { blendMode in
                Text(blendMode.displayName).tag(blendMode)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel(AppString.localized("transform.blendMode.ax", "Blend Mode"))
        .accessibilityIdentifier("Transform Blend Mode")
    }
}

private struct TrackCompositingInspector: View {
    let state: SelectedTrackCompositingInspectorState
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppString.localized("track.compositing", "Track Compositing"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(state.trackName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(
                AppString.localized("track.opacityPercent", "Opacity %"),
                text: Binding(
                    get: { model.selectedTrackOpacityPercentValue() },
                    set: { model.updateSelectedTrackOpacityPercent(rawValue: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .timelineTextEditingScope(model: model)
            .accessibilityLabel(AppString.localized("track.opacityPercent.ax", "Track Opacity Percent"))
            .accessibilityIdentifier("Track Opacity Percent")
            Picker(
                AppString.localized("track.blend", "Track Blend"),
                selection: Binding(
                    get: { model.selectedTrackCompositingInspector?.blendMode ?? .normal },
                    set: { model.updateSelectedTrackBlendMode($0) }
                )
            ) {
                ForEach(ClipBlendMode.allCases, id: \.self) { blendMode in
                    Text(blendMode.displayName).tag(blendMode)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(AppString.localized("track.blendMode.ax", "Track Blend Mode"))
            .accessibilityIdentifier("Track Blend Mode")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Track Compositing Inspector")
        .accessibilityLabel(
            AppString.localized("track.compositing.ax", "Track Compositing Inspector")
        )
    }
}

private struct TransformFlipControls: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppString.localized("transform.flip", "Flip"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle(
                AppString.localized("transform.flip.horizontal", "Flip Horizontal"),
                isOn: Binding(
                    get: { model.selectedTransformInspector?.transform.flip.horizontal ?? false },
                    set: { model.updateSelectedClipFlip(horizontal: $0) }
                )
            )
            .accessibilityLabel(AppString.localized("transform.flip.horizontal", "Flip Horizontal"))
            .accessibilityIdentifier("Transform Flip Horizontal")
            .accessibilityValue(
                (model.selectedTransformInspector?.transform.flip.horizontal ?? false)
                    ? AppString.localized("state.on", "On")
                    : AppString.localized("state.off", "Off")
            )
            Toggle(
                AppString.localized("transform.flip.vertical", "Flip Vertical"),
                isOn: Binding(
                    get: { model.selectedTransformInspector?.transform.flip.vertical ?? false },
                    set: { model.updateSelectedClipFlip(vertical: $0) }
                )
            )
            .accessibilityLabel(AppString.localized("transform.flip.vertical", "Flip Vertical"))
            .accessibilityIdentifier("Transform Flip Vertical")
            .accessibilityValue(
                (model.selectedTransformInspector?.transform.flip.vertical ?? false)
                    ? AppString.localized("state.on", "On")
                    : AppString.localized("state.off", "Off")
            )
        }
    }
}

private struct CanvasTransformOverlay: View {
    @ObservedObject var model: EditorAjarAppModel
    @GestureState private var movePreview = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            if let layout = model.selectedCanvasTransformLayout {
                let metrics = canvasMetrics(layout: layout, size: geometry.size)
                ZStack(alignment: .topLeading) {
                    transformOutline(metrics: metrics)
                    transformReadout(metrics: metrics, transform: layout.transform)
                    transformHandle(
                        identifier: "Scale Transform",
                        label: AppString.localized("transform.handle.scale", "Scale Transform"),
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        position: CGPoint(x: metrics.rect.maxX, y: metrics.rect.maxY),
                        handle: .scaleBottomRight,
                        canvasScale: metrics.scale
                    )
                    transformHandle(
                        identifier: "Rotate Transform",
                        label: AppString.localized("transform.handle.rotate", "Rotate Transform"),
                        systemImage: "rotate.right",
                        position: CGPoint(x: metrics.rect.midX, y: metrics.rect.minY - 28),
                        handle: .rotate,
                        canvasScale: metrics.scale
                    )
                    transformHandle(
                        identifier: "Move Anchor",
                        label: AppString.localized("transform.handle.anchor", "Move Anchor"),
                        systemImage: "scope",
                        position: metrics.anchorPoint,
                        handle: .anchor,
                        canvasScale: metrics.scale
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("Program Transform Overlay")
                .accessibilityLabel(
                    AppString.localized("transform.overlay.ax", "Program Transform Overlay")
                )
            }
        }
    }

    private func transformOutline(metrics: CanvasOverlayMetrics) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            .frame(width: metrics.rect.width, height: metrics.rect.height)
            .offset(x: metrics.rect.minX, y: metrics.rect.minY)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($movePreview) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        model.applyCanvasTransformGesture(
                            CanvasTransformGesture(
                                handle: .move,
                                translationX: value.translation.width,
                                translationY: value.translation.height,
                                canvasScale: metrics.scale
                            )
                        )
                    }
            )
            .accessibilityLabel(AppString.localized("transform.move.ax", "Move Transform"))
            .accessibilityIdentifier("Program Move Transform")
            .accessibilityHint(AppString.localized(
                "transform.move.hint",
                "Drag to reposition the selected clip. Numeric fields are in the inspector."
            ))
            .accessibilityAddTraits(.isButton)
    }

    private func transformReadout(
        metrics: CanvasOverlayMetrics, transform: ClipTransform
    ) -> some View {
        let summary = readout(transform)
        return Text(summary)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
            .offset(x: metrics.rect.minX, y: max(0, metrics.rect.minY - 24))
            .accessibilityIdentifier("Program Transform Readout")
            .accessibilityLabel(AppString.localized("transform.readout.ax", "Transform readout"))
            .accessibilityValue(summary)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private func transformHandle(
        identifier: String,
        label: String,
        systemImage: String,
        position: CGPoint,
        handle: CanvasTransformHandle,
        canvasScale: Double
    ) -> some View {
        Image(systemName: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(.black)
            .frame(width: 22, height: 22)
            .background(Color.accentColor, in: Circle())
            .offset(x: position.x - 11, y: position.y - 11)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onEnded { value in
                        model.applyCanvasTransformGesture(
                            CanvasTransformGesture(
                                handle: handle,
                                translationX: value.translation.width,
                                translationY: value.translation.height,
                                canvasScale: canvasScale
                            )
                        )
                    }
            )
            .accessibilityLabel(label)
            .accessibilityIdentifier("Program \(identifier)")
            .accessibilityHint(AppString.localized(
                "transform.handle.hint", "Drag to adjust. Numeric fields are in the inspector."
            ))
            .accessibilityAddTraits(.isButton)
    }

    private func canvasMetrics(
        layout: CanvasClipTransformLayout, size: CGSize
    ) -> CanvasOverlayMetrics {
        let canvasWidth = max(1.0, Double(layout.canvasSize.width))
        let canvasHeight = max(1.0, Double(layout.canvasSize.height))
        let scale = min(size.width / canvasWidth, size.height / canvasHeight)
        let origin = CGPoint(
            x: (size.width - (canvasWidth * scale)) / 2.0,
            y: (size.height - (canvasHeight * scale)) / 2.0
        )
        let xPosition =
            origin.x
            + ((layout.transform.position.x.doubleValue * scale) + movePreview.width)
        let yPosition =
            origin.y
            + ((layout.transform.position.y.doubleValue * scale) + movePreview.height)
        let width = max(
            8, Double(layout.clipSize.width) * layout.transform.scale.x.doubleValue * scale)
        let height = max(
            8, Double(layout.clipSize.height) * layout.transform.scale.y.doubleValue * scale)
        let rect = CGRect(x: xPosition, y: yPosition, width: width, height: height)
        let anchorPoint = CGPoint(
            x: origin.x + (layout.transform.anchorPoint.x.doubleValue * scale),
            y: origin.y + (layout.transform.anchorPoint.y.doubleValue * scale)
        )
        return CanvasOverlayMetrics(scale: scale, rect: rect, anchorPoint: anchorPoint)
    }

    private func readout(_ transform: ClipTransform) -> String {
        let xPosition = TransformFieldValueMapper.stringValue(for: .positionX, in: transform)
        let yPosition = TransformFieldValueMapper.stringValue(for: .positionY, in: transform)
        let scale = TransformFieldValueMapper.stringValue(for: .scaleXPercent, in: transform)
        let rotation = TransformFieldValueMapper.stringValue(for: .rotationDegrees, in: transform)
        return "X \(xPosition)  Y \(yPosition)  S \(scale)%  R \(rotation)"
    }
}

private struct CanvasOverlayMetrics {
    let scale: Double
    let rect: CGRect
    let anchorPoint: CGPoint
}

private struct TransformKeyframeLanesView: View {
    let layout: TimelineClipLayout
    let lanes: [TransformKeyframeLane]
    let pixelsPerFrame: Double
    let addKeyframe: (ClipTransformParameter, Int64) -> Void
    let moveKeyframe: (ClipTransformParameter, Int64, Int64) -> Void
    let deleteKeyframe: (ClipTransformParameter, Int64) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(lanes) { lane in
                TransformKeyframeLaneRow(
                    layout: layout,
                    lane: lane,
                    pixelsPerFrame: pixelsPerFrame,
                    addKeyframe: addKeyframe,
                    moveKeyframe: moveKeyframe,
                    deleteKeyframe: deleteKeyframe
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Transform keyframe lanes")
        .accessibilityLabel(AppString.localized("transform.keyframeLanes.ax", "Transform keyframe lanes"))
    }
}

private struct TransformKeyframeLaneRow: View {
    let layout: TimelineClipLayout
    let lane: TransformKeyframeLane
    let pixelsPerFrame: Double
    let addKeyframe: (ClipTransformParameter, Int64) -> Void
    let moveKeyframe: (ClipTransformParameter, Int64, Int64) -> Void
    let deleteKeyframe: (ClipTransformParameter, Int64) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Text(lane.title)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                ForEach(lane.keyframes) { point in
                    TransformKeyframeDot(
                        lane: lane,
                        point: point,
                        clipStartX: layout.xPosition,
                        laneWidth: geometry.size.width,
                        pixelsPerFrame: pixelsPerFrame,
                        moveKeyframe: moveKeyframe,
                        deleteKeyframe: deleteKeyframe
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let frame =
                            layout.startFrame
                            + Int64((value.location.x / max(1.0, pixelsPerFrame)).rounded())
                        addKeyframe(
                            lane.parameter, min(max(layout.startFrame, frame), layout.endFrame - 1))
                    }
            )
        }
        .frame(height: 8)
        .accessibilityIdentifier("Transform keyframe lane \(lane.title)")
        .accessibilityLabel(
            AppString.localized("transform.keyframeLane.ax", "Transform keyframe lane \(lane.title)")
        )
    }
}

private struct TransformKeyframeDot: View {
    let lane: TransformKeyframeLane
    let point: TransformKeyframePoint
    let clipStartX: Double
    let laneWidth: Double
    let pixelsPerFrame: Double
    let moveKeyframe: (ClipTransformParameter, Int64, Int64) -> Void
    let deleteKeyframe: (ClipTransformParameter, Int64) -> Void

    var body: some View {
        Button {
            deleteKeyframe(lane.parameter, point.frame)
        } label: {
            Image(systemName: "diamond.fill")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 14, height: 10)
        }
        .buttonStyle(.plain)
        .offset(x: dotX)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onEnded { value in
                    let deltaFrames = Int64(
                        (value.translation.width / max(1.0, pixelsPerFrame)).rounded())
                    moveKeyframe(lane.parameter, point.frame, point.frame + deltaFrames)
                }
        )
        .help(AppString.localized(
            "transform.keyframeDot.help", "\(lane.title) keyframe, frame \(point.frame)"
        ))
        .accessibilityLabel(
            AppString.localized("transform.keyframeDot.ax", "\(lane.title) keyframe")
        )
        .accessibilityValue(AppString.localized("frame.value", "Frame \(point.frame)"))
        .accessibilityIdentifier("Transform \(lane.title) Keyframe \(point.frame)")
    }

    private var dotX: Double {
        min(max(0, point.xPosition - clipStartX - 7), max(0, laneWidth - 14))
    }
}

private struct TrackLaneRow {
    let name: String
    let kind: TrackKind
    let track: Track
    /// English label; backs stable, non-localized UI-test identifiers (e.g. `Disable Video track 1`).
    let accessibilityLabel: String
    /// Localized label used for the spoken VoiceOver label (never for identifiers).
    let localizedLabel: String

    var summary: String {
        guard !track.items.isEmpty else {
            return AppString.localized("timeline.track.summary.empty", "Empty")
        }
        let clipCount = track.items.reduce(0) { count, item in
            if case .clip = item {
                return count + 1
            }
            return count
        }
        if clipCount == 1 {
            return AppString.localized("timeline.track.summary.oneClip", "1 clip")
        }
        if clipCount > 1 {
            return AppString.localized("timeline.track.summary.clips", "\(clipCount) clips")
        }
        return AppString.localized("timeline.track.summary.items", "\(track.items.count) item")
    }

    var fullAccessibilityLabel: String {
        var states: [String] = []
        states.append(
            track.enabled
                ? AppString.localized("timeline.track.state.enabled", "enabled")
                : AppString.localized("timeline.track.state.disabled", "disabled")
        )
        if track.locked {
            states.append(AppString.localized("timeline.track.state.locked", "locked"))
        }
        if kind == .video, track.hidden {
            states.append(AppString.localized("timeline.track.state.hidden", "hidden"))
        }
        if kind == .audio {
            if track.muted {
                states.append(AppString.localized("timeline.track.state.muted", "muted"))
            }
            if track.solo {
                states.append(AppString.localized("timeline.track.state.solo", "solo"))
            }
        }
        return "\(localizedLabel), \(summary), \(states.joined(separator: ", "))"
    }
}

private struct TrackStateButton: View {
    /// Localized visible/spoken title (tooltip + VoiceOver label).
    let title: String
    /// Stable, non-localized identifier queried by UI tests (NFR-I18N-001: identifiers are literal).
    let identifier: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        .frame(width: 28, height: 28)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(
            isOn
                ? AppString.localized("state.on", "On")
                : AppString.localized("state.off", "Off")
        )
    }
}

struct PanelTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

struct EmptyPanelRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(title)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

/// Reports a text field's keyboard focus to the app model (#240 review, finding 1).
///
/// While any scoped text field is focused, the timeline is blurred and plain-key / clipboard
/// timeline shortcuts are inert, so typing can never cut, blade, or delete timeline content.
struct TimelineTextEditingScope: ViewModifier {
    @ObservedObject var model: EditorAjarAppModel
    @FocusState private var isFocused: Bool
    @State private var editorID = UUID()

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                model.textEditorFocusChanged(id: editorID, isFocused: focused)
            }
            .onDisappear {
                model.textEditorFocusChanged(id: editorID, isFocused: false)
            }
    }
}

extension View {
    /// Marks a text field as a timeline-blurring text editing scope (#240 review, finding 1).
    func timelineTextEditingScope(model: EditorAjarAppModel) -> some View {
        modifier(TimelineTextEditingScope(model: model))
    }
}
