// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

public extension AudioMixerMeterAnalyzer {
    /// Computes BS.1770/R128 integrated loudness and 4x true peak for a rendered buffer.
    ///
    /// This is deterministic offline analysis for FR-AUD-003, not the FR-AUD-007 real-time audio
    /// callback path. K-weighting follows the BS.1770 two-stage high-shelf plus RLB high-pass
    /// filter model; stereo uses L/R channel weights of 1.0 and surround layout weighting is out of
    /// scope until layout metadata is available.
    static func measureProgramLoudness(
        buffer: RenderedAudioBuffer
    ) throws -> AudioProgramLoudnessReport {
        try measureProgramLoudness(buffer: buffer, cancellationCheck: {})
    }

    /// Computes program loudness and true peak while cooperatively polling for cancellation.
    static func measureProgramLoudness(
        buffer: RenderedAudioBuffer,
        cancellationCheck: @escaping AudioRenderCancellationCheck
    ) throws -> AudioProgramLoudnessReport {
        try cancellationCheck()
        try BS1770.validate(sampleRate: buffer.format.sampleRate)
        try BS1770.validate(channelCount: buffer.format.channelCount)
        let powers = try BS1770.kWeightedPowers(
            buffer: buffer,
            cancellationCheck: cancellationCheck
        )
        let blockEnergies = try BS1770.blockEnergies(
            powers: powers,
            sampleRate: buffer.format.sampleRate,
            cancellationCheck: cancellationCheck
        )
        let gated = try BS1770.gatedLoudness(
            blockEnergies: blockEnergies,
            cancellationCheck: cancellationCheck
        )
        let truePeak = try BS1770.truePeak(
            buffer: buffer,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()

        return AudioProgramLoudnessReport(
            sampleRate: buffer.format.sampleRate,
            channelCount: buffer.format.channelCount,
            frameCount: buffer.frameCount,
            integratedLUFS: gated.integratedLUFS,
            truePeak: truePeak,
            blockCount: blockEnergies.count,
            gatedBlockCount: gated.gatedBlockCount,
            truePeakOversamplingFactor: BS1770.truePeakOversamplingFactor
        )
    }

    /// Renders a project sequence window, then computes integrated loudness and true peak.
    static func measureProgramLoudness(
        project: Project,
        sequence: Sequence,
        range: TimeRange,
        sourceProvider: any AudioSourceProvider,
        channelCount: Int = 2
    ) throws -> AudioProgramLoudnessReport {
        let buffer = try OfflineAudioMixer.render(
            project: project,
            sequence: sequence,
            range: range,
            sourceProvider: sourceProvider,
            channelCount: channelCount
        )
        return try measureProgramLoudness(buffer: buffer)
    }

    /// Renders a sequence window, then computes integrated loudness and true peak.
    static func measureProgramLoudness(
        sequence: Sequence,
        range: TimeRange,
        format: AudioRenderFormat,
        sourceProvider: any AudioSourceProvider
    ) throws -> AudioProgramLoudnessReport {
        let buffer = try OfflineAudioMixer.render(
            sequence: sequence,
            range: range,
            format: format,
            sourceProvider: sourceProvider
        )
        return try measureProgramLoudness(buffer: buffer)
    }
}
