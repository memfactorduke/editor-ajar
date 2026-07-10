// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import SwiftUI

struct EditorAjarWorkspaceView: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isReadOnlyBannerVisible {
                ReadOnlyProjectBanner(model: model)
            }
            header
            SequenceTabsBar(model: model)
            Divider()
            HStack(spacing: 0) {
                LibraryPanel()
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

    private var header: some View {
        HStack(spacing: 12) {
            Text("Editor Ajar")
                .font(.headline)
            Spacer()
            Text(model.projectSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Export…") {
                model.presentExportDialog()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .accessibilityLabel("Open export dialog")
            .accessibilityIdentifier("Open Export Dialog")
            Button(model.isExportQueuePanelVisible ? "Hide Exports" : "Exports") {
                model.toggleExportQueuePanel()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("e", modifiers: [.command, .control])
            .help("Show or hide the background export queue")
            .accessibilityLabel(
                model.isExportQueuePanelVisible
                    ? "Hide export queue"
                    : "Show export queue"
            )
            .accessibilityIdentifier("Toggle Export Queue")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor Ajar, \(model.projectSummary)")
    }
}

/// Workspace banner for FR-PROJ-005 read-only opens (higher schema minor / ADR-0018).
private struct ReadOnlyProjectBanner: View {
    @ObservedObject var model: EditorAjarAppModel

    private var message: String {
        model.readOnlyBannerMessage ?? "This project is open read-only."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.orange)
                .accessibilityHidden(true)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Read-only project")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Dismiss") {
                model.dismissReadOnlyBanner()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .help("Dismiss read-only notice")
            .accessibilityLabel("Dismiss read-only project notice")
            .accessibilityIdentifier("Dismiss Read-Only Banner")
            .accessibilityHint("Hides the read-only banner. Editing and saving remain disabled.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.18))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Read-Only Project Banner")
        .accessibilityLabel("Read-only project notice")
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
            .accessibilityLabel("Sequence tabs")

            Button {
                model.addSequence()
            } label: {
                Label("New Sequence", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .frame(width: 30, height: 28)
            .help("New Sequence")
            .accessibilityLabel("New Sequence")
            .accessibilityIdentifier("New Sequence")

            Button {
                model.closeActiveSequence()
            } label: {
                Label("Close Sequence", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .frame(width: 30, height: 28)
            .help("Close Sequence")
            .accessibilityLabel("Close Sequence")
            .accessibilityIdentifier("Close Sequence")
            .disabled(!model.canCloseActiveSequence)
        }
        .padding(.trailing, 12)
        .frame(height: 38)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Sequence tab bar")
        .accessibilityLabel("Sequence tab bar")
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
            .accessibilityLabel("Sequence tab \(tab.title)")
            .accessibilityValue(tab.isActive ? "Selected" : "Not selected")
            .accessibilityIdentifier("Sequence tab \(tab.title)")

            Button {
                model.closeSequence(tab.id)
            } label: {
                Label("Close \(tab.title)", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.caption2.weight(.semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Close \(tab.title)")
            .accessibilityLabel("Close \(tab.title)")
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

private struct LibraryPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelTitle("Media")
            EmptyPanelRow(title: "Project Media", systemImage: "film.stack")
            EmptyPanelRow(title: "Effects", systemImage: "sparkles")
            Spacer()
        }
        .padding(14)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Media and effects panel")
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
            .background(Color.black)
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
        .accessibilityIdentifier("Canvas Safe Area Guides Toggle")
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(model.canvasSafeAreaGuidesVisible ? "On" : "Off")
    }

    private var toggleLabel: some View {
        Label(accessibilityTitle, systemImage: "rectangle.inset.filled")
    }

    private var accessibilityTitle: String {
        model.canvasSafeAreaGuidesVisible
            ? "Hide Action and Title Safe Guides"
            : "Show Action and Title Safe Guides"
    }

    private var helpText: String {
        model.canvasSafeAreaGuidesVisible
            ? "Hide action-safe and title-safe guides"
            : "Show action-safe and title-safe guides"
    }
}

private struct TransportBar: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            Button(action: model.stepBackward) {
                Label("Step Backward", systemImage: "backward.frame.fill")
                    .labelStyle(.iconOnly)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Step Backward")
            .accessibilityLabel("Step Backward")

            Button(action: model.togglePlayback) {
                Label(
                    model.isPlaying ? "Pause" : "Play",
                    systemImage: model.isPlaying ? "pause.fill" : "play.fill"
                )
                .labelStyle(.iconOnly)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(model.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            Button(action: model.stepForward) {
                Label("Step Forward", systemImage: "forward.frame.fill")
                    .labelStyle(.iconOnly)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Step Forward")
            .accessibilityLabel("Step Forward")

            Text(model.playheadDescription)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 96, alignment: .leading)
                .accessibilityIdentifier("Playhead readout")
                .accessibilityLabel("Playhead")
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
            .accessibilityLabel("Scrub playhead")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Transport controls")
        .accessibilityLabel("Transport controls")
    }
}

private struct InspectorPanel: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelTitle("Inspector")
            DetailRow(label: "Sequence", value: model.activeSequenceName)
            DetailRow(label: "Frame Rate", value: model.frameRateDescription)
            DetailRow(label: "State", value: model.isPlaying ? "Playing" : "Paused")
            Divider()
            if let marker = model.selectedMarker {
                MarkerInspector(marker: marker, model: model)
            } else if let transformState = model.selectedTransformInspector {
                TransformInspector(state: transformState, model: model)
            } else {
                DetailRow(label: "Marker", value: "None selected")
                DetailRow(label: "Transform", value: "Select one video clip")
            }
            Spacer()
        }
        .padding(14)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector panel")
    }
}

private struct MarkerInspector: View {
    let marker: Marker
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Marker", systemImage: "flag.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(marker.color.swatchColor)
                Spacer()
                Button(role: .destructive, action: model.deleteSelectedMarker) {
                    Label("Delete Marker", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Delete Marker")
                .accessibilityLabel("Delete Marker")
            }

            TextField(
                "Marker Name",
                text: Binding(
                    get: { model.selectedMarker?.name ?? "" },
                    set: { model.updateSelectedMarker(name: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Marker Name")

            Picker(
                "Marker Color",
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
            .accessibilityLabel("Marker Color")

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
            .accessibilityLabel("Marker Note")

            DetailRow(label: "Position", value: "Frame \(markerFrameDescription(marker))")
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
                    .accessibilityLabel("Timeline track lanes")
                } else {
                    Text("No sequence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                footer
            }
            .padding(14)
            .background(Color(red: 0.12, green: 0.12, blue: 0.13))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Timeline")
            .accessibilityLabel("Timeline")
        }
    }

    private func toolbar(availableWidth: Double) -> some View {
        HStack(spacing: 8) {
            PanelTitle("Timeline")
            Spacer()
            TimelineToolButton(title: "Add Marker", systemImage: "flag.fill") {
                model.addTimelineMarkerAtPlayhead()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            TimelineToolButton(title: "Previous Marker", systemImage: "arrow.left.to.line") {
                model.jumpToPreviousMarker()
            }
            .keyboardShortcut("[", modifiers: [.command])
            TimelineToolButton(title: "Next Marker", systemImage: "arrow.right.to.line") {
                model.jumpToNextMarker()
            }
            .keyboardShortcut("]", modifiers: [.command])
            TimelineToolButton(title: "Delete Marker", systemImage: "trash") {
                model.deleteSelectedMarker()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(model.selectedMarker == nil)
            TimelineToolButton(title: "Detach Audio", systemImage: "speaker.slash.fill") {
                model.detachAudioForSelectedClip()
            }
            .disabled(!model.selectedClipIsLinked)
            TimelineToolButton(title: "Zoom Timeline Out", systemImage: "minus.magnifyingglass") {
                model.zoomTimelineOut()
            }
            TimelineToolButton(title: "Zoom Timeline In", systemImage: "plus.magnifyingglass") {
                model.zoomTimelineIn()
            }
            TimelineToolButton(
                title: "Decrease Track Height", systemImage: "arrow.down.to.line.compact"
            ) {
                model.zoomTimelineVerticallyOut()
            }
            TimelineToolButton(
                title: "Increase Track Height", systemImage: "arrow.up.to.line.compact"
            ) {
                model.zoomTimelineVerticallyIn()
            }
            TimelineToolButton(title: "Fit Timeline", systemImage: "arrow.left.and.right") {
                model.fitTimeline(toWidth: availableWidth)
            }
            TimelineToolButton(title: "Zoom to Selection", systemImage: "selection.pin.in.out") {
                model.zoomTimelineToSelection(toWidth: availableWidth)
            }
            TimelineToolButton(
                title: "Set Range In", systemImage: "inset.filled.leadinghalf.rectangle"
            ) {
                model.setTimelineRangeIn()
            }
            .keyboardShortcut("i", modifiers: [])
            TimelineToolButton(
                title: "Set Range Out", systemImage: "inset.filled.trailinghalf.rectangle"
            ) {
                model.setTimelineRangeOut()
            }
            .keyboardShortcut("o", modifiers: [])
            TimelineToolButton(title: "Clear Timeline Range", systemImage: "xmark.rectangle") {
                model.clearTimelineRange()
            }
            TimelineToolButton(
                title: model.timelineSnappingEnabled ? "Disable Snapping" : "Enable Snapping",
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
            Text("\(model.timelineSelectedClipCount) selected")
            Spacer()
            Text(model.loadMessage)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Timeline status, \(model.timelineRangeDescription), \(model.timelineSelectedClipCount) selected"
        )
    }

    private func videoRows(in sequence: AjarCore.Sequence) -> [TrackLaneRow] {
        sequence.videoTracks.enumerated().reversed().map { index, track in
            TrackLaneRow(
                name: "V\(index + 1)",
                kind: .video,
                track: track,
                accessibilityLabel: "Video track \(index + 1)"
            )
        }
    }

    private func audioRows(in sequence: AjarCore.Sequence) -> [TrackLaneRow] {
        sequence.audioTracks.enumerated().map { index, track in
            TrackLaneRow(
                name: "A\(index + 1)",
                kind: .audio,
                track: track,
                accessibilityLabel: "Audio track \(index + 1)"
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
            Text("Frame 0")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline ruler")
        .accessibilityValue(model.playheadDescription)
        .help("Drag to scrub")
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
        .help("\(layout.name), frame \(layout.frame)")
        .accessibilityLabel("Marker \(layout.name)")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("Timeline marker \(layout.markerID.uuidString)")
    }

    private var accessibilityValue: String {
        let note = layout.note.isEmpty ? "No note" : layout.note
        return
            "\(isSelected ? "Selected" : "Not selected"), \(layout.color.displayName), frame \(layout.frame), \(note)"
    }
}

private struct TimelineToolButton: View {
    let title: String
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
    }
}

private extension MarkerColor {
    var displayName: String {
        switch self {
        case .gray:
            return "Gray"
        case .red:
            return "Red"
        case .orange:
            return "Orange"
        case .yellow:
            return "Yellow"
        case .green:
            return "Green"
        case .blue:
            return "Blue"
        case .purple:
            return "Purple"
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
            return "Normal"
        case .multiply:
            return "Multiply"
        case .screen:
            return "Screen"
        case .overlay:
            return "Overlay"
        case .add:
            return "Add"
        case .darken:
            return "Darken"
        case .lighten:
            return "Lighten"
        case .colorDodge:
            return "Color Dodge"
        case .colorBurn:
            return "Color Burn"
        case .hardLight:
            return "Hard Light"
        case .softLight:
            return "Soft Light"
        case .difference:
            return "Difference"
        case .exclusion:
            return "Exclusion"
        case .subtract:
            return "Subtract"
        case .hue:
            return "Hue"
        case .saturation:
            return "Saturation"
        case .color:
            return "Color"
        case .luminosity:
            return "Luminosity"
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
                title: "Select all \(row.accessibilityLabel)",
                systemImage: "checkmark.circle",
                isOn: false
            ) {
                model.selectAllClips(on: row.track.id)
            }
        }
        .frame(width: TimelineLayoutMetrics.trackHeaderWidth, alignment: .leading)
    }

    private var timelineContent: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08))
            ForEach(model.timelineClipLayouts(for: row.track), id: \.reference) { layout in
                TimelineClipBlock(
                    layout: layout,
                    isSelected: model.isClipSelected(layout.reference),
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
                    model.selectClip(
                        trackID: layout.reference.trackID,
                        clipID: layout.reference.clipID,
                        mode: .replace
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
    let keyframeLanes: [TransformKeyframeLane]
    let pixelsPerFrame: Double
    let addKeyframe: (ClipTransformParameter, Int64) -> Void
    let moveKeyframe: (ClipTransformParameter, Int64, Int64) -> Void
    let deleteKeyframe: (ClipTransformParameter, Int64) -> Void
    let action: () -> Void

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
            .help("\(layout.name), frames \(layout.startFrame)-\(layout.endFrame)")
            .accessibilityLabel("Clip \(layout.name)")
            .accessibilityValue(
                "\(isSelected ? "Selected" : "Not selected"), frames \(layout.startFrame)-\(layout.endFrame)"
            )
            .accessibilityIdentifier("Timeline clip \(layout.reference.clipID.uuidString)")

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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Transform Inspector")
        .accessibilityLabel("Transform Inspector")
    }
}

private struct TransformFieldGrid: View {
    let fields: [TransformInspectorField]
    let keyframeParameter: ClipTransformParameter
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(keyframeParameter.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                TransformKeyframeToggle(parameter: keyframeParameter, model: model)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(fields) { field in
                    TransformNumberField(field: field, model: model)
                }
            }
        }
    }
}

private struct TransformNumberField: View {
    let field: TransformInspectorField
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(
                field.title,
                text: Binding(
                    get: { model.transformFieldValue(field) },
                    set: { model.updateSelectedTransformField(field, rawValue: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(field.title)
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
                    ? "Delete \(parameter.displayName) Keyframe"
                    : "Add \(parameter.displayName) Keyframe",
                systemImage: hasKeyframe ? "diamond.fill" : "diamond"
            )
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(hasKeyframe ? "Delete keyframe at playhead" : "Add keyframe at playhead")
        .accessibilityLabel(
            hasKeyframe
                ? "Delete \(parameter.displayName) Keyframe"
                : "Add \(parameter.displayName) Keyframe"
        )
        .accessibilityIdentifier("Transform \(parameter.displayName) Keyframe Toggle")
    }
}

private struct TransformBlendPicker: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        Picker(
            "Blend",
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
        .accessibilityLabel("Blend Mode")
        .accessibilityIdentifier("Transform Blend Mode")
    }
}

private struct TrackCompositingInspector: View {
    let state: SelectedTrackCompositingInspectorState
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Track Compositing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(state.trackName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(
                "Opacity %",
                text: Binding(
                    get: { model.selectedTrackOpacityPercentValue() },
                    set: { model.updateSelectedTrackOpacityPercent(rawValue: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Track Opacity Percent")
            .accessibilityIdentifier("Track Opacity Percent")
            Picker(
                "Track Blend",
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
            .accessibilityLabel("Track Blend Mode")
            .accessibilityIdentifier("Track Blend Mode")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Track Compositing Inspector")
        .accessibilityLabel("Track Compositing Inspector")
    }
}

private struct TransformFlipControls: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Flip")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle(
                "Horizontal",
                isOn: Binding(
                    get: { model.selectedTransformInspector?.transform.flip.horizontal ?? false },
                    set: { model.updateSelectedClipFlip(horizontal: $0) }
                )
            )
            .accessibilityIdentifier("Transform Flip Horizontal")
            Toggle(
                "Vertical",
                isOn: Binding(
                    get: { model.selectedTransformInspector?.transform.flip.vertical ?? false },
                    set: { model.updateSelectedClipFlip(vertical: $0) }
                )
            )
            .accessibilityIdentifier("Transform Flip Vertical")
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
                        title: "Scale Transform",
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        position: CGPoint(x: metrics.rect.maxX, y: metrics.rect.maxY),
                        handle: .scaleBottomRight,
                        canvasScale: metrics.scale
                    )
                    transformHandle(
                        title: "Rotate Transform",
                        systemImage: "rotate.right",
                        position: CGPoint(x: metrics.rect.midX, y: metrics.rect.minY - 28),
                        handle: .rotate,
                        canvasScale: metrics.scale
                    )
                    transformHandle(
                        title: "Move Anchor",
                        systemImage: "scope",
                        position: metrics.anchorPoint,
                        handle: .anchor,
                        canvasScale: metrics.scale
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("Program Transform Overlay")
                .accessibilityLabel("Program Transform Overlay")
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
            .accessibilityLabel("Move Transform")
            .accessibilityIdentifier("Program Move Transform")
    }

    private func transformReadout(
        metrics: CanvasOverlayMetrics, transform: ClipTransform
    ) -> some View {
        Text(readout(transform))
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
            .offset(x: metrics.rect.minX, y: max(0, metrics.rect.minY - 24))
            .accessibilityIdentifier("Program Transform Readout")
    }

    private func transformHandle(
        title: String,
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
            .accessibilityLabel(title)
            .accessibilityIdentifier("Program \(title)")
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
        .accessibilityLabel("Transform keyframe lanes")
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
        .accessibilityLabel("Transform keyframe lane \(lane.title)")
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
        .help("\(lane.title) keyframe, frame \(point.frame)")
        .accessibilityLabel("\(lane.title) keyframe")
        .accessibilityValue("Frame \(point.frame)")
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
    let accessibilityLabel: String

    var summary: String {
        guard !track.items.isEmpty else {
            return "Empty"
        }
        let clipCount = track.items.reduce(0) { count, item in
            if case .clip = item {
                return count + 1
            }
            return count
        }
        if clipCount == 1 {
            return "1 clip"
        }
        if clipCount > 1 {
            return "\(clipCount) clips"
        }
        return "\(track.items.count) item"
    }

    var fullAccessibilityLabel: String {
        var states: [String] = []
        states.append(track.enabled ? "enabled" : "disabled")
        if track.locked {
            states.append("locked")
        }
        if kind == .video, track.hidden {
            states.append("hidden")
        }
        if kind == .audio {
            if track.muted {
                states.append("muted")
            }
            if track.solo {
                states.append("solo")
            }
        }
        return "\(accessibilityLabel), \(summary), \(states.joined(separator: ", "))"
    }
}

private struct TrackStateButton: View {
    let title: String
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
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct PanelTitle: View {
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

private struct EmptyPanelRow: View {
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
