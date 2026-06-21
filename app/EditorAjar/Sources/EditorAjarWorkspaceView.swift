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
            Spacer()
        }
        .padding(14)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector panel")
    }
}

private struct TimelineView: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle("Timeline")
            if let sequence = model.activeSequence {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(videoRows(in: sequence), id: \.track.id) { row in
                            TrackLane(
                                sequenceID: sequence.id,
                                row: row,
                                model: model
                            )
                        }
                        ForEach(audioRows(in: sequence), id: \.track.id) { row in
                            TrackLane(
                                sequenceID: sequence.id,
                                row: row,
                                model: model
                            )
                        }
                    }
                }
                .accessibilityIdentifier("Timeline track lanes")
                .accessibilityLabel("Timeline track lanes")
            } else {
                Text("No sequence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.loadMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
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

private struct TrackLane: View {
    let sequenceID: UUID
    let row: TrackLaneRow
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        HStack(spacing: 8) {
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
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08))
                .overlay(alignment: .leading) {
                    Text(row.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }
        }
        .frame(height: 46)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.fullAccessibilityLabel)
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
