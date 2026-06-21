// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import SwiftUI

struct EditorAjarWorkspaceView: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(spacing: 0) {
            header
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
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.11))
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Editor Ajar")
                .font(.headline)
            Spacer()
            Text(model.projectSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Editor Ajar, \(model.projectSummary)")
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

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                ProgramMetalView(device: model.metalDevice, texture: model.presentedTexture)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)

                if model.presentedTexture == nil {
                    VStack(spacing: 6) {
                        Text(model.activeSequenceName)
                            .font(.title3.weight(.semibold))
                        Text(model.loadMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Program monitor showing \(model.activeSequenceName)")

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
            } else {
                DetailRow(label: "Marker", value: "None selected")
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
            let timelineWidth = TimelineLayoutMetrics.trackContentLeadingOffset + timelineContentWidth
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
            TimelineToolButton(title: "Zoom Timeline Out", systemImage: "minus.magnifyingglass") {
                model.zoomTimelineOut()
            }
            TimelineToolButton(title: "Zoom Timeline In", systemImage: "plus.magnifyingglass") {
                model.zoomTimelineIn()
            }
            TimelineToolButton(title: "Decrease Track Height", systemImage: "arrow.down.to.line.compact") {
                model.zoomTimelineVerticallyOut()
            }
            TimelineToolButton(title: "Increase Track Height", systemImage: "arrow.up.to.line.compact") {
                model.zoomTimelineVerticallyIn()
            }
            TimelineToolButton(title: "Fit Timeline", systemImage: "arrow.left.and.right") {
                model.fitTimeline(toWidth: availableWidth)
            }
            TimelineToolButton(title: "Zoom to Selection", systemImage: "selection.pin.in.out") {
                model.zoomTimelineToSelection(toWidth: availableWidth)
            }
            TimelineToolButton(title: "Set Range In", systemImage: "inset.filled.leadinghalf.rectangle") {
                model.setTimelineRangeIn()
            }
            .keyboardShortcut("i", modifiers: [])
            TimelineToolButton(title: "Set Range Out", systemImage: "inset.filled.trailinghalf.rectangle") {
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
                        xPosition: value.location.x - TimelineLayoutMetrics.trackContentLeadingOffset
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
        return "\(isSelected ? "Selected" : "Not selected"), \(layout.color.displayName), frame \(layout.frame), \(note)"
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
                title: row.track.enabled ? "Disable \(row.accessibilityLabel)" : "Enable \(row.accessibilityLabel)",
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
                title: row.track.locked ? "Unlock \(row.accessibilityLabel)" : "Lock \(row.accessibilityLabel)",
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
                    title: row.track.hidden ? "Show \(row.accessibilityLabel)" : "Hide \(row.accessibilityLabel)",
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
                    title: row.track.muted ? "Unmute \(row.accessibilityLabel)" : "Mute \(row.accessibilityLabel)",
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
                    title: row.track.solo ? "Unsolo \(row.accessibilityLabel)" : "Solo \(row.accessibilityLabel)",
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
                    isSelected: model.isClipSelected(layout.reference)
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
        .frame(width: max(1, timelineContentWidth), height: max(24, model.timelineState.laneHeight - 8))
    }
}

private struct TimelineClipBlock: View {
    let layout: TimelineClipLayout
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
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
        .background(
            isSelected ? Color.accentColor : Color.white.opacity(0.16),
            in: RoundedRectangle(cornerRadius: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.white.opacity(0.7) : Color.white.opacity(0.18), lineWidth: 1)
        )
        .help("\(layout.name), frames \(layout.startFrame)-\(layout.endFrame)")
        .accessibilityLabel("Clip \(layout.name)")
        .accessibilityValue(
            "\(isSelected ? "Selected" : "Not selected"), frames \(layout.startFrame)-\(layout.endFrame)"
        )
        .accessibilityIdentifier("Timeline clip \(layout.reference.clipID.uuidString)")
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
