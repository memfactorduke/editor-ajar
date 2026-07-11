// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import SwiftUI

/// FR-COL-001 color inspector + FR-COL-004 LUT + FR-COL-007 looks list.
///
/// Extracted from `InspectorPanel` so the transform inspector type-check budget stays intact.
struct ColorInspector: View {
    let state: SelectedColorInspectorState
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(state.clipName, systemImage: "paintpalette")
                    .font(.callout.weight(.semibold))

                Text(AppString.localized(
                    "color.staticNote",
                    "Primary grade is static in v1 (no color keyframes yet)."
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ColorChannelGroupControls(group: .lift, model: model)
                ColorChannelGroupControls(group: .gamma, model: model)
                ColorChannelGroupControls(group: .gain, model: model)

                ForEach(ColorInspectorScalarField.allCases) { field in
                    ColorScalarSlider(field: field, model: model)
                }

                Button(AppString.localized("color.resetAll", "Reset All Color")) {
                    model.resetSelectedClipColorCorrection()
                }
                .disabled(!model.isProjectEditable)
                .accessibilityLabel(AppString.localized("color.resetAll", "Reset All Color"))
                .accessibilityIdentifier("Color Reset All")

                Divider()
                ColorLUTSection(state: state, model: model)

                Divider()
                ColorLooksSection(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Color Inspector")
        .accessibilityLabel(AppString.localized("inspector.color.ax", "Color Inspector"))
    }
}

struct ColorChannelGroupControls: View {
    let group: ColorInspectorChannelGroup
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(group.localizedTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(AppString.localized("color.reset", "Reset")) {
                    model.resetSelectedColorChannelGroup(group)
                }
                .controlSize(.mini)
                .disabled(!model.isProjectEditable)
                .accessibilityLabel(
                    AppString.localized(
                        "color.reset.group",
                        "Reset \(group.localizedTitle)"
                    )
                )
                .accessibilityIdentifier("Color Reset \(group.title)")
            }
            ForEach(ColorInspectorChannelComponent.allCases) { component in
                ColorChannelSlider(group: group, component: component, model: model)
            }
        }
    }
}

struct ColorChannelSlider: View {
    let group: ColorInspectorChannelGroup
    let component: ColorInspectorChannelComponent
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        let channels =
            model.selectedColorInspector.map { group.channels(in: $0.correction) } ?? group.identity
        let currentValue = component.value(in: channels)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(component.localizedTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ColorFieldValueMapper.string(from: currentValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: {
                        let channels =
                            model.selectedColorInspector.map { group.channels(in: $0.correction) }
                            ?? group.identity
                        return component.value(in: channels).doubleValue
                    },
                    set: { model.setSelectedColorChannel(group: group, component: component, doubleValue: $0) }
                ),
                in: group.range,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        model.endColorCorrectionSliderGesture()
                    }
                }
            )
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(
                AppString.localized(
                    "color.channel.slider.ax",
                    "\(group.localizedTitle) \(component.localizedTitle)"
                )
            )
            .accessibilityIdentifier("Color \(group.title) \(component.rawValue.capitalized)")
            .accessibilityValue(ColorFieldValueMapper.string(from: currentValue))
        }
    }
}

struct ColorScalarSlider: View {
    let field: ColorInspectorScalarField
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        let value =
            model.selectedColorInspector.map { field.value(in: $0.correction) } ?? field.identity
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(field.localizedTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ColorFieldValueMapper.string(from: value))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(AppString.localized("color.reset", "Reset")) {
                    model.resetSelectedColorScalar(field)
                }
                .controlSize(.mini)
                .disabled(!model.isProjectEditable)
                .accessibilityLabel(
                    AppString.localized("color.reset.field", "Reset \(field.localizedTitle)")
                )
                .accessibilityIdentifier("Color Reset \(field.title)")
            }
            Slider(
                value: Binding(
                    get: {
                        (model.selectedColorInspector.map { field.value(in: $0.correction) }
                            ?? field.identity).doubleValue
                    },
                    set: { model.setSelectedColorScalar(field, doubleValue: $0) }
                ),
                in: field.range,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        model.endColorCorrectionSliderGesture()
                    }
                }
            )
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(field.localizedTitle)
            .accessibilityIdentifier(field.accessibilityIdentifier)
            .accessibilityValue(ColorFieldValueMapper.string(from: value))
        }
    }
}

