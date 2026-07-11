// SPDX-License-Identifier: GPL-3.0-or-later

import Metal
import SwiftUI

/// FR-COL-003 scopes panel — display-only; analysis is throttled in the app model.
struct ScopesPanel: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(AppString.localized("scopes.title", "Scopes"))
                    .font(.callout.weight(.semibold))
                Spacer()
                Picker(
                    AppString.localized("scopes.kind", "Scope"),
                    selection: Binding(
                        get: { model.selectedScopeKind },
                        set: { model.selectScopeKind($0) }
                    )
                ) {
                    ForEach(ScopeDisplayKind.allCases) { kind in
                        Text(kind.localizedTitle)
                            .tag(kind)
                            .accessibilityIdentifier(kind.accessibilityIdentifier)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 160)
                .accessibilityLabel(AppString.localized("scopes.kind.ax", "Scope type"))
                .accessibilityIdentifier("Scope Type Picker")

                Button(AppString.localized("scopes.hide", "Hide Scopes")) {
                    model.toggleScopesPanel()
                }
                .accessibilityLabel(AppString.localized("scopes.hide", "Hide Scopes"))
                .accessibilityIdentifier("Hide Scopes")
            }

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black)
                if let texture = model.scopeDisplayTexture {
                    ProgramMetalView(device: model.metalDevice, texture: texture)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(model.scopeStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                AppString.localized(
                    "scopes.display.ax",
                    "\(model.selectedScopeKind.localizedTitle) scope"
                )
            )
            .accessibilityIdentifier("Scope Display")

            Text(
                AppString.localized(
                    "scopes.budget.note",
                    "Analysis: on texture change when paused (≤ \(ScopeAnalysisThrottle.maxAnalysesPerSecondWhilePlaying)/s while scrubbing); ≤ \(ScopeAnalysisThrottle.maxAnalysesPerSecondWhilePlaying)/s while playing (off the playback hot path)."
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppString.localized("scopes.panel.ax", "Scopes panel"))
        .accessibilityIdentifier("Scopes Panel")
    }
}
