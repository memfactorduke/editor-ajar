// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import Foundation
import SwiftUI

/// Session-only hash-mismatch state for the single-file relink Override alert (FR-MED-007).
struct EditorAjarPendingRelinkMismatch: Equatable, Sendable {
    let mediaID: UUID
    let candidateURL: URL
    let warning: MediaRelinkWarning
}

/// Confirmation sheet for FR-PROJ-003 first-media project settings auto-detection.
struct EditorAjarFirstMediaSettingsProposalView: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                AppString.localized(
                    "document.settings.autoDetect.title",
                    "Use Settings from First Media?"
                )
            )
            .font(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)

            Text(
                AppString.localized(
                    "document.settings.autoDetect.message",
                    "Editor Ajar can match the project to the first imported media. Apply is undoable."
                )
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let proposed = model.proposedFirstMediaSettings {
                VStack(alignment: .leading, spacing: 8) {
                    proposalRow(
                        label: AppString.localized(
                            "document.settings.autoDetect.resolution",
                            "Resolution"
                        ),
                        value: "\(proposed.resolution.width) × \(proposed.resolution.height)"
                    )
                    proposalRow(
                        label: AppString.localized(
                            "document.settings.autoDetect.frameRate",
                            "Frame rate"
                        ),
                        value: String(describing: proposed.frameRate)
                    )
                    proposalRow(
                        label: AppString.localized(
                            "document.settings.autoDetect.colorSpace",
                            "Color space"
                        ),
                        value: proposed.colorSpace.rawValue
                    )
                    proposalRow(
                        label: AppString.localized(
                            "document.settings.autoDetect.audioRate",
                            "Audio sample rate"
                        ),
                        value: "\(proposed.audioSampleRate) Hz"
                    )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    AppString.localized(
                        "document.settings.autoDetect.summary.ax",
                        "Proposed settings"
                    )
                )
            }

            HStack {
                Spacer()
                Button(AppString.localized("document.settings.autoDetect.keep", "Keep Current")) {
                    model.declineProposedFirstMediaSettings()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("Decline First Media Settings")
                Button(AppString.localized("document.settings.autoDetect.apply", "Apply")) {
                    model.applyProposedFirstMediaSettings()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("Apply First Media Settings")
            }
        }
        .padding(24)
        .frame(minWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppString.localized(
                "document.settings.autoDetect.sheet.ax",
                "First media project settings proposal"
            )
        )
        .accessibilityIdentifier("First Media Settings Proposal")
    }

    private func proposalRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

/// Summary sheet after batch folder relink (FR-MED-007 / #246).
struct EditorAjarBatchRelinkSummaryView: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppString.localized("library.relink.batch.title", "Batch Relink Summary"))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if let summary = model.batchRelinkSummary {
                Text(
                    AppString.localized(
                        "library.relink.batch.detail",
                        "\(summary.relinkedMediaIDs.count) relinked, \(summary.unresolvedMediaIDs.count) unmatched"
                    )
                )
                .accessibilityIdentifier("Batch Relink Counts")

                if !summary.relinkedMediaIDs.isEmpty {
                    section(
                        title: AppString.localized(
                            "library.relink.batch.relinked",
                            "Relinked"
                        ),
                        ids: summary.relinkedMediaIDs
                    )
                }
                if !summary.unresolvedMediaIDs.isEmpty {
                    section(
                        title: AppString.localized(
                            "library.relink.batch.unmatched",
                            "Unmatched"
                        ),
                        ids: summary.unresolvedMediaIDs
                    )
                }
            }

            HStack {
                Spacer()
                Button(AppString.localized("library.relink.batch.done", "Done")) {
                    model.dismissBatchRelinkSummary()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("Close Batch Relink Summary")
            }
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 200)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppString.localized("library.relink.batch.sheet.ax", "Batch relink summary")
        )
        .accessibilityIdentifier("Batch Relink Summary")
    }

    private func section(title: String, ids: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ForEach(ids, id: \.self) { mediaID in
                let name = model.project?.mediaPool.first(where: { $0.id == mediaID })?
                    .sourceURL?.lastPathComponent ?? mediaID.uuidString
                Text(name)
                    .font(.callout)
                    .accessibilityLabel(
                        AppString.localized(
                            "library.relink.batch.row.ax",
                            "\(title): \(name)"
                        )
                    )
            }
        }
    }
}