struct ColorLUTSection: View {
    let state: SelectedColorInspectorState
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppString.localized("color.lut.heading", "LUT"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Button(AppString.localized("color.lut.import", "Import .cube LUT…")) {
                model.presentLUTImporter()
            }
            .disabled(!model.canImportLUT)
            .accessibilityLabel(AppString.localized("color.lut.import.ax", "Import cube LUT"))
            .accessibilityIdentifier("Import LUT")

            if state.hasLUT {
                if let title = state.lutTitle, !title.isEmpty {
                    Text(title)
                        .font(.caption)
                        .lineLimit(1)
                        .accessibilityLabel(
                            AppString.localized("color.lut.title.ax", "LUT title \(title)")
                        )
                }
                HStack {
                    Text(AppString.localized("color.lut.strength", "Strength"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ColorFieldValueMapper.string(from: state.lutStrength))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { state.lutStrength.doubleValue },
                        set: { model.setSelectedLUTStrength(doubleValue: $0) }
                    ),
                    in: 0...1
                )
                .disabled(!model.isProjectEditable)
                .accessibilityLabel(AppString.localized("color.lut.strength", "Strength"))
                .accessibilityIdentifier("LUT Strength")

                Button(AppString.localized("color.lut.remove", "Remove LUT")) {
                    model.removeSelectedClipLUT()
                }
                .disabled(!model.isProjectEditable)
                .accessibilityLabel(AppString.localized("color.lut.remove", "Remove LUT"))
                .accessibilityIdentifier("Remove LUT")
            } else {
                Text(AppString.localized("color.lut.none", "No LUT on this clip"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let message = model.lutImportStatusMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(
                        AppString.localized("color.lut.status.ax", "LUT status \(message)")
                    )
            }
        }
    }
}

struct ColorLooksSection: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppString.localized("color.looks.heading", "Looks"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Button(AppString.localized("color.looks.save", "Save Look…")) {
                model.presentSaveLookSheet()
            }
            .disabled(!model.canSaveLook)
            .accessibilityLabel(AppString.localized("color.looks.save.ax", "Save Look from Selected Clip"))
            .accessibilityIdentifier("Save Look")

            if model.savedLooks.isEmpty {
                Text(AppString.localized("color.looks.empty", "No saved looks"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.savedLooks, id: \.id) { look in
                    HStack(spacing: 8) {
                        Text(look.name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button(AppString.localized("color.looks.apply", "Apply")) {
                            model.applyLookToSelectedClip(lookID: look.id)
                        }
                        .controlSize(.mini)
                        .disabled(!model.canApplyLook)
                        .accessibilityLabel(
                            AppString.localized(
                                "color.looks.apply.item",
                                "Apply Look \(look.name)"
                            )
                        )
                        .accessibilityIdentifier("Apply Look \(look.id.uuidString)")
                        Button(AppString.localized("color.looks.delete", "Delete")) {
                            model.deleteLook(lookID: look.id)
                        }
                        .controlSize(.mini)
                        .disabled(!model.isProjectEditable)
                        .accessibilityLabel(
                            AppString.localized(
                                "color.looks.delete.item",
                                "Delete Look \(look.name)"
                            )
                        )
                        .accessibilityIdentifier("Delete Look \(look.id.uuidString)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppString.localized("color.looks.ax", "Project Looks"))
    }
}

struct SaveLookSheet: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppString.localized("look.save.title", "Save Look"))
                .font(.headline)
            TextField(
                AppString.localized("look.save.name", "Look name"),
                text: Binding(
                    get: { model.saveLookDraftName },
                    set: { model.updateSaveLookDraftName($0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .timelineTextEditingScope(model: model)
            .accessibilityLabel(AppString.localized("look.save.name", "Look name"))
            .accessibilityIdentifier("Save Look Name")

            HStack {
                Spacer()
                Button(AppString.localized("look.save.cancel", "Cancel")) {
                    model.dismissSaveLookSheet()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(AppString.localized("look.save.cancel", "Cancel"))
                .accessibilityIdentifier("Save Look Cancel")

                Button(AppString.localized("look.save.confirm", "Save")) {
                    model.confirmSaveLookFromSelectedClip()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConfirmSaveLook)
                .accessibilityLabel(AppString.localized("look.save.confirm", "Save"))
                .accessibilityIdentifier("Save Look Confirm")
            }
        }
        .padding(20)
        .frame(minWidth: 320)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppString.localized("look.save.ax", "Save Look dialog"))
        .accessibilityIdentifier("Save Look Sheet")
    }
}

