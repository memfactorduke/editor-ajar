// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import SwiftUI

/// FR-FX-003 effects stack inspector + FR-FX-001 transition controls.
///
/// Extracted from `ClipInspectorTabs` so stack row/parameter controls stay small (SwiftUI
/// type-check budget; NFR-A11Y-001 AX tree).

struct EffectsInspector: View {
    let state: SelectedEffectStackInspectorState
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(state.clipName, systemImage: "sparkles")
                    .font(.callout.weight(.semibold))

                Text(
                    AppString.localized(
                        "effects.staticNote",
                        "Effect parameters are static in v1 (no effect keyframe UI yet)."
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if state.nodes.isEmpty {
                    Text(
                        AppString.localized(
                            "effects.stack.empty",
                            "No effects on this clip. Double-click an effect in the library to add one."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(state.nodes.enumerated()), id: \.element.id) { index, node in
                        EffectStackNodeRow(
                            node: node,
                            index: index,
                            nodeCount: state.nodes.count,
                            model: model
                        )
                    }
                }

                Button(AppString.localized("effects.stack.resetAll", "Reset Effects Stack")) {
                    _ = model.resetSelectedEffectStack()
                }
                .disabled(!model.isProjectEditable || state.nodes.isEmpty)
                .accessibilityLabel(
                    AppString.localized("effects.stack.resetAll", "Reset Effects Stack")
                )
                .accessibilityIdentifier("Effects Reset All")

                Divider()
                if let transitionState = model.selectedVideoTransitionState {
                    VideoTransitionInspector(state: transitionState, model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Effects Inspector")
        .accessibilityLabel(AppString.localized("inspector.effects.ax", "Effects Inspector"))
    }
}

struct EffectStackNodeRow: View {
    let node: ClipEffectNode
    let index: Int
    let nodeCount: Int
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Toggle(
                    isOn: Binding(
                        get: { node.enabled },
                        set: { model.setSelectedEffectNodeEnabled(nodeID: node.id, enabled: $0) }
                    )
                ) {
                    Text(node.kind.localizedDisplayName)
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.checkbox)
                .disabled(!model.isProjectEditable)
                .accessibilityLabel(
                    AppString.localized(
                        "effects.node.enable.ax",
                        "Enable \(node.kind.localizedDisplayName)"
                    )
                )
                .accessibilityIdentifier("Effect Enable \(node.id.uuidString)")

                Spacer(minLength: 4)

                Button {
                    _ = model.moveSelectedEffectNode(nodeID: node.id, delta: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .disabled(!model.isProjectEditable || index == 0)
                .accessibilityLabel(
                    AppString.localized("effects.node.moveUp", "Move Effect Up")
                )
                .accessibilityIdentifier("Effect Move Up \(node.id.uuidString)")

                Button {
                    _ = model.moveSelectedEffectNode(nodeID: node.id, delta: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .disabled(!model.isProjectEditable || index >= nodeCount - 1)
                .accessibilityLabel(
                    AppString.localized("effects.node.moveDown", "Move Effect Down")
                )
                .accessibilityIdentifier("Effect Move Down \(node.id.uuidString)")

                Button {
                    _ = model.resetSelectedEffectNode(nodeID: node.id)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .disabled(!model.isProjectEditable)
                .help(AppString.localized("effects.node.reset.help", "Reset parameters"))
                .accessibilityLabel(
                    AppString.localized(
                        "effects.node.reset.ax",
                        "Reset \(node.kind.localizedDisplayName)"
                    )
                )
                .accessibilityIdentifier("Effect Reset \(node.id.uuidString)")

                Button {
                    _ = model.removeSelectedEffectNode(nodeID: node.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .disabled(!model.isProjectEditable)
                .accessibilityLabel(
                    AppString.localized(
                        "effects.node.remove.ax",
                        "Remove \(node.kind.localizedDisplayName)"
                    )
                )
                .accessibilityIdentifier("Effect Remove \(node.id.uuidString)")
            }

            EffectNodeParameterControls(node: node, model: model)
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Effect Node \(node.id.uuidString)")
    }
}

struct EffectNodeParameterControls: View {
    let node: ClipEffectNode
    @ObservedObject var model: EditorAjarAppModel

    private var layout: EffectParameterLayout {
        EffectParameterCatalog.layout(for: node.kind)
    }

    var body: some View {
        if layout.isEmpty {
            Text(
                AppString.localized(
                    "effects.params.none",
                    "No adjustable parameters."
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(layout.scalars) { spec in
                    EffectScalarParameterSlider(
                        nodeID: node.id,
                        definition: node.definition,
                        spec: spec,
                        model: model
                    )
                }
                if layout.discrete == .mirrorAxis {
                    EffectMirrorAxisPicker(nodeID: node.id, definition: node.definition, model: model)
                }
            }
        }
    }
}

struct EffectScalarParameterSlider: View {
    let nodeID: UUID
    let definition: ClipEffectDefinition
    let spec: EffectScalarParameterSpec
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        let current =
            EffectParameterCatalog.scalarValue(parameterID: spec.id, in: definition)
            ?? RationalValue.zero
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(spec.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ColorFieldValueMapper.string(from: current))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: {
                        (EffectParameterCatalog.scalarValue(
                            parameterID: spec.id,
                            in: liveDefinition
                        ) ?? RationalValue.zero).doubleValue
                    },
                    set: {
                        model.setSelectedEffectScalar(
                            nodeID: nodeID,
                            parameterID: spec.id,
                            doubleValue: $0
                        )
                    }
                ),
                in: spec.range,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        model.endEffectParameterSliderGesture()
                    }
                }
            )
            .disabled(!model.isProjectEditable)
            .accessibilityLabel(spec.title)
            .accessibilityIdentifier("Effect Param \(nodeID.uuidString) \(spec.id)")
            .accessibilityValue(ColorFieldValueMapper.string(from: current))
        }
    }

    private var liveDefinition: ClipEffectDefinition {
        model.selectedClip?.effectStack.nodes.first(where: { $0.id == nodeID })?.definition
            ?? definition
    }
}

struct EffectMirrorAxisPicker: View {
    let nodeID: UUID
    let definition: ClipEffectDefinition
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        let current = EffectParameterCatalog.mirrorAxis(in: liveDefinition) ?? .horizontal
        Picker(
            AppString.localized("effects.param.axis", "Axis"),
            selection: Binding(
                get: {
                    EffectParameterCatalog.mirrorAxis(in: liveDefinition) ?? .horizontal
                },
                set: { model.setSelectedEffectMirrorAxis(nodeID: nodeID, axis: $0) }
            )
        ) {
            ForEach(ClipMirrorAxis.allCases, id: \.self) { axis in
                Text(axis.localizedTitle).tag(axis)
            }
        }
        .labelsHidden()
        .disabled(!model.isProjectEditable)
        .accessibilityLabel(AppString.localized("effects.param.axis", "Axis"))
        .accessibilityIdentifier("Effect Mirror Axis \(nodeID.uuidString)")
        .accessibilityValue(current.localizedTitle)
    }

    private var liveDefinition: ClipEffectDefinition {
        model.selectedClip?.effectStack.nodes.first(where: { $0.id == nodeID })?.definition
            ?? definition
    }
}

// MARK: - Transition inspector (FR-FX-001)

struct VideoTransitionInspector: View {
    let state: SelectedVideoTransitionState
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppString.localized("transition.heading", "Transition"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if !state.hasAdjacentIncoming {
                Text(
                    AppString.localized(
                        "transition.needAdjacent",
                        "Select the outgoing clip of two abutting clips to apply a transition."
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                // Orphaned trailing record: partner gone but menu can still Remove — match it.
                if let existing = state.transition {
                    Text(
                        AppString.localized(
                            "transition.current",
                            "Current: \(existing.kind.localizedDisplayName)"
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Text(
                        AppString.localized(
                            "transition.partnerMissing",
                            "Transition partner missing"
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("Transition Partner Missing")
                    Button(AppString.localized("transition.remove", "Remove Transition")) {
                        _ = model.removeVideoTransitionFromSelectedCut()
                    }
                    .disabled(!model.canRemoveVideoTransition)
                    .accessibilityLabel(
                        AppString.localized("transition.remove", "Remove Transition")
                    )
                    .accessibilityIdentifier("Remove Transition")

                    if let message = model.videoTransitionStatusMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(
                                AppString.localized(
                                    "transition.status.ax",
                                    "Transition status \(message)"
                                )
                            )
                    }
                }
            } else {
                if let existing = state.transition {
                    Text(
                        AppString.localized(
                            "transition.current",
                            "Current: \(existing.kind.localizedDisplayName)"
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    Text(
                        AppString.localized(
                            "transition.none",
                            "No transition on this cut."
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Picker(
                    AppString.localized("transition.kind", "Kind"),
                    selection: Binding(
                        get: { model.videoTransitionDraftKind },
                        set: { model.updateVideoTransitionDraftKind($0) }
                    )
                ) {
                    ForEach(ClipVideoTransitionKind.allCases, id: \.self) { kind in
                        Text(kind.localizedDisplayName).tag(kind)
                    }
                }
                .disabled(!model.isProjectEditable)
                .accessibilityLabel(AppString.localized("transition.kind", "Kind"))
                .accessibilityIdentifier("Transition Kind")

                HStack {
                    Text(AppString.localized("transition.durationFrames", "Duration (frames)"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField(
                        AppString.localized("transition.durationFrames", "Duration (frames)"),
                        text: Binding(
                            get: { model.videoTransitionDraftDurationFrames },
                            set: { model.updateVideoTransitionDraftDurationFrames($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .timelineTextEditingScope(model: model)
                    .disabled(!model.isProjectEditable)
                    .accessibilityLabel(
                        AppString.localized("transition.durationFrames", "Duration (frames)")
                    )
                    .accessibilityIdentifier("Transition Duration")
                }

                if model.videoTransitionDraftKind.usesDirection {
                    Picker(
                        AppString.localized("transition.direction", "Direction"),
                        selection: Binding(
                            get: { model.videoTransitionDraftDirection },
                            set: { model.updateVideoTransitionDraftDirection($0) }
                        )
                    ) {
                        ForEach(
                            ClipVideoTransitionDirection.options(for: model.videoTransitionDraftKind),
                            id: \.self
                        ) { direction in
                            Text(direction.localizedDisplayName).tag(direction)
                        }
                    }
                    .disabled(!model.isProjectEditable)
                    .accessibilityLabel(AppString.localized("transition.direction", "Direction"))
                    .accessibilityIdentifier("Transition Direction")
                }

                HStack {
                    Button(
                        state.transition == nil
                            ? AppString.localized("transition.apply", "Apply Transition")
                            : AppString.localized("transition.replace", "Replace Transition")
                    ) {
                        _ = model.applyDraftVideoTransitionToSelectedCut()
                    }
                    .disabled(!model.canApplyVideoTransition)
                    .accessibilityLabel(
                        state.transition == nil
                            ? AppString.localized("transition.apply", "Apply Transition")
                            : AppString.localized("transition.replace", "Replace Transition")
                    )
                    .accessibilityIdentifier("Apply Transition")

                    Button(AppString.localized("transition.remove", "Remove Transition")) {
                        _ = model.removeVideoTransitionFromSelectedCut()
                    }
                    .disabled(!model.canRemoveVideoTransition)
                    .accessibilityLabel(
                        AppString.localized("transition.remove", "Remove Transition")
                    )
                    .accessibilityIdentifier("Remove Transition")
                }

                if let message = model.videoTransitionStatusMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(
                            AppString.localized(
                                "transition.status.ax",
                                "Transition status \(message)"
                            )
                        )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Transition Inspector")
        .accessibilityLabel(
            AppString.localized("transition.inspector.ax", "Video Transition Inspector")
        )
    }
}
