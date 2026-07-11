// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AppKit
import SwiftUI

/// FR-TXT-001/002/004 title inspector: box list, style controls, animation presets.
///
/// Extracted like `ColorInspector` so `ClipInspectorTabs` stays small.
struct TitleInspector: View {
    let state: SelectedTitleInspectorState
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(state.clipName, systemImage: "textformat")
                    .font(.callout.weight(.semibold))

                TitleBoxListSection(state: state, model: model)

                if let box = state.selectedBox {
                    Divider()
                    TitleTypographySection(box: box, model: model)
                    Divider()
                    TitleFillStrokeSection(box: box, model: model)
                    Divider()
                    TitleShadowBackgroundSection(box: box, model: model)
                    Divider()
                    TitleGradientSection(box: box, model: model)
                } else {
                    Text(AppString.localized("title.box.none", "No text box selected"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()
                TitleAnimationPresetSection(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Title Inspector")
        .accessibilityLabel(AppString.localized("inspector.title.ax", "Title Inspector"))
    }
}

// MARK: - Box list

private struct TitleBoxListSection: View {
    let state: SelectedTitleInspectorState
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppString.localized("title.boxes.heading", "Text Boxes"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(state.title.boxes.enumerated()), id: \.element.id) { index, box in
                Button {
                    model.selectTitleInspectorBox(id: box.id)
                } label: {
                    HStack {
                        Text(boxLabel(index: index, box: box))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if state.selectedBoxID == box.id {
                            Image(systemName: "checkmark")
                                .font(.caption2)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!model.isProjectEditable)
                .accessibilityLabel(
                    AppString.localized(
                        "title.box.select.ax",
                        "Select text box \(index + 1), \(boxLabel(index: index, box: box))"
                    )
                )
                .accessibilityIdentifier("Title Box \(box.id.uuidString)")
                .accessibilityAddTraits(
                    state.selectedBoxID == box.id ? [.isSelected] : []
                )
            }

            HStack(spacing: 8) {
                Button(AppString.localized("title.box.add", "Add Box")) {
                    model.addTitleTextBox()
                }
                .controlSize(.mini)
                .disabled(!model.isProjectEditable)
                .accessibilityLabel(AppString.localized("title.box.add", "Add Box"))
                .accessibilityIdentifier("Title Add Box")

                Button(AppString.localized("title.box.remove", "Remove Box")) {
                    model.removeSelectedTitleTextBox()
                }
                .controlSize(.mini)
                .disabled(!model.isProjectEditable || state.selectedBoxID == nil)
                .accessibilityLabel(AppString.localized("title.box.remove", "Remove Box"))
                .accessibilityIdentifier("Title Remove Box")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppString.localized("title.boxes.ax", "Title text boxes"))
    }

    private func boxLabel(index: Int, box: TitleTextBox) -> String {
        let preview = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.isEmpty {
            return AppString.localized("title.box.empty", "Box \(index + 1) (empty)")
        }
        let clipped = preview.count > 24 ? String(preview.prefix(24)) + "…" : preview
        return AppString.localized("title.box.named", "Box \(index + 1): \(clipped)")
    }
}

// MARK: - Typography

private struct TitleTypographySection: View {
    let box: TitleTextBox
    @ObservedObject var model: EditorAjarAppModel

    private var fontFamilies: [String] {
        let system = NSFontManager.shared.availableFontFamilies.sorted()
        if system.contains(box.style.fontFamily) {
            return system
        }
        return ([box.style.fontFamily] + system).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppString.localized("title.typography.heading", "Typography"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Free-text accepts user fonts; names are data (not localized). Focus-gated (#240).
            // Coalescing also disarms on real focus loss inside `textEditorFocusChanged` (P3b);
            // submit remains an explicit boundary for Return without relying on blur timing.
            TextField(
                AppString.localized("title.field.fontFamily", "Font"),
                text: Binding(
                    get: { box.style.fontFamily },
                    set: { model.setSelectedTitleFontFamily($0, coalesce: true) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .timelineTextEditingScope(model: model)
            .onSubmit { model.endTitleStyleSliderGesture() }
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(AppString.localized("title.field.fontFamily", "Font"))
            .accessibilityIdentifier("Title Font Family")

            Picker(
                AppString.localized("title.field.fontFamily.menu", "Font Menu"),
                selection: Binding(
                    get: { box.style.fontFamily },
                    set: { model.setSelectedTitleFontFamily($0) }
                )
            ) {
                // Font family names are data (PostScript/family names), not localized.
                ForEach(fontFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .labelsHidden()
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(AppString.localized("title.field.fontFamily.menu", "Font Menu"))
            .accessibilityIdentifier("Title Font Family Menu")

            Picker(
                AppString.localized("title.field.fontWeight", "Weight"),
                selection: Binding(
                    get: { box.style.fontWeight },
                    set: { model.setSelectedTitleFontWeight($0) }
                )
            ) {
                ForEach(TitleFontWeight.allCases, id: \.self) { weight in
                    Text(weight.localizedTitle).tag(weight)
                }
            }
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(AppString.localized("title.field.fontWeight", "Weight"))
            .accessibilityIdentifier("Title Font Weight")

            Picker(
                AppString.localized("title.field.alignment", "Alignment"),
                selection: Binding(
                    get: { box.style.alignment },
                    set: { model.setSelectedTitleAlignment($0) }
                )
            ) {
                ForEach(TitleTextAlignment.allCases, id: \.self) { alignment in
                    Text(alignment.localizedTitle).tag(alignment)
                }
            }
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(AppString.localized("title.field.alignment", "Alignment"))
            .accessibilityIdentifier("Title Alignment")

            TitleScalarSlider(field: .fontSize, box: box, model: model)
            TitleScalarSlider(field: .tracking, box: box, model: model)
            TitleScalarSlider(field: .leading, box: box, model: model)

            TitleColorChannelGroup(target: .fill, box: box, model: model)
        }
    }
}

// MARK: - Fill / stroke

private struct TitleFillStrokeSection: View {
    let box: TitleTextBox
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppString.localized("title.stroke.heading", "Stroke"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle(
                AppString.localized("title.stroke.enable", "Stroke"),
                isOn: Binding(
                    get: { box.style.stroke != nil },
                    set: { model.setSelectedTitleStrokeEnabled($0) }
                )
            )
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(AppString.localized("title.stroke.enable", "Stroke"))
            .accessibilityIdentifier("Title Stroke Enabled")

            if box.style.stroke != nil {
                TitleScalarSlider(field: .strokeWidth, box: box, model: model)
                TitleColorChannelGroup(target: .stroke, box: box, model: model)
                Picker(
                    AppString.localized("title.field.strokeJoin", "Join"),
                    selection: Binding(
                        get: { box.style.stroke?.join ?? .miter },
                        set: { model.setSelectedTitleStrokeJoin($0) }
                    )
                ) {
                    ForEach(TitleStrokeJoin.allCases, id: \.self) { join in
                        Text(join.localizedTitle).tag(join)
                    }
                }
                .disabled(!model.isProjectEditable)
                .accessibilityLabel(AppString.localized("title.field.strokeJoin", "Join"))
                .accessibilityIdentifier("Title Stroke Join")
            }
        }
    }
}

// MARK: - Shadow / background

private struct TitleShadowBackgroundSection: View {
    let box: TitleTextBox
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppString.localized("title.shadow.heading", "Drop Shadow"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle(
                AppString.localized("title.shadow.enable", "Drop Shadow"),
                isOn: Binding(
                    get: { box.style.dropShadow != nil },
                    set: { model.setSelectedTitleDropShadowEnabled($0) }
                )
            )
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(AppString.localized("title.shadow.enable", "Drop Shadow"))
            .accessibilityIdentifier("Title Shadow Enabled")

            if box.style.dropShadow != nil {
                TitleScalarSlider(field: .shadowOffsetX, box: box, model: model)
                TitleScalarSlider(field: .shadowOffsetY, box: box, model: model)
                TitleScalarSlider(field: .shadowBlur, box: box, model: model)
                TitleScalarSlider(field: .shadowOpacity, box: box, model: model)
                TitleColorChannelGroup(target: .shadow, box: box, model: model)
            }

            Text(AppString.localized("title.background.heading", "Background Box"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle(
                AppString.localized("title.background.enable", "Background Box"),
                isOn: Binding(
                    get: { box.backgroundBox != nil },
                    set: { model.setSelectedTitleBackgroundEnabled($0) }
                )
            )
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(AppString.localized("title.background.enable", "Background Box"))
            .accessibilityIdentifier("Title Background Enabled")

            if box.backgroundBox != nil {
                TitleScalarSlider(field: .backgroundPadding, box: box, model: model)
                TitleScalarSlider(field: .backgroundCornerRadius, box: box, model: model)
                TitleScalarSlider(field: .backgroundOpacity, box: box, model: model)
                TitleColorChannelGroup(target: .background, box: box, model: model)
            }
        }
    }
}

// MARK: - Gradient

private struct TitleGradientSection: View {
    let box: TitleTextBox
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppString.localized("title.gradient.heading", "Gradient Fill"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle(
                AppString.localized("title.gradient.enable", "Gradient Fill"),
                isOn: Binding(
                    get: { box.style.gradientFill != nil },
                    set: { model.setSelectedTitleGradientEnabled($0) }
                )
            )
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(AppString.localized("title.gradient.enable", "Gradient Fill"))
            .accessibilityIdentifier("Title Gradient Enabled")

            if box.style.gradientFill != nil {
                TitleColorChannelGroup(target: .gradientStart, box: box, model: model)
                TitleColorChannelGroup(target: .gradientEnd, box: box, model: model)
                TitleScalarSlider(field: .gradientAngle, box: box, model: model)
            }
        }
    }
}

// MARK: - Animation presets

private struct TitleAnimationPresetSection: View {
    @ObservedObject var model: EditorAjarAppModel
    @State private var selectedKind: TitleAnimationPresetKind = .fade
    @State private var selectedDirection: TitleAnimationDirection = .left

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppString.localized("title.presets.heading", "Animation Preset"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker(
                AppString.localized("title.presets.kind", "Preset"),
                selection: $selectedKind
            ) {
                ForEach(TitleAnimationPresetKind.allCases, id: \.self) { kind in
                    Text(kind.localizedTitle).tag(kind)
                }
            }
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(AppString.localized("title.presets.kind", "Preset"))
            .accessibilityIdentifier("Title Animation Preset Kind")

            if selectedKind == .slide || selectedKind == .lowerThird {
                Picker(
                    AppString.localized("title.presets.direction", "Direction"),
                    selection: $selectedDirection
                ) {
                    ForEach(TitleAnimationDirection.allCases, id: \.self) { direction in
                        Text(direction.localizedTitle).tag(direction)
                    }
                }
                .disabled(!model.isProjectEditable)
                .accessibilityLabel(AppString.localized("title.presets.direction", "Direction"))
                .accessibilityIdentifier("Title Animation Direction")
            }

            Button(AppString.localized("title.presets.apply", "Apply Preset")) {
                let direction: TitleAnimationDirection? =
                    (selectedKind == .slide || selectedKind == .lowerThird)
                    ? selectedDirection
                    : nil
                model.applyTitleAnimationPresetToSelection(
                    kind: selectedKind,
                    direction: direction
                )
            }
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(AppString.localized("title.presets.apply", "Apply Preset"))
            .accessibilityIdentifier("Title Apply Animation Preset")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppString.localized("title.presets.ax", "Title animation presets"))
    }
}

// MARK: - Shared controls

private struct TitleScalarSlider: View {
    let field: TitleStyleScalarField
    let box: TitleTextBox
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        let value = TitleStyleEditor.scalarValue(field, in: box)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(field.localizedTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ColorFieldValueMapper.string(from: value))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { TitleStyleEditor.scalarValue(field, in: box).doubleValue },
                    set: { model.setSelectedTitleScalar(field, doubleValue: $0) }
                ),
                in: field.range,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        model.endTitleStyleSliderGesture()
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

private struct TitleColorChannelGroup: View {
    let target: TitleColorTarget
    let box: TitleTextBox
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(target.localizedTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(ColorInspectorChannelComponent.allCases) { component in
                TitleColorChannelSlider(
                    target: target,
                    component: component,
                    box: box,
                    model: model
                )
            }
        }
    }
}

private struct TitleColorChannelSlider: View {
    let target: TitleColorTarget
    let component: ColorInspectorChannelComponent
    let box: TitleTextBox
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        let color = TitleStyleEditor.color(target, in: box)
        let channelValue: RationalValue = {
            switch component {
            case .red: return color.red
            case .green: return color.green
            case .blue: return color.blue
            }
        }()

        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(component.localizedTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ColorFieldValueMapper.string(from: channelValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: {
                        let color = TitleStyleEditor.color(target, in: box)
                        switch component {
                        case .red: return color.red.doubleValue
                        case .green: return color.green.doubleValue
                        case .blue: return color.blue.doubleValue
                        }
                    },
                    set: {
                        model.setSelectedTitleColorChannel(
                            target: target,
                            component: component,
                            doubleValue: $0
                        )
                    }
                ),
                in: 0...1,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        model.endTitleStyleSliderGesture()
                    }
                }
            )
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(
                AppString.localized(
                    "title.color.channel.ax",
                    "\(target.localizedTitle) \(component.localizedTitle)"
                )
            )
            .accessibilityIdentifier(
                "Title \(target.rawValue.capitalized) \(component.rawValue.capitalized)"
            )
            .accessibilityValue(ColorFieldValueMapper.string(from: channelValue))
        }
    }
}
