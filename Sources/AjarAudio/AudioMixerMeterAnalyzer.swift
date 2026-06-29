// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Peak and RMS readings for one interleaved PCM channel.
public struct AudioMeterChannelLevel: Codable, Equatable, Sendable {
    /// Zero-based channel index.
    public let channelIndex: Int

    /// Sample peak as max absolute amplitude. 0 dBFS is linear amplitude 1.0.
    public let peak: Double

    /// Root-mean-square amplitude. 0 dBFS is linear amplitude 1.0.
    public let rms: Double

    /// Peak converted to dBFS, where 0 dBFS is linear amplitude 1.0.
    public var peakDBFS: Double? {
        Self.dbFS(for: peak)
    }

    /// RMS converted to dBFS, where 0 dBFS is linear amplitude 1.0.
    public var rmsDBFS: Double? {
        Self.dbFS(for: rms)
    }

    /// Creates a channel meter reading.
    public init(channelIndex: Int, peak: Double, rms: Double) {
        self.channelIndex = channelIndex
        self.peak = peak
        self.rms = rms
    }

    /// Converts a linear amplitude into dBFS using 1.0 as the 0 dBFS reference.
    public static func dbFS(for amplitude: Double) -> Double? {
        guard amplitude > 0, amplitude.isFinite else {
            return nil
        }
        return 20 * log10(amplitude)
    }
}

/// Meter readings for one rendered audio track contribution.
public struct AudioTrackMeterReading: Codable, Equatable, Sendable {
    /// Stable track ID from the project timeline.
    public let trackID: UUID

    /// Per-channel track contribution levels.
    public let levels: [AudioMeterChannelLevel]

    /// Creates a track meter reading.
    public init(trackID: UUID, levels: [AudioMeterChannelLevel]) {
        self.trackID = trackID
        self.levels = levels
    }
}

/// Deterministic meter report for a rendered mixer window.
public struct AudioMixerMeterReport: Codable, Equatable, Sendable {
    /// Rendered time window.
    public let range: TimeRange

    /// Render sample rate in hertz.
    public let sampleRate: Int

    /// Rendered channel count.
    public let channelCount: Int

    /// Number of complete frames in the analyzed window.
    public let frameCount: Int

    /// Per-track readings in selected render order.
    public let trackLevels: [AudioTrackMeterReading]

    /// Per-channel summed master mix levels.
    public let mixLevels: [AudioMeterChannelLevel]

    /// Creates a mixer meter report.
    public init(
        range: TimeRange,
        sampleRate: Int,
        channelCount: Int,
        frameCount: Int,
        trackLevels: [AudioTrackMeterReading],
        mixLevels: [AudioMeterChannelLevel]
    ) {
        self.range = range
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.trackLevels = trackLevels
        self.mixLevels = mixLevels
    }
}

/// Deterministic offline meter analysis for rendered audio buffers and mixer windows.
public enum AudioMixerMeterAnalyzer {
    /// Computes per-channel peak and RMS levels for an already rendered buffer.
    public static func measure(buffer: RenderedAudioBuffer) -> [AudioMeterChannelLevel] {
        levels(
            samples: buffer.samples,
            frameCount: buffer.frameCount,
            channelCount: buffer.format.channelCount
        )
    }

    /// Renders and meters selected audio tracks plus the summed master mix for a project sequence.
    public static func measure(
        project: Project,
        sequence: Sequence,
        range: TimeRange,
        sourceProvider: any AudioSourceProvider,
        channelCount: Int = 2
    ) throws -> AudioMixerMeterReport {
        try measure(
            sequence: sequence,
            range: range,
            format: AudioRenderFormat(
                sampleRate: project.settings.audioSampleRate,
                channelCount: channelCount
            ),
            sourceProvider: sourceProvider
        )
    }

