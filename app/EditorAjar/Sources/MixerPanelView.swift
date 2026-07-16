// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import SwiftUI

/// Toggleable FR-AUD-003 mixer: per-audio-track fader/pan/mute/solo, master fader, true-peak meters.
struct MixerPanelView: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let meterError = model.mixerMeterError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(
                        "\(AppString.localized("mixer.meter.error", "Meters unavailable")): "
                            + meterError.description
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(AppString.localized("mixer.meter.retry", "Retry")) {
                        model.refreshMixerMeters()
                    }
                    .buttonStyle(.borderless)
                }
                .accessibilityIdentifier("Mixer Meter Error")
            }
            if let sequence = model.activeSequence {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach(
                            Array(sequence.audioTracks.enumerated()),
                            id: \.element.id
                        ) { index, track in
                            MixerTrackStrip(
                                sequenceID: sequence.id,
                                track: track,
                                trackIndex: index,
                                model: model
                            )
                        }
                        MixerMasterStrip(model: model)
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            } else {
                Text(AppString.localized("mixer.empty", "No active sequence"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Mixer Panel")
        .accessibilityLabel(AppString.localized("mixer.panel.ax", "Audio mixer panel"))
        .onAppear {
            model.refreshMixerMeters()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(AppString.localized("mixer.title", "Mixer"))
                .font(.headline)
            Spacer()
            Button(AppString.localized("mixer.hide", "Hide Mixer")) {
                model.toggleMixerPanel()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("m", modifiers: [.command, .option])
            .accessibilityLabel(AppString.localized("mixer.hide.ax", "Hide audio mixer"))
            .accessibilityIdentifier("Hide Mixer")
        }
    }
}

private struct MixerTrackStrip: View {
    let sequenceID: UUID
    let track: Track
    let trackIndex: Int
    @ObservedObject var model: EditorAjarAppModel

    private var trackLabel: String {
        AppString.localized("mixer.track.label", "A\(trackIndex + 1)")
    }

    private var gainLinear: Double {
        track.audioGain.base.doubleValue
    }

    private var panValue: Double {
        track.audioPan.base.doubleValue
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(trackLabel)
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
            MixerMeterColumn(
                levels: model.mixerMeterSnapshot?.trackLevels[track.id] ?? [],
                isClipping: model.mixerMeterSnapshot?.isTrackClipping(track.id) ?? false,
                accessibilityLabel: AppString.localized(
                    "mixer.track.meter.ax",
                    "\(trackLabel) meter"
                )
            )
            MixerGainFader(
                label: AppString.localized("mixer.track.fader.ax", "\(trackLabel) volume"),
                identifier: "Mixer Track \(track.id.uuidString) Gain",
                gainDB: AudioMixUISupport.gainDB(fromLinear: gainLinear),
                onChange: { db, phase in
                    model.setTrackGainDB(
                        sequenceID: sequenceID,
                        trackID: track.id,
                        gainDB: db,
                        gesturePhase: phase
                    )
                }
            )
            MixerPanSlider(
                label: AppString.localized("mixer.track.pan.ax", "\(trackLabel) pan"),
                identifier: "Mixer Track \(track.id.uuidString) Pan",
                pan: panValue,
                onChange: { pan, phase in
                    model.setTrackPan(
                        sequenceID: sequenceID,
                        trackID: track.id,
                        pan: pan,
                        gesturePhase: phase
                    )
                }
            )
            HStack(spacing: 6) {
                MixerToggleButton(
                    title: track.muted
                        ? AppString.localized("mixer.track.unmute", "Unmute \(trackLabel)")
                        : AppString.localized("mixer.track.mute", "Mute \(trackLabel)"),
                    identifier: "Mixer Mute \(track.id.uuidString)",
                    systemImage: track.muted ? "speaker.slash.fill" : "speaker.wave.2",
                    isOn: track.muted
                ) {
                    model.setTrackState(
                        sequenceID: sequenceID,
                        trackID: track.id,
                        muted: !track.muted
                    )
                }
                MixerToggleButton(
                    title: track.solo
                        ? AppString.localized("mixer.track.unsolo", "Unsolo \(trackLabel)")
                        : AppString.localized("mixer.track.solo", "Solo \(trackLabel)"),
                    identifier: "Mixer Solo \(track.id.uuidString)",
                    systemImage: track.solo ? "headphones.circle.fill" : "headphones",
                    isOn: track.solo
                ) {
                    model.setTrackState(
                        sequenceID: sequenceID,
                        trackID: track.id,
                        solo: !track.solo
                    )
                }
            }
        }
        .frame(width: 88)
        .padding(8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppString.localized("mixer.track.strip.ax", "Audio track \(trackIndex + 1) mixer strip")
        )
    }
}

private struct MixerMasterStrip: View {
    @ObservedObject var model: EditorAjarAppModel

    var body: some View {
        VStack(spacing: 8) {
            Text(AppString.localized("mixer.master.label", "Master"))
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
            MixerMeterColumn(
                levels: model.mixerMeterSnapshot?.mixLevels ?? [],
                isClipping: model.mixerMeterSnapshot?.isMasterClipping ?? false,
                truePeak: model.mixerMeterSnapshot?.masterTruePeak,
                accessibilityLabel: AppString.localized("mixer.master.meter.ax", "Master meter")
            )
            MixerGainFader(
                label: AppString.localized("mixer.master.fader.ax", "Master volume"),
                identifier: "Mixer Master Gain",
                gainDB: AudioMixUISupport.gainDB(fromLinear: model.masterGainLinear),
                onChange: { db, phase in
                    model.setMasterGainDB(db, gesturePhase: phase)
                }
            )
            Text(AppString.localized("mixer.master.session", "Session"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    AppString.localized(
                        "mixer.master.session.ax",
                        "Master fader is session monitoring gain"
                    )
                )
        }
        .frame(width: 96)
        .padding(8)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppString.localized("mixer.master.strip.ax", "Master mixer strip"))
    }
}

private struct MixerMeterColumn: View {
    let levels: [AudioMeterChannelLevel]
    let isClipping: Bool
    var truePeak: Double?
    let accessibilityLabel: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            if levels.isEmpty {
                meterBar(heightFraction: 0.05, clipping: false)
                meterBar(heightFraction: 0.05, clipping: false)
            } else {
                ForEach(levels, id: \.channelIndex) { level in
                    meterBar(
                        heightFraction: meterHeightFraction(peak: level.peak),
                        clipping: level.peak >= 1.0
                    )
                }
            }
        }
        .frame(height: 72)
        .overlay(alignment: .top) {
            if isClipping {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(meterValueDescription)
        .accessibilityIdentifier(accessibilityLabel)
    }

    private var meterValueDescription: String {
        let peaks = levels.map { level in
            if let db = level.peakDBFS {
                return String(format: "%.1f dBFS", db)
            }
            return "−∞ dBFS"
        }
        var parts = peaks
        if let truePeak, let db = AudioMeterChannelLevel.dbFS(for: truePeak) {
            parts.append(String(format: "true peak %.1f dBTP", db))
        }
        if isClipping {
            parts.append(AppString.localized("mixer.meter.clipping", "clipping"))
        }
        return parts.joined(separator: ", ")
    }

    private func meterHeightFraction(peak: Double) -> CGFloat {
        guard peak.isFinite, peak > 0 else {
            return 0.04
        }
        let db = 20.0 * log10(peak)
        let normalized = (db - AudioMixUISupport.minimumGainDB)
            / (0 - AudioMixUISupport.minimumGainDB)
        return CGFloat(min(1, max(0.04, normalized)))
    }

    private func meterBar(heightFraction: CGFloat, clipping: Bool) -> some View {
        GeometryReader { geometry in
            VStack {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2)
                    .fill(clipping ? Color.red : Color.green.opacity(0.85))
                    .frame(height: max(2, geometry.size.height * heightFraction))
            }
        }
        .frame(width: 10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 2))
    }
}

