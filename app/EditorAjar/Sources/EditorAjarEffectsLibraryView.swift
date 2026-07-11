// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import SwiftUI

/// FR-FX-002 browsable built-in effects library (replaces the media-panel Effects placeholder).
struct EffectsLibrarySection: View {
    @ObservedObject var model: EditorAjarAppModel
    @State private var searchText = ""

    private var items: [EffectLibraryItem] {
        EffectLibraryItem.filtered(searchText: searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    AppString.localized("library.effects", "Effects"),
                    systemImage: "sparkles"
                )
                .font(.callout.weight(.semibold))
                Spacer()
            }

            TextField(
                AppString.localized("effects.library.search", "Search effects"),
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .timelineTextEditingScope(model: model)
            .accessibilityLabel(
                AppString.localized("effects.library.search", "Search effects")
            )
            .accessibilityIdentifier("Effects Library Search")

            if items.isEmpty {
                Text(
                    AppString.localized(
                        "effects.library.empty",
                        "No matching effects"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            EffectLibraryRow(item: item, model: model)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Effects Library")
        .accessibilityLabel(
            AppString.localized("effects.library.ax", "Effects library")
        )
    }
}

struct EffectLibraryRow: View {
    let item: EffectLibraryItem
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.localizedName)
                    .font(.caption)
                    .lineLimit(1)
                Text(item.localizedCategory)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(AppString.localized("effects.library.add", "Add")) {
                _ = model.addEffectToSelectedClip(kind: item.kind)
            }
            .controlSize(.mini)
            .disabled(!model.canAddEffectToSelectedClip)
            .accessibilityLabel(
                AppString.localized(
                    "effects.library.add.ax",
                    "Add \(item.localizedName) to selected clip"
                )
            )
            .accessibilityIdentifier("Effect Library Add \(item.kind.rawValue)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard model.canAddEffectToSelectedClip else { return }
            _ = model.addEffectToSelectedClip(kind: item.kind)
        }
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppString.localized(
                "effects.library.row.ax",
                "\(item.localizedName), \(item.localizedCategory)"
            )
        )
        .accessibilityIdentifier("Effect Library Row \(item.kind.rawValue)")
        .accessibilityHint(
            AppString.localized(
                "effects.library.row.hint",
                "Double-click or press Add to append to the selected clip"
            )
        )
    }
}
