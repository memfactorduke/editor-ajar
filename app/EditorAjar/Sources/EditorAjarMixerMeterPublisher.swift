// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import Foundation

/// Publishes FR-AUD-003 mixer meter levels using **offline** analysis only.
///
/// Measurement runs on a dedicated utility queue via `AudioMixerMeterAnalyzer` and (for master
/// true-peak) `AudioMixerMeterAnalyzer.measureProgramLoudness`. The real-time audio callback is
/// never entered from this type (ADR-0012 / FR-AUD-007).
final class EditorAjarMixerMeterPublisher: @unchecked Sendable {
    /// Queue label — asserted by tests so the publish path cannot silently move onto the RT path.
    static let analysisQueueLabel = "org.editorajar.mixer-meter.analysis"

    private let analysisQueue: DispatchQueue
    private let publish: @MainActor (MixerMeterSnapshot) -> Void
    /// Monotonic request/cancel generation. Stale async results are dropped when it advances.
    /// Test seam for live-meter refresh while playing.
    private(set) var generation = 0

    /// Creates a publisher that always delivers snapshots on the main actor.
    init(publish: @escaping @MainActor (MixerMeterSnapshot) -> Void) {
        analysisQueue = DispatchQueue(label: Self.analysisQueueLabel, qos: .utility)
        self.publish = publish
    }

    /// Test seam: expose the analysis queue label without touching audio hardware.
    var analysisQueueLabelForTesting: String {
        analysisQueue.label
    }

    /// Whether work is scheduled on the off-RT analysis queue (not the audio render callback).
    var publishesOnOffRealtimePath: Bool {
        analysisQueue.label == Self.analysisQueueLabel
    }

    /// Schedules offline metering for a short window around the playhead.
    ///
    /// `masterGainLinear` is applied to the summed mix before peak / true-peak extraction so the
    /// master clip indicator tracks the monitoring master fader (FR-AUD-003).
    func requestMeter(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        sourceProvider: any AudioSourceProvider,
        masterGainLinear: Double
    ) {
        generation += 1
        let token = generation
        let gain = masterGainLinear
        analysisQueue.async { [weak self] in
            guard let self else {
                return
            }
            let snapshot = Self.measureSnapshot(
                project: project,
                sequence: sequence,
                playheadFrame: playheadFrame,
                sourceProvider: sourceProvider,
                masterGainLinear: gain
            )
            Task { @MainActor in
                guard self.generation == token else {
                    return
                }
                self.publish(snapshot)
            }
        }
    }

    /// Clears pending generations so a closed project does not publish stale meters.
    func cancel() {
        generation += 1
        Task { @MainActor in
            self.publish(.empty)
        }
    }

    /// Pure offline measure used by both production and unit tests.
    static func measureSnapshot(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        sourceProvider: any AudioSourceProvider,
        windowFrames: Int64 = 4,
        masterGainLinear: Double = 1.0
    ) -> MixerMeterSnapshot {
        do {
            let startFrame = max(0, playheadFrame)
            let durationFrames = max(1, windowFrames)
            let range = try TimeRange(
                start: RationalTime.atFrame(startFrame, frameRate: sequence.timebase),
                duration: sequence.timebase.duration(ofFrames: durationFrames)
            )
            let report = try AudioMixerMeterAnalyzer.measure(
                project: project,
                sequence: sequence,
                range: range,
                sourceProvider: sourceProvider,
                channelCount: 2
            )
            var trackMap: [UUID: [AudioMeterChannelLevel]] = [:]
            for reading in report.trackLevels {
                trackMap[reading.trackID] = reading.levels
            }

            let buffer = try OfflineAudioMixer.render(
                project: project,
                sequence: sequence,
                range: range,
                sourceProvider: sourceProvider,
                channelCount: 2
            )
            // Master fader is monitoring-only and post-mix — scale before master peak/true-peak.
            let meteredBuffer = try applyingMasterGain(masterGainLinear, to: buffer)
            let mixLevels = AudioMixerMeterAnalyzer.measure(buffer: meteredBuffer)
            let truePeak: Double?
            if meteredBuffer.frameCount > 0 {
                truePeak = try AudioMixerMeterAnalyzer.measureProgramLoudness(
                    buffer: meteredBuffer
                ).truePeak
            } else {
                truePeak = nil
            }

            return MixerMeterSnapshot(
                trackLevels: trackMap,
                mixLevels: mixLevels,
                masterTruePeak: truePeak
            )
        } catch {
            return .empty
        }
    }

    /// Mirrors `EditorAjarLiveAudioCoordinator.applyingMasterGain` for offline metering.
    private static func applyingMasterGain(
        _ linear: Double,
        to buffer: RenderedAudioBuffer
    ) throws -> RenderedAudioBuffer {
        guard linear != 1.0, linear.isFinite else {
            return buffer
        }
        let gain = Float(linear)
        let samples = buffer.samples.map { $0 * gain }
        return try RenderedAudioBuffer(
            format: buffer.format,
            frameCount: buffer.frameCount,
            samples: samples
        )
    }
}