private struct MixerGainFader: View {
    let label: String
    let identifier: String
    let gainDB: Double
    let onChange: (Double, AudioMixGesturePhase) -> Void

    @State private var draftDB: Double = 0
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%.1f dB", draftDB))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { draftDB },
                    set: { newValue in
                        draftDB = newValue
                        onChange(newValue, isDragging ? .changed : .discrete)
                    }
                ),
                in: AudioMixUISupport.minimumGainDB...AudioMixUISupport.maximumGainDB
            ) { editing in
                if editing {
                    isDragging = true
                    onChange(draftDB, .began)
                } else {
                    isDragging = false
                    onChange(draftDB, .ended)
                }
            }
            .controlSize(.small)
            .frame(width: 72)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(String(format: "%.1f dB", draftDB))
            .accessibilityAdjustableAction { direction in
                let step = 1.0
                switch direction {
                case .increment:
                    draftDB = min(AudioMixUISupport.maximumGainDB, draftDB + step)
                case .decrement:
                    draftDB = max(AudioMixUISupport.minimumGainDB, draftDB - step)
                @unknown default:
                    break
                }
                onChange(draftDB, .discrete)
            }
        }
        .onAppear { draftDB = gainDB }
        .onChange(of: gainDB) { newValue in
            if !isDragging {
                draftDB = newValue
            }
        }
    }
}

private struct MixerPanSlider: View {
    let label: String
    let identifier: String
    let pan: Double
    let onChange: (Double, AudioMixGesturePhase) -> Void

    @State private var draftPan: Double = 0
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 2) {
            Text(String(format: "Pan %.2f", draftPan))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { draftPan },
                    set: { newValue in
                        draftPan = newValue
                        onChange(newValue, isDragging ? .changed : .discrete)
                    }
                ),
                in: AudioMixLimits.minimumPan.doubleValue...AudioMixLimits.maximumPan.doubleValue
            ) { editing in
                if editing {
                    isDragging = true
                    onChange(draftPan, .began)
                } else {
                    isDragging = false
                    onChange(draftPan, .ended)
                }
            }
            .controlSize(.mini)
            .frame(width: 72)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(String(format: "%.2f", draftPan))
            .accessibilityAdjustableAction { direction in
                let step = 0.1
                switch direction {
                case .increment:
                    draftPan = min(AudioMixLimits.maximumPan.doubleValue, draftPan + step)
                case .decrement:
                    draftPan = max(AudioMixLimits.minimumPan.doubleValue, draftPan - step)
                @unknown default:
                    break
                }
                onChange(draftPan, .discrete)
            }
        }
        .onAppear { draftPan = pan }
        .onChange(of: pan) { newValue in
            if !isDragging {
                draftPan = newValue
            }
        }
    }
}

private struct MixerToggleButton: View {
    let title: String
    let identifier: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
                .frame(width: 28, height: 22)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? Color.accentColor : Color.secondary)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(
            isOn
                ? AppString.localized("state.on", "On")
                : AppString.localized("state.off", "Off")
        )
    }
}
