// SPDX-License-Identifier: GPL-3.0-or-later

import AjarExport
import SwiftUI

/// Minimal export dialog: mode, preset, range, still/audio format (FR-EXP-003/004).
///
/// Subviews are extracted so SwiftUI type-check stays within CI time limits.
struct EditorAjarExportDialogView: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            ExportModePicker(model: model)
            if model.exportDialog.mode == .video {
                ExportPresetPicker(model: model)
            }
            if model.exportDialog.mode != .stillFrame {
                ExportRangePicker(model: model)
            }
            if model.exportDialog.mode == .stillFrame {
                ExportStillFormatPicker(model: model)
            }
            if model.exportDialog.mode == .audioOnly {
                ExportAudioOnlyFormatPicker(model: model)
            }

            if let status = model.exportDialog.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Export status: \(status)")
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    model.dismissExportDialog()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel export")
                .accessibilityIdentifier("Export Dialog Cancel")

                Button("Validate") {
                    _ = model.validateExportDialogSelection()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Validate export settings")
                .accessibilityIdentifier("Export Dialog Validate")
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Export dialog")
        .accessibilityIdentifier("Export Dialog")
    }
}

// MARK: - Extracted pickers (keep parent type-check small)

private struct ExportModePicker: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mode")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Export mode", selection: modeBinding) {
                ForEach(EditorAjarExportMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Export mode")
            .accessibilityIdentifier("Export Mode Picker")
            .accessibilityValue(model.exportDialog.mode.displayName)
        }
    }

    private var modeBinding: Binding<EditorAjarExportMode> {
        Binding(
            get: { model.exportDialog.mode },
            set: { model.setExportMode($0) }
        )
    }
}

private struct ExportPresetPicker: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preset")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Export preset", selection: presetBinding) {
                ForEach(model.exportDialog.availablePresets) { preset in
                    Text(presetLabel(preset)).tag(Optional(preset.id))
                }
            }
            .accessibilityLabel("Export preset")
            .accessibilityIdentifier("Export Preset Picker")
            .accessibilityValue(selectedPresetAccessibilityValue)
        }
    }

    private var selectedPresetAccessibilityValue: String {
        guard let id = model.exportDialog.selectedPresetID,
            let preset = model.exportDialog.availablePresets.first(where: { $0.id == id })
        else {
            return "None"
        }
        return presetLabel(preset)
    }

    private func presetLabel(_ preset: ExportPreset) -> String {
        preset.isBuiltIn ? preset.name : "\(preset.name) (Custom)"
    }

    private var presetBinding: Binding<UUID?> {
        Binding(
            get: { model.exportDialog.selectedPresetID },
            set: { newValue in
                if let newValue {
                    model.setExportPresetID(newValue)
                }
            }
        )
    }
}

private struct ExportRangePicker: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Range")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Export range", selection: rangeBinding) {
                ForEach(EditorAjarExportRangeChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Export range")
            .accessibilityIdentifier("Export Range Picker")
            .accessibilityValue(model.exportDialog.rangeChoice.displayName)
            Text(model.timelineRangeDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Timeline range: \(model.timelineRangeDescription)")
        }
    }

    private var rangeBinding: Binding<EditorAjarExportRangeChoice> {
        Binding(
            get: { model.exportDialog.rangeChoice },
            set: { model.setExportRangeChoice($0) }
        )
    }
}

private struct ExportStillFormatPicker: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Still format")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Still format", selection: formatBinding) {
                ForEach(EditorAjarStillFormatChoice.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Still frame format")
            .accessibilityIdentifier("Export Still Format Picker")
            .accessibilityValue(model.exportDialog.stillFormat.displayName)
        }
    }

    private var formatBinding: Binding<EditorAjarStillFormatChoice> {
        Binding(
            get: { model.exportDialog.stillFormat },
            set: { model.setStillFormat($0) }
        )
    }
}

private struct ExportAudioOnlyFormatPicker: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audio format")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Audio-only format", selection: formatBinding) {
                ForEach(EditorAjarAudioOnlyFormatChoice.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Audio-only format")
            .accessibilityIdentifier("Export Audio Format Picker")
            .accessibilityValue(model.exportDialog.audioOnlyFormat.displayName)
        }
    }

    private var formatBinding: Binding<EditorAjarAudioOnlyFormatChoice> {
        Binding(
            get: { model.exportDialog.audioOnlyFormat },
            set: { model.setAudioOnlyFormat($0) }
        )
    }
}
