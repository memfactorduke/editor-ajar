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
            Text(AppString.localized("export.dialog.title", "Export"))
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
            if model.exportDialog.mode == .animatedGIF {
                ExportAnimatedGIFSizePicker(model: model)
                ExportAnimatedGIFFrameRatePicker(model: model)
                ExportAnimatedGIFLoopPicker(model: model)
            }

            if let status = model.exportDialog.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        AppString.localized("export.dialog.status.ax", "Export status: \(status)")
                    )
            }

            HStack {
                Spacer()
                Button(AppString.localized("export.dialog.cancel", "Cancel")) {
                    model.dismissExportDialog()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(AppString.localized("export.dialog.cancel.ax", "Cancel export"))
                .accessibilityIdentifier("Export Dialog Cancel")

                if model.exportDialog.mode == .video
                    || model.exportDialog.mode == .animatedGIF
                {
                    Button(AppString.localized("export.dialog.addToQueue", "Add to Queue")) {
                        model.enqueueExportDialogSelection()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(
                        AppString.localized("export.dialog.addToQueue.ax", "Add export to queue")
                    )
                    .accessibilityIdentifier("Export Dialog Add to Queue")
                } else {
                    Button(AppString.localized("export.dialog.validate", "Validate")) {
                        _ = model.validateExportDialogSelection()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(
                        AppString.localized(
                            "export.dialog.validate.ax", "Validate export settings"
                        )
                    )
                    .accessibilityIdentifier("Export Dialog Validate")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppString.localized("export.dialog.ax", "Export dialog"))
        .accessibilityIdentifier("Export Dialog")
    }
}

// MARK: - Extracted pickers (keep parent type-check small)

private struct ExportModePicker: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppString.localized("export.section.mode", "Mode"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(AppString.localized("export.mode.ax", "Export mode"), selection: modeBinding) {
                ForEach(EditorAjarExportMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(AppString.localized("export.mode.ax", "Export mode"))
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
            Text(AppString.localized("export.section.preset", "Preset"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(AppString.localized("export.preset.ax", "Export preset"), selection: presetBinding) {
                ForEach(model.exportDialog.availablePresets) { preset in
                    Text(presetLabel(preset)).tag(Optional(preset.id))
                }
            }
            .accessibilityLabel(AppString.localized("export.preset.ax", "Export preset"))
            .accessibilityIdentifier("Export Preset Picker")
            .accessibilityValue(selectedPresetAccessibilityValue)
        }
    }

    private var selectedPresetAccessibilityValue: String {
        guard let id = model.exportDialog.selectedPresetID,
            let preset = model.exportDialog.availablePresets.first(where: { $0.id == id })
        else {
            return AppString.localized("export.preset.none", "None")
        }
        return presetLabel(preset)
    }

    private func presetLabel(_ preset: ExportPreset) -> String {
        preset.isBuiltIn
            ? preset.name
            : AppString.localized("export.preset.custom", "\(preset.name) (Custom)")
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
            Text(AppString.localized("export.section.range", "Range"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(AppString.localized("export.range.ax", "Export range"), selection: rangeBinding) {
                ForEach(EditorAjarExportRangeChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(AppString.localized("export.range.ax", "Export range"))
            .accessibilityIdentifier("Export Range Picker")
            .accessibilityValue(model.exportDialog.rangeChoice.displayName)
            Text(model.timelineRangeDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(AppString.localized(
                    "export.range.timeline.ax", "Timeline range: \(model.timelineRangeDescription)"
                ))
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
            Text(AppString.localized("export.section.stillFormat", "Still format"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(
                AppString.localized("export.section.stillFormat", "Still format"),
                selection: formatBinding
            ) {
                ForEach(EditorAjarStillFormatChoice.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(AppString.localized("export.stillFormat.ax", "Still frame format"))
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
            Text(AppString.localized("export.section.audioFormat", "Audio format"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(
                AppString.localized("export.audioFormat.ax", "Audio-only format"),
                selection: formatBinding
            ) {
                ForEach(EditorAjarAudioOnlyFormatChoice.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(AppString.localized("export.audioFormat.ax", "Audio-only format"))
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

private struct ExportAnimatedGIFSizePicker: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppString.localized("export.section.gifSize", "Size"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(
                AppString.localized("export.gif.size.ax", "Animated GIF size"),
                selection: sizeBinding
            ) {
                ForEach(EditorAjarAnimatedGIFSizeChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(
                AppString.localized("export.gif.size.ax", "Animated GIF size")
            )
            .accessibilityIdentifier("Export Animated GIF Size Picker")
            .accessibilityValue(model.exportDialog.animatedGIFSizeChoice.displayName)
        }
    }

    private var sizeBinding: Binding<EditorAjarAnimatedGIFSizeChoice> {
        Binding(
            get: { model.exportDialog.animatedGIFSizeChoice },
            set: { model.setAnimatedGIFSizeChoice($0) }
        )
    }
}

private struct ExportAnimatedGIFFrameRatePicker: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppString.localized("export.section.gifFrameRate", "Frame rate"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(
                AppString.localized("export.gif.frameRate.ax", "Animated GIF frame rate"),
                selection: frameRateBinding
            ) {
                ForEach(EditorAjarAnimatedGIFFrameRateChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(
                AppString.localized("export.gif.frameRate.ax", "Animated GIF frame rate")
            )
            .accessibilityIdentifier("Export Animated GIF Frame Rate Picker")
            .accessibilityValue(model.exportDialog.animatedGIFFrameRateChoice.displayName)
        }
    }

    private var frameRateBinding: Binding<EditorAjarAnimatedGIFFrameRateChoice> {
        Binding(
            get: { model.exportDialog.animatedGIFFrameRateChoice },
            set: { model.setAnimatedGIFFrameRateChoice($0) }
        )
    }
}

private struct ExportAnimatedGIFLoopPicker: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppString.localized("export.section.gifLoop", "Playback"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(
                AppString.localized("export.gif.loop.ax", "Animated GIF playback"),
                selection: loopBinding
            ) {
                ForEach(EditorAjarAnimatedGIFLoopChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(
                AppString.localized("export.gif.loop.ax", "Animated GIF playback")
            )
            .accessibilityIdentifier("Export Animated GIF Loop Picker")
            .accessibilityValue(model.exportDialog.animatedGIFLoopChoice.displayName)
        }
    }

    private var loopBinding: Binding<EditorAjarAnimatedGIFLoopChoice> {
        Binding(
            get: { model.exportDialog.animatedGIFLoopChoice },
            set: { model.setAnimatedGIFLoopChoice($0) }
        )
    }
}
