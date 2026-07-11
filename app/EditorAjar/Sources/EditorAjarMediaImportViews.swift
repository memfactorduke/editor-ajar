// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import SwiftUI

/// Media-pool surface with import action and non-modal background progress (FR-MED-001).
struct LibraryPanel: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PanelTitle(AppString.localized("library.title", "Media"))
                Spacer()
                Button {
                    model.presentMediaImporter()
                } label: {
                    Label(
                        AppString.localized("import.action", "Import Media…"),
                        systemImage: "plus"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canImportMedia)
                .help(AppString.localized("import.action.help", "Import media files or folders"))
                .accessibilityLabel(
                    AppString.localized("import.action.ax", "Import media files or folders")
                )
                .accessibilityIdentifier("Import Media")
            }

            if let progress = model.mediaImportProgress {
                MediaImportProgressView(progress: progress)
            }

            Text(AppString.localized("library.projectMedia", "Project Media"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let media = model.project?.mediaPool, !media.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(media, id: \.id) { reference in
                            MediaPoolRow(reference: reference)
                        }
                    }
                }
            } else {
                EmptyPanelRow(
                    title: AppString.localized("library.empty", "No project media"),
                    systemImage: "film.stack"
                )
            }

            Divider()
            EmptyPanelRow(
                title: AppString.localized("library.effects", "Effects"),
                systemImage: "sparkles"
            )
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppString.localized(
                "library.panel.ax",
                "Media and effects panel. Drop media files or folders here to import."
            )
        )
    }
}

private struct MediaPoolRow: View {
    let reference: MediaRef

    private var filename: String {
        reference.sourceURL?.lastPathComponent
            ?? AppString.localized("library.media.unknown", "Unknown media")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: reference.isOffline ? "exclamationmark.triangle" : "film")
                .foregroundStyle(reference.isOffline ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(filename)
                    .font(.caption)
                    .lineLimit(1)
                Text(reference.metadata.codecID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppString.localized("library.media.row.ax", "Media \(filename)"))
        .accessibilityValue(
            reference.isOffline
                ? AppString.localized("library.media.offline", "Offline")
                : reference.metadata.codecID
        )
    }
}

private struct MediaImportProgressView: View {
    let progress: MediaImportProgress

    private var label: String {
        switch progress.phase {
        case .discovering:
            return AppString.localized("import.progress.discovering", "Scanning folders…")
        case .importing:
            if let filename = progress.currentFileURL?.lastPathComponent {
                return AppString.localized("import.progress.file", "Importing \(filename)")
            }
            return AppString.localized("import.progress.preparing", "Preparing import…")
        }
    }

    private var value: String {
        AppString.localized(
            "import.progress.value",
            "\(progress.completedUnitCount) of \(progress.totalUnitCount) files"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .lineLimit(1)
            if progress.phase == .discovering || progress.totalUnitCount == 0 {
                ProgressView()
                    .controlSize(.small)
            } else {
                ProgressView(value: progress.fractionCompleted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier("Media Import Progress")
    }
}

/// Categorized, keyboard-dismissible import result sheet.
struct EditorAjarMediaImportSummaryView: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppString.localized("import.summary.title", "Media Import Summary"))
                .font(.title2.weight(.semibold))

            ScrollView {
                if let summary = model.mediaImportSummary {
                    VStack(alignment: .leading, spacing: 18) {
                        if summary.isEmpty {
                            Text(
                                AppString.localized(
                                    "import.summary.empty",
                                    "No media files were found in the selection."
                                )
                            )
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("Empty Media Import Summary")
                        }
                        ImportSummarySection(
                            title: AppString.localized("import.summary.imported", "Imported"),
                            systemImage: "checkmark.circle",
                            rows: summary.imported.map { item in
                                ImportSummaryRowValue(
                                    filename: item.sourceURL.lastPathComponent,
                                    detail: importedDetail(item.mediaReference)
                                )
                            }
                        )
                        ImportSummarySection(
                            title: AppString.localized(
                                "import.summary.duplicates",
                                "Skipped Duplicates"
                            ),
                            systemImage: "doc.on.doc",
                            rows: summary.skippedDuplicates.map { item in
                                ImportSummaryRowValue(
                                    filename: item.sourceURL.lastPathComponent,
                                    detail: AppString.localized(
                                        "import.summary.duplicate.reason",
                                        "Same content is already in the media pool. The existing location and bookmark were kept."
                                    )
                                )
                            }
                        )
                        ImportSummarySection(
                            title: AppString.localized(
                                "import.summary.vfrConformed",
                                "Variable Frame Rate Conformed"
                            ),
                            systemImage: "metronome",
                            rows: summary.vfrConformed.map { item in
                                ImportSummaryRowValue(
                                    filename: item.sourceURL.lastPathComponent,
                                    detail: AppString.localized(
                                        "import.summary.vfr.reason",
                                        "Stable timebase: \(item.conformedFrameRate.description)"
                                    )
                                )
                            }
                        )
                        ImportSummarySection(
                            title: AppString.localized("import.summary.failed", "Failed"),
                            systemImage: "exclamationmark.triangle",
                            rows: summary.failed.map { item in
                                ImportSummaryRowValue(
                                    filename: item.sourceURL.lastPathComponent,
                                    detail: AppString.mediaImportFailureMessage(for: item.error)
                                )
                            }
                        )
                    }
                }
            }

            HStack {
                Spacer()
                Button(AppString.localized("import.summary.done", "Done")) {
                    model.dismissMediaImportSummary()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(
                    AppString.localized("import.summary.done.ax", "Close media import summary")
                )
                .accessibilityIdentifier("Close Media Import Summary")
            }
        }
        .padding(24)
        .frame(width: 620, height: 520)
        .onExitCommand {
            model.dismissMediaImportSummary()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppString.localized("import.summary.sheet.ax", "Media import summary")
        )
        .accessibilityIdentifier("Media Import Summary")
    }

    private func importedDetail(_ reference: MediaRef) -> String {
        let dimensions: String
        if let pixels = reference.metadata.pixelDimensions {
            dimensions = "\(pixels.width)×\(pixels.height)"
        } else {
            dimensions = AppString.localized("import.summary.audioOnly", "audio only")
        }
        return AppString.localized(
            "import.summary.imported.detail",
            "\(reference.metadata.codecID), \(dimensions)"
        )
    }
}

private struct ImportSummarySection: View {
    let title: String
    let systemImage: String
    let rows: [ImportSummaryRowValue]

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    AppString.localized(
                        "import.summary.section.count",
                        "\(title) (\(rows.count))"
                    ),
                    systemImage: systemImage
                )
                    .font(.headline)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.filename)
                            .font(.body.weight(.medium))
                        Text(row.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        AppString.localized(
                            "import.summary.row.ax",
                            "\(title): \(row.filename)"
                        )
                    )
                    .accessibilityValue(row.detail)
                }
            }
        }
    }
}

private struct ImportSummaryRowValue {
    let filename: String
    let detail: String
}
