// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import AppKit
import SwiftUI

struct LibraryPanel: View {
    @ObservedObject var model: EditorAjarAppModel
    @State private var layout = MediaBrowserLayout.list
    @State private var query = MediaBrowserQuery()
    @State private var selection = Set<UUID>()

    private var media: [MediaRef] { query.results(in: model.project?.mediaPool ?? []) }
    private var codecs: [String] {
        ["all"] + Set((model.project?.mediaPool ?? []).map(\.metadata.codecID)).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let progress = model.mediaImportProgress { MediaImportProgressView(progress: progress) }
            searchAndFilters
            if media.isEmpty { emptyState } else { results }
            Divider()
            EmptyPanelRow(title: AppString.localized("library.effects", "Effects"), systemImage: "sparkles")
        }
        .padding(10)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppString.localized(
                "library.panel.ax",
                "Media browser. Drop media files or folders here to import."
            )
        )
        .onDisappear {
            model.cancelAllMediaPreviews()
        }
    }

    private var header: some View {
        HStack {
            PanelTitle(AppString.localized("library.title", "Media"))
            Spacer()
            Picker(AppString.localized("library.layout", "Media layout"), selection: $layout) {
                Image(systemName: "list.bullet").tag(MediaBrowserLayout.list)
                Image(systemName: "square.grid.2x2").tag(MediaBrowserLayout.grid)
            }
            .pickerStyle(.segmented)
            .frame(width: 66)
            .labelsHidden()
            .accessibilityLabel(AppString.localized("library.layout", "Media layout"))
            .accessibilityIdentifier("Media Browser Layout")
            Button(action: model.presentMediaImporter) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .disabled(!model.canImportMedia)
                .help(AppString.localized("import.action.help", "Import media files or folders"))
                .accessibilityLabel(
                    AppString.localized("import.action.ax", "Import media files or folders")
                )
                .accessibilityIdentifier("Import Media")
        }
    }

    private var searchAndFilters: some View {
        VStack(spacing: 6) {
            TextField(AppString.localized("library.search", "Search media"), text: $query.searchText)
                .textFieldStyle(.roundedBorder)
                .timelineTextEditingScope(model: model)
                .accessibilityLabel(AppString.localized("library.search", "Search media"))
                .accessibilityIdentifier("Media Search")
            HStack {
                Picker(AppString.localized("library.codec", "Codec"), selection: $query.codec) {
                    ForEach(codecs, id: \.self) {
                        Text(
                            $0 == "all"
                                ? AppString.localized("library.filter.allCodecs", "All codecs")
                                : $0
                        )
                        .tag($0)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(AppString.localized("library.codec", "Codec"))
                Picker(AppString.localized("library.state", "State"), selection: $query.filter) {
                    Text(AppString.localized("library.filter.all", "All"))
                        .tag(MediaBrowserFilter.all)
                    Text(AppString.localized("library.filter.offline", "Offline"))
                        .tag(MediaBrowserFilter.offline)
                    Text(AppString.localized("library.filter.proxyReady", "Proxy ready"))
                        .tag(MediaBrowserFilter.proxyReady)
                    Text(AppString.localized("library.filter.proxyPending", "Proxy pending"))
                        .tag(MediaBrowserFilter.proxyPending)
                }
                .labelsHidden()
                .accessibilityLabel(AppString.localized("library.state", "State"))
            }
        }
    }

    @ViewBuilder private var results: some View {
        switch layout {
        case .list:
            List(media, id: \.id, selection: $selection) {
                MediaBrowserListRow(media: $0, model: model)
            }
            .listStyle(.plain)
            .onChange(of: selection) { model.setSelectedMediaIDs($0) }
        case .grid:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(media, id: \.id) { reference in
                        MediaBrowserGridItem(
                            media: reference,
                            model: model,
                            selected: selection.contains(reference.id)
                        )
                        .onTapGesture { selection = [reference.id] }
                    }
                }
            }
            .onChange(of: selection) { model.setSelectedMediaIDs($0) }
        }
    }

    private var emptyState: some View {
        EmptyPanelRow(
            title: AppString.localized("library.empty", "No matching project media"),
            systemImage: "film.stack"
        )
        .frame(maxHeight: .infinity)
    }
}

private struct MediaBrowserListRow: View {
    let media: MediaRef
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        HStack(spacing: 8) {
            MediaPreviewTile(media: media, model: model).frame(width: 64, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(mediaName).font(.caption.weight(.semibold)).lineLimit(1)
                Text(MediaBrowserText.metadata(media))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                MediaBrowserActions(media: media, model: model)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppString.localized("library.media.row.ax", "Media \(mediaName)"))
        .accessibilityValue(MediaBrowserText.accessibilityValue(media))
        .accessibilityIdentifier("Media Row \(media.id)")
        .draggable(media.id.uuidString)
    }

    private var mediaName: String {
        media.sourceURL?.lastPathComponent
            ?? AppString.localized("library.media.unknown", "Unknown media")
    }
}

