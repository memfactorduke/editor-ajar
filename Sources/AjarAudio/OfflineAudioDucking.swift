// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

struct OfflinePeakFrameContext {
    let mix: OfflineMixContext
    let outputFrame: Int
}

extension OfflineAudioMixer {
    static func duckingMultipliersByTrackID(
        renderPath: OfflineAudioRenderPath = [],
        rules: [AudioDuckingRule],
        tracks: [Track],
        context: OfflineMixContext,
        environment: inout OfflineAudioRenderEnvironment,
        nestingDepth: Int
    ) throws -> [UUID: [Double]] {
        guard !rules.isEmpty, context.frameCount > 0 else {
            return [:]
        }

        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        var multipliersByTargetID: [UUID: [Double]] = [:]
        var peaksByTriggerID: [UUID: [Double]] = [:]

        for (ruleIndex, rule) in rules.enumerated() {
            try context.cancellationCheck()
            guard let triggerTrack = tracksByID[rule.triggerTrackID] else {
                continue
            }

            let triggerPeaks = try cachedPeakLevels(
                for: triggerTrack,
                renderPath: renderPath,
                context: context,
                environment: &environment,
                peaksByTriggerID: &peaksByTriggerID,
                nestingDepth: nestingDepth
            )
            let continuationKey = OfflineDuckingContinuationKey(
                renderPath: renderPath,
                ruleIndex: ruleIndex
            )
            let previous = environment.continuation.duckingStates[continuationKey]
            var envelope =
                previous?.envelope(at: context.range.start) ?? OfflineDuckingEnvelopeState()
            var envelopeHistory = OfflineDuckingEnvelopeHistory()
            let ruleMultipliers = try duckingEnvelopeMultipliers(
                levels: triggerPeaks,
                rule: rule,
                format: context.format,
                envelope: &envelope,
                history: &envelopeHistory,
                cancellationCheck: context.cancellationCheck
            )
            environment.continuation.duckingStates[continuationKey] =
                try OfflineDuckingContinuationState(
                    range: context.range,
                    sampleRate: context.format.sampleRate,
                    history: envelopeHistory
                )
            for targetTrackID in Set(rule.targetTrackIDs) where tracksByID[targetTrackID] != nil {
                var targetMultipliers =
                    multipliersByTargetID[targetTrackID]
                    ?? Array(repeating: 1, count: context.frameCount)
                for outputFrame in targetMultipliers.indices {
                    try context.checkCancellation(atFrame: outputFrame)
                    targetMultipliers[outputFrame] *= ruleMultipliers[outputFrame]
                }
                multipliersByTargetID[targetTrackID] = targetMultipliers
            }
        }

        return multipliersByTargetID
    }

    // swiftlint:disable:next function_parameter_count
    static func cachedPeakLevels(
        for triggerTrack: Track,
        renderPath: OfflineAudioRenderPath,
        context: OfflineMixContext,
        environment: inout OfflineAudioRenderEnvironment,
        peaksByTriggerID: inout [UUID: [Double]],
        nestingDepth: Int
    ) throws -> [Double] {
        if let cachedPeaks = peaksByTriggerID[triggerTrack.id] {
            return cachedPeaks
        }

        let peaks = try trackPeakLevels(
            triggerTrack,
            renderPath: renderPath,
            context: context,
            environment: &environment,
            nestingDepth: nestingDepth
        )
        peaksByTriggerID[triggerTrack.id] = peaks
        return peaks
    }

    static func trackPeakLevels(
        _ track: Track,
        renderPath: OfflineAudioRenderPath,
        context: OfflineMixContext,
        environment: inout OfflineAudioRenderEnvironment,
        nestingDepth: Int
    ) throws -> [Double] {
        var levels = Array(repeating: Double(0), count: context.frameCount)
        for (itemIndex, item) in track.items.enumerated() {
            try context.cancellationCheck()
            guard case .clip(let clip) = item, clip.kind == .audio else {
                continue
            }
            guard
                let sourceWindow = try requiredSourceWindow(
                    for: clip,
                    renderRange: context.range
                )
            else {
                continue
            }

            let source = try sourceBuffer(
                for: clip,
                requiredSourceWindow: sourceWindow,
                context: context,
                environment: &environment,
                nestingDepth: nestingDepth,
                renderPath: clipOccurrenceRenderPath(
                    renderPath,
                    trackID: track.id,
                    itemIndex: itemIndex,
                    clipID: clip.id
                )
            )
            try peakClipLevels(
                state: retimedClipMixState(
                    clip: clip,
                    track: track,
                    source: source,
                    environment: &environment
                ),
                levels: &levels,
                context: context
            )
        }
        return levels
    }

    static func peakClipLevels(
        state: OfflineClipMixState,
        levels: inout [Double],
        context: OfflineMixContext
    ) throws {
        let intersection = try intersectionFrames(
            clip: state.clip,
            range: context.range,
            frameCount: context.frameCount,
            sampleRate: context.format.sampleRate
        )
        guard intersection.lowerBound < intersection.upperBound else {
            return
        }

        for outputFrame in intersection {
            try context.checkCancellation(atFrame: outputFrame)
            try peakClipFrame(
                state: state,
                levels: &levels,
                frame: OfflinePeakFrameContext(mix: context, outputFrame: outputFrame)
            )
        }
    }

