// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import SwiftUI

/// Per-clip gain, pan, and fade fields for a selected audio clip (FR-AUD-001 / FR-AUD-002).
///
/// Gain/pan use the engine's `ClipAudioMix` static base values. Full rubber-band keyframing is
/// available via the animatable model; the v1 inspector exposes a static field (same pattern as
/// early transform text fields) so one undo step covers each discrete commit.
struct AudioClipInspectorView: View {
    let clipName: String
    @ObservedObject var model: EditorAjarAppModel

    @State private var gainDBText = "0.0"
    @State private var panText = "0.00"
    @State private var fadeInSecondsText = "0.00"
    @State private var fadeOutSecondsText = "0.00"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(clipName, systemImage: "waveform")
                    .font(.callout.weight(.semibold))
                GroupBox(AppString.localized("inspector.audio.mix.title", "Clip Audio")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(
                            AppString.localized("inspector.audio.gainDB", "Gain dB"),
                            text: $gainDBText
                        )
                        .textFieldStyle(.roundedBorder)
                        .timelineTextEditingScope(model: model)
                        .accessibilityLabel(
                            AppString.localized("inspector.audio.gainDB", "Gain dB")
                        )
                        .accessibilityIdentifier("Clip Audio Gain dB")
                        .onSubmit { commitGain() }

                        TextField(
                            AppString.localized("inspector.audio.pan", "Pan"),
                            text: $panText
                        )
                        .textFieldStyle(.roundedBorder)
                        .timelineTextEditingScope(model: model)
                        .accessibilityLabel(AppString.localized("inspector.audio.pan", "Pan"))
                        .accessibilityIdentifier("Clip Audio Pan")
                        .onSubmit { commitPan() }

                        Text(
                            AppString.localized(
                                "inspector.audio.keyframe.note",
                                "Static gain/pan. Keyframable via engine AudioMix; rubber-band UI is v1.x."
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    AppString.localized("inspector.audio.mix.ax", "Clip Audio Mix Inspector")
                )
                .accessibilityIdentifier("Clip Audio Mix Inspector")

                GroupBox(AppString.localized("inspector.audio.fades.title", "Fades")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(
                            AppString.localized("inspector.audio.fadeIn", "Fade In (s)"),
                            text: $fadeInSecondsText
                        )
                        .textFieldStyle(.roundedBorder)
                        .timelineTextEditingScope(model: model)
                        .accessibilityLabel(
                            AppString.localized("inspector.audio.fadeIn", "Fade In (s)")
                        )
                        .accessibilityIdentifier("Clip Fade In Seconds")
                        .onSubmit { commitFadeIn() }

                        TextField(
                            AppString.localized("inspector.audio.fadeOut", "Fade Out (s)"),
                            text: $fadeOutSecondsText
                        )
                        .textFieldStyle(.roundedBorder)
                        .timelineTextEditingScope(model: model)
                        .accessibilityLabel(
                            AppString.localized("inspector.audio.fadeOut", "Fade Out (s)")
                        )
                        .accessibilityIdentifier("Clip Fade Out Seconds")
                        .onSubmit { commitFadeOut() }

                        Button(AppString.localized("inspector.audio.crossfade", "Add Crossfade")) {
                            _ = model.addCrossfadeAfterSelectedAudioClip()
                        }
                        .disabled(!model.canAddCrossfadeAfterSelectedAudioClip)
                        .accessibilityLabel(
                            AppString.localized(
                                "inspector.audio.crossfade.ax",
                                "Add audio crossfade after selected clip"
                            )
                        )
                        .accessibilityIdentifier("Add Clip Audio Crossfade")

                        if model.selectedClipHasTrailingCrossfade {
                            Button(
                                AppString.localized(
                                    "inspector.audio.removeCrossfade",
                                    "Remove Crossfade"
                                )
                            ) {
                                _ = model.removeCrossfadeFromSelectedAudioClip()
                            }
                            .accessibilityLabel(
                                AppString.localized(
                                    "inspector.audio.removeCrossfade.ax",
                                    "Remove audio crossfade after selected clip"
                                )
                            )
                            .accessibilityIdentifier("Remove Clip Audio Crossfade")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    AppString.localized("inspector.audio.fades.ax", "Clip Audio Fades Inspector")
                )
                .accessibilityIdentifier("Clip Audio Fades Inspector")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Audio Clip Inspector")
        .accessibilityLabel(
            AppString.localized("inspector.audio.panel.ax", "Audio clip inspector")
        )
        .onAppear { reloadFields() }
        .onChange(of: model.selectedClip?.id) { _ in reloadFields() }
        .onChange(of: model.selectedClip?.audioMix) { _ in reloadFields() }
    }

    private func reloadFields() {
        guard let clip = model.selectedClip, clip.kind == .audio else {
            return
        }
        gainDBText = AudioMixUISupport.gainDBString(fromLinear: clip.audioMix.gain.base.doubleValue)
        panText = AudioMixUISupport.panString(from: clip.audioMix.pan.base)
        fadeInSecondsText = String(format: "%.2f", clip.audioMix.fadeIn.duration.seconds)
        fadeOutSecondsText = String(format: "%.2f", clip.audioMix.fadeOut.duration.seconds)
    }

    private func commitGain() {
        guard let gain = AudioMixUISupport.linearGain(fromDBString: gainDBText) else {
            reloadFields()
            return
        }
        _ = model.setSelectedClipAudioGain(gain, gesturePhase: .discrete)
    }

    private func commitPan() {
        guard let pan = AudioMixUISupport.pan(fromString: panText) else {
            reloadFields()
            return
        }
        _ = model.setSelectedClipAudioPan(pan, gesturePhase: .discrete)
    }

    private func commitFadeIn() {
        guard let seconds = Double(fadeInSecondsText), seconds.isFinite, seconds >= 0 else {
            reloadFields()
            return
        }
        _ = model.setSelectedClipFadeInSeconds(seconds, gesturePhase: .discrete)
    }

    private func commitFadeOut() {
        guard let seconds = Double(fadeOutSecondsText), seconds.isFinite, seconds >= 0 else {
            reloadFields()
            return
        }
        _ = model.setSelectedClipFadeOutSeconds(seconds, gesturePhase: .discrete)
    }
}