private struct MediaBrowserGridItem: View {
    let media: MediaRef
    @ObservedObject var model: EditorAjarAppModel
    let selected: Bool
    @State private var hoverTask: Task<Void, Never>?
    /// Measured tile width for hover-scrub fraction (L3); never a hard-coded 150.
    @State private var measuredWidth: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            MediaPreviewTile(media: media, model: model).frame(height: 86)
            Text(
                media.sourceURL?.lastPathComponent
                    ?? AppString.localized("library.media.unknown", "Unknown media")
            )
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            Text(MediaBrowserText.metadata(media))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            MediaBrowserActions(media: media, model: model)
        }
        .padding(6)
        .background(
            selected ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: MediaBrowserTileWidthKey.self,
                    value: geometry.size.width
                )
            }
        )
        .onPreferenceChange(MediaBrowserTileWidthKey.self) { measuredWidth = max($0, 1) }
        .draggable(media.id.uuidString)
        .onContinuousHover { phase in
            hoverTask?.cancel()
            guard case .active(let point) = phase, !media.isOffline else {
                model.cancelMediaHoverPreview()
                return
            }
            let fraction = max(0, min(1, point.x / measuredWidth))
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                model.requestMediaHoverPreview(mediaID: media.id, fraction: fraction)
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            model.cancelMediaHoverPreview()
            model.cancelMediaPreview(for: media.id)
        }
    }
}

private struct MediaBrowserTileWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MediaPreviewTile: View {
    let media: MediaRef
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7))
            content
            if media.isOffline {
                Label(
                    AppString.localized("library.media.offline", "Offline"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
        .task(id: media.contentHash) {
            await model.requestMediaPreview(for: media)
        }
        .onDisappear {
            model.cancelMediaPreview(for: media.id)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        // Prefer transient hover frame; never let hover overwrite durable thumbnails (M4).
        if let hover = model.mediaHoverPreviewData[media.id], let image = NSImage(data: hover) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if let data = model.mediaThumbnailData[media.id], let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if let waveform = model.mediaWaveformSummary[media.id] {
            MediaWaveformBars(summary: waveform)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
        } else {
            Image(systemName: media.metadata.pixelDimensions == nil ? "waveform" : "film")
                .foregroundStyle(.secondary)
        }
    }
}

/// Simple peak bars from a cached `AudioWaveformSummary` (FR-MED-009 / M6).
private struct MediaWaveformBars: View {
    let summary: AudioWaveformSummary

    var body: some View {
        GeometryReader { geometry in
            let bins = displayBins
            let count = max(bins.count, 1)
            let barWidth = max(1, geometry.size.width / CGFloat(count) * 0.7)
            let spacing = max(0.5, geometry.size.width / CGFloat(count) * 0.3)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bins.enumerated()), id: \.offset) { _, amplitude in
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(
                            width: barWidth,
                            height: max(2, CGFloat(amplitude) * geometry.size.height)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// Downsample to a readable bar count using peak absolute amplitude per bucket.
    private var displayBins: [Float] {
        let source = summary.channels.first?.bins ?? []
        guard !source.isEmpty else { return [] }
        let target = min(48, source.count)
        let group = max(1, source.count / target)
        var result: [Float] = []
        result.reserveCapacity(target)
        var index = 0
        while index < source.count {
            let end = min(index + group, source.count)
            let peak = source[index..<end].map { max(abs($0.minimum), abs($0.maximum)) }.max() ?? 0
            result.append(min(1, peak))
            index = end
        }
        return result
    }
}

private struct MediaBrowserActions: View {
    let media: MediaRef
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        HStack(spacing: 5) {
            Text(MediaBrowserText.proxy(media.proxyState))
                .font(.caption2)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.08), in: Capsule())
            Button(
                media.proxyState.isReady
                    ? AppString.localized("library.proxy.regenerate", "Regenerate")
                    : AppString.localized("library.proxy.generate", "Generate")
            ) {
                model.generateProxy(for: media.id)
            }
            .buttonStyle(.link)
            .disabled(media.isOffline)
            if media.isOffline {
                Button(AppString.localized("library.relink", "Relink…")) {
                    model.presentRelinker(for: media.id)
                }
                .buttonStyle(.link)
            }
        }
    }
}

enum MediaBrowserText {
    static func metadata(_ media: MediaRef) -> String {
        let m = media.metadata
        let dimensions = m.pixelDimensions.map { "\($0.width)×\($0.height)" } ?? "Audio"
        let fps = (m.conformedFrameRate ?? m.frameRate).map(String.init(describing:)) ?? "— fps"
        let vfr = m.isVariableFrameRate ? " VFR→" : ""
        let seconds = m.duration.seconds
        return "\(m.codecID) · \(dimensions) · \(fps)\(vfr) · \(String(format: "%.1fs", seconds)) · \(m.colorSpace.rawValue)"
    }

    static func accessibilityValue(_ media: MediaRef) -> String {
        "\(media.isOffline ? "Offline, " : "")\(metadata(media)), proxy \(proxy(media.proxyState))"
    }

    static func proxy(_ state: MediaProxyState) -> String {
        switch state {
        case .none: "None"
        case .generating: "Generating"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }
}