    static func peakClipFrame(
        state: OfflineClipMixState,
        levels: inout [Double],
        frame: OfflinePeakFrameContext
    ) throws {
        let clip = state.clip
        let renderTime = try renderTime(
            rangeStart: frame.mix.range.start,
            outputFrame: frame.outputFrame,
            sampleRate: frame.mix.format.sampleRate
        )
        let localTime = try subtract(renderTime, clip.timelineRange.start)
        // The trigger detector samples through the exact tail-aware, EOF-clamped mapping the
        // mixer plays (ADR-0015 §2/§7): reverse tails read backward past `sourceRange.start`,
        // and a tail past the declared media end is silence — so ducking can never fire on
        // audio the mix does not play (FR-AUD-002, FR-AUD-004).
        guard
            let sourceFrame = try resolvedSourceFramePosition(
                state: state,
                renderTime: renderTime
            )
        else {
            return
        }
        // Crossfade tails stay in the trigger envelope at their ADR-0015 §4 ramped level.
        let crossfadeGain = try crossfadeGainMultiplier(clip: clip, renderTime: renderTime)
        let gain =
            gainMultiplier(
                clip: clip,
                track: state.track,
                renderTime: renderTime,
                localTime: localTime
            ) * crossfadeGain
        let pan = panValue(clip: clip, track: state.track, renderTime: renderTime)

        var peak = Double(0)
        for outputChannel in 0..<frame.mix.format.channelCount {
            let sourceSample = mappedSourceSample(
                source: state.source,
                framePosition: sourceFrame,
                outputChannel: outputChannel,
                outputChannelCount: frame.mix.format.channelCount
            )
            let panned =
                Double(abs(sourceSample))
                * panMultiplier(pan: pan, channel: outputChannel, format: frame.mix.format)
            peak = max(peak, panned * gain)
        }
        // FR-AUD-004 sidechain detection is a peak detector: overlapping trigger clips use the
        // loudest per-frame contribution rather than summing into a bus-level trigger.
        levels[frame.outputFrame] = max(levels[frame.outputFrame], peak)
    }

    static func duckingEnvelopeMultipliers(
        levels: [Double],
        rule: AudioDuckingRule,
        format: AudioRenderFormat,
        cancellationCheck: AudioRenderCancellationCheck = {}
    ) throws -> [Double] {
        var envelope = OfflineDuckingEnvelopeState()
        var history = OfflineDuckingEnvelopeHistory()
        return try duckingEnvelopeMultipliers(
            levels: levels,
            rule: rule,
            format: format,
            envelope: &envelope,
            history: &history,
            cancellationCheck: cancellationCheck
        )
    }

    // swiftlint:disable:next function_parameter_count
    static func duckingEnvelopeMultipliers(
        levels: [Double],
        rule: AudioDuckingRule,
        format: AudioRenderFormat,
        envelope: inout OfflineDuckingEnvelopeState,
        history: inout OfflineDuckingEnvelopeHistory,
        cancellationCheck: AudioRenderCancellationCheck
    ) throws -> [Double] {
        let reductionGain = clamped01(rule.reductionGain.doubleValue)
        let threshold = max(0, rule.threshold.doubleValue)
        let attackFrames = try envelopeFrameCount(for: rule.attack, format: format)
        let releaseFrames = try envelopeFrameCount(for: rule.release, format: format)
        let holdFrames = try envelopeFrameCount(for: rule.hold, format: format)

        var multipliers: [Double] = []
        multipliers.reserveCapacity(levels.count)
        var duckingAmount = envelope.amount
        var holdRemaining = envelope.holdRemaining
        history.append(envelope)

        for (frame, level) in levels.enumerated() {
            if frame & 1_023 == 0 {
                try cancellationCheck()
            }
            if level > threshold {
                holdRemaining = holdFrames
                duckingAmount = rampUp(duckingAmount, attackFrames: attackFrames)
            } else if holdRemaining > 0 {
                holdRemaining -= 1
            } else {
                duckingAmount = rampDown(duckingAmount, releaseFrames: releaseFrames)
            }

            multipliers.append(1 - ((1 - reductionGain) * duckingAmount))
            history.append(
                OfflineDuckingEnvelopeState(
                    amount: duckingAmount,
                    holdRemaining: holdRemaining
                )
            )
        }

        envelope.amount = duckingAmount
        envelope.holdRemaining = holdRemaining
        return multipliers
    }

    static func envelopeFrameCount(
        for duration: RationalTime,
        format: AudioRenderFormat
    ) throws -> Int {
        try sampleIndex(
            for: duration,
            sampleRate: format.sampleRate,
            rounding: .nearestOrAwayFromZero
        )
    }

    static func rampUp(_ amount: Double, attackFrames: Int) -> Double {
        guard attackFrames > 0 else {
            return 1
        }
        return min(1, amount + (1 / Double(attackFrames)))
    }

    static func rampDown(_ amount: Double, releaseFrames: Int) -> Double {
        guard releaseFrames > 0 else {
            return 0
        }
        return max(0, amount - (1 / Double(releaseFrames)))
    }
}
