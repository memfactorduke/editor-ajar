// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Offline FR-AUD-003 master-gain recommendation for loudness normalization.
public struct AudioProgramLoudnessNormalizationResult: Codable, Equatable, Sendable {
    /// Requested integrated loudness target in LUFS.
    public let targetLUFS: Double

    /// Optional true-peak ceiling in dBTP.
    public let truePeakCeilingDBTP: Double?

    /// Measured integrated loudness before applying gain.
    public let measuredIntegratedLUFS: Double

    /// Measured true peak before applying gain, as linear amplitude.
    public let measuredTruePeak: Double

    /// Measured true peak before applying gain, in dBTP.
    public let measuredTruePeakDBTP: Double?

    /// Gain requested by the loudness target alone.
    public let requestedGainDB: Double

    /// Gain to apply after optional true-peak limiting.
    public let appliedGainDB: Double

    /// Linear master gain equivalent to `appliedGainDB`.
    public let appliedLinearGain: Double

    /// Predicted integrated loudness after applying `appliedGainDB`.
    public let achievedLUFS: Double

    /// Predicted true peak after applying `appliedGainDB`, as linear amplitude.
    public let achievedTruePeak: Double

    /// Predicted true peak after applying `appliedGainDB`, in dBTP.
    public let achievedTruePeakDBTP: Double?

    /// Whether the true-peak ceiling forced a lower gain than the loudness target requested.
    public let isTruePeakLimited: Bool
}

public extension AudioMixerMeterAnalyzer {
    /// Computes the deterministic master gain needed to normalize an already rendered buffer.
    ///
    /// FR-AUD-003 normalization is offline analysis, not a real-time callback. Integrated LUFS
    /// shifts by the applied gain in dB for a fixed gated block set, so a single measured report
    /// is enough for deterministic target-gain prediction. If the optional true-peak ceiling would
    /// be exceeded, the applied gain is clamped and the achieved LUFS intentionally falls short.
    static func normalizeProgramLoudness(
        buffer: RenderedAudioBuffer,
        targetLUFS: Double,
        truePeakCeilingDBTP: Double? = nil
    ) throws -> AudioProgramLoudnessNormalizationResult {
        try LoudnessNormalization.validate(
            targetLUFS: targetLUFS,
            truePeakCeilingDBTP: truePeakCeilingDBTP
        )
        let report = try measureProgramLoudness(buffer: buffer)
        return try LoudnessNormalization.result(
            report: report,
            targetLUFS: targetLUFS,
            truePeakCeilingDBTP: truePeakCeilingDBTP
        )
    }

    /// Renders a project sequence window, then computes the deterministic normalization gain.
    static func normalizeProgramLoudness(
        project: Project,
        sequence: Sequence,
        range: TimeRange,
        sourceProvider: any AudioSourceProvider,
        targetLUFS: Double,
        truePeakCeilingDBTP: Double? = nil,
        channelCount: Int = 2
    ) throws -> AudioProgramLoudnessNormalizationResult {
        let buffer = try OfflineAudioMixer.render(
            project: project,
            sequence: sequence,
            range: range,
            sourceProvider: sourceProvider,
            channelCount: channelCount
        )
        return try normalizeProgramLoudness(
            buffer: buffer,
            targetLUFS: targetLUFS,
            truePeakCeilingDBTP: truePeakCeilingDBTP
        )
    }

    /// Renders a sequence window, then computes the deterministic normalization gain.
    static func normalizeProgramLoudness(
        sequence: Sequence,
        range: TimeRange,
        format: AudioRenderFormat,
        sourceProvider: any AudioSourceProvider,
        targetLUFS: Double,
        truePeakCeilingDBTP: Double? = nil
    ) throws -> AudioProgramLoudnessNormalizationResult {
        let buffer = try OfflineAudioMixer.render(
            sequence: sequence,
            range: range,
            format: format,
            sourceProvider: sourceProvider
        )
        return try normalizeProgramLoudness(
            buffer: buffer,
            targetLUFS: targetLUFS,
            truePeakCeilingDBTP: truePeakCeilingDBTP
        )
    }
}

private enum LoudnessNormalization {
    static func validate(
        targetLUFS: Double,
        truePeakCeilingDBTP: Double?
    ) throws {
        guard targetLUFS.isFinite else {
            throw AudioProgramLoudnessError.nonFiniteNormalizationParameter("targetLUFS")
        }
        guard truePeakCeilingDBTP?.isFinite ?? true else {
            throw AudioProgramLoudnessError.nonFiniteNormalizationParameter("truePeakCeilingDBTP")
        }
    }

    static func result(
        report: AudioProgramLoudnessReport,
        targetLUFS: Double,
        truePeakCeilingDBTP: Double?
    ) throws -> AudioProgramLoudnessNormalizationResult {
        guard let measuredLUFS = report.integratedLUFS else {
            throw AudioProgramLoudnessError.silentProgram
        }

        let requestedGainDB = targetLUFS - measuredLUFS
        let peakLimitGainDB = truePeakCeilingDBTP.flatMap { ceiling in
            report.truePeakDBTP.map { ceiling - $0 }
        }
        let appliedGainDB = min(requestedGainDB, peakLimitGainDB ?? requestedGainDB)
        let appliedLinearGain = linearGain(decibels: appliedGainDB)
        let achievedTruePeak = report.truePeak * appliedLinearGain

        return AudioProgramLoudnessNormalizationResult(
            targetLUFS: targetLUFS,
            truePeakCeilingDBTP: truePeakCeilingDBTP,
            measuredIntegratedLUFS: measuredLUFS,
            measuredTruePeak: report.truePeak,
            measuredTruePeakDBTP: report.truePeakDBTP,
            requestedGainDB: requestedGainDB,
            appliedGainDB: appliedGainDB,
            appliedLinearGain: appliedLinearGain,
            achievedLUFS: measuredLUFS + appliedGainDB,
            achievedTruePeak: achievedTruePeak,
            achievedTruePeakDBTP: AudioMeterChannelLevel.dbFS(for: achievedTruePeak),
            isTruePeakLimited: appliedGainDB < requestedGainDB
        )
    }

    static func linearGain(decibels: Double) -> Double {
        pow(10, decibels / 20)
    }
}
