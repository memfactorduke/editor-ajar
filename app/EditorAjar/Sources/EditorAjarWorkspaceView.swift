// SPDX-License-Identifier: GPL-3.0-or-later

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
            TimelinePlaceholder(model: model)
                .frame(height: 210)
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
                .accessibilityLabel("Playhead \(model.playheadDescription)")
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

private struct TimelinePlaceholder: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle("Timeline")
            VStack(spacing: 8) {
                TrackLane(name: "V1", label: "Video track one")
                TrackLane(name: "A1", label: "Audio track one")
            }
            Spacer()
            Text(model.loadMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline placeholder")
    }
}

private struct TrackLane: View {
    let name: String
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.caption.weight(.semibold))
                .frame(width: 44)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08))
                .overlay(alignment: .leading) {
                    Text("Empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }
        }
        .frame(height: 46)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), empty")
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