    /// Renders and meters selected audio tracks plus the summed master mix for a time window.
    ///
    /// Generation may allocate because it is offline analysis over the rendered mix, not the
    /// FR-AUD-007 real-time audio callback path.
    public static func measure(
        sequence: Sequence,
        range: TimeRange,
        format: AudioRenderFormat,
        sourceProvider: any AudioSourceProvider
    ) throws -> AudioMixerMeterReport {
        try AudioBufferValidator.validate(format: format, frameCount: 0, samples: [])
        try OfflineAudioMixer.validateCrossfades(in: sequence)

        let frameCount = try OfflineAudioMixer.sampleIndex(
            for: range.duration,
            sampleRate: format.sampleRate,
            rounding: .nearestOrAwayFromZero
        )
        let sampleCount = try OfflineAudioMixer.sampleCount(
            frameCount: frameCount,
            channelCount: format.channelCount
        )
        let context = OfflineMixContext(frameCount: frameCount, range: range, format: format)
        let audioTracks = OfflineAudioMixer.selectedAudioTracks(sequence.audioTracks)
        var sourceCache: [UUID: AudioSourceBuffer] = [:]
        let duckingMultipliers = try OfflineAudioMixer.duckingMultipliersByTrackID(
            rules: sequence.audioDucking,
            tracks: audioTracks,
            context: context,
            sourceProvider: sourceProvider,
            sourceCache: &sourceCache
        )
        let measured = try measuredTracks(
            request: TrackMeasurementRequest(
                tracks: audioTracks,
                sampleCount: sampleCount,
                context: context,
                duckingMultipliers: duckingMultipliers,
                sourceProvider: sourceProvider
            ),
            sourceCache: &sourceCache
        )

        return AudioMixerMeterReport(
            range: range,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            frameCount: frameCount,
            trackLevels: measured.trackLevels,
            mixLevels: levels(
                samples: measured.mixSamples,
                frameCount: frameCount,
                channelCount: format.channelCount
            )
        )
    }
}

private extension AudioMixerMeterAnalyzer {
    struct MeasuredTracks {
        let trackLevels: [AudioTrackMeterReading]
        let mixSamples: [Float]
    }

    struct TrackMeasurementRequest {
        let tracks: [Track]
        let sampleCount: Int
        let context: OfflineMixContext
        let duckingMultipliers: [UUID: [Double]]
        let sourceProvider: any AudioSourceProvider
    }

    static func measuredTracks(
        request: TrackMeasurementRequest,
        sourceCache: inout [UUID: AudioSourceBuffer]
    ) throws -> MeasuredTracks {
        var trackLevels: [AudioTrackMeterReading] = []
        trackLevels.reserveCapacity(request.tracks.count)
        var mixSamples = Array(repeating: Float(0), count: request.sampleCount)

        for track in request.tracks {
            var trackSamples = Array(repeating: Float(0), count: request.sampleCount)
            try OfflineAudioMixer.mixTrack(
                track,
                into: &trackSamples,
                context: OfflineTrackMixContext(
                    mix: request.context,
                    duckingMultipliers: request.duckingMultipliers[track.id]
                ),
                sourceProvider: request.sourceProvider,
                sourceCache: &sourceCache
            )
            for index in trackSamples.indices {
                mixSamples[index] += trackSamples[index]
            }
            trackLevels.append(
                AudioTrackMeterReading(
                    trackID: track.id,
                    levels: levels(
                        samples: trackSamples,
                        frameCount: request.context.frameCount,
                        channelCount: request.context.format.channelCount
                    )
                )
            )
        }

        return MeasuredTracks(trackLevels: trackLevels, mixSamples: mixSamples)
    }

    static func levels(
        samples: [Float],
        frameCount: Int,
        channelCount: Int
    ) -> [AudioMeterChannelLevel] {
        var levels: [AudioMeterChannelLevel] = []
        levels.reserveCapacity(channelCount)

        for channelIndex in 0..<channelCount {
            levels.append(
                level(
                    samples: samples,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    channelIndex: channelIndex
                )
            )
        }

        return levels
    }

    static func level(
        samples: [Float],
        frameCount: Int,
        channelCount: Int,
        channelIndex: Int
    ) -> AudioMeterChannelLevel {
        guard frameCount > 0 else {
            return AudioMeterChannelLevel(channelIndex: channelIndex, peak: 0, rms: 0)
        }

        var peak = Double(0)
        var sumOfSquares = Double(0)
        for frame in 0..<frameCount {
            let value = Double(abs(samples[(frame * channelCount) + channelIndex]))
            peak = max(peak, value)
            sumOfSquares += value * value
        }

        return AudioMeterChannelLevel(
            channelIndex: channelIndex,
            peak: peak,
            rms: (sumOfSquares / Double(frameCount)).squareRoot()
        )
    }
}
