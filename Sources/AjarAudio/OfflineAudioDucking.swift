// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

struct OfflinePeakFrameContext {
    let mix: OfflineMixContext
    let outputFrame: Int
}

extension OfflineAudioMixer {
    static func duckingMultipliersByTrackID(
        rules: [AudioDuckingRule],
        tracks: [Track],
        context: OfflineMixContext,
        sourceProvider: any AudioSourceProvider,
        sourceCache: inout [UUID: AudioSourceBuffer]
    ) throws -> [UUID: [Double]] {
        guard !rules.isEmpty, context.frameCount > 0 else {
            return [:]
        }

        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        var multipliersByTargetID: [UUID: [Double]] = [:]
        var peaksByTriggerID: [UUID: [Double]] = [:]

        for rule in rules {
            guard let triggerTrack = tracksByID[rule.triggerTrackID] else {
                continue
            }

            let triggerPeaks = try cachedPeakLevels(
                for: triggerTrack,
                context: context,
                sourceProvider: sourceProvider,
                sourceCache: &sourceCache,
                peaksByTriggerID: &peaksByTriggerID
            )
            let ruleMultipliers = try duckingEnvelopeMultipliers(
                levels: triggerPeaks,
                rule: rule,
                format: context.format
            )
            for targetTrackID in Set(rule.targetTrackIDs) where tracksByID[targetTrackID] != nil {
                var targetMultipliers = multipliersByTargetID[targetTrackID]
                    ?? Array(repeating: 1, count: context.frameCount)
                for outputFrame in targetMultipliers.indices {
                    targetMultipliers[outputFrame] *= ruleMultipliers[outputFrame]
                }
                multipliersByTargetID[targetTrackID] = targetMultipliers
            }
        }

        return multipliersByTargetID
    }

    static func cachedPeakLevels(
        for triggerTrack: Track,
        context: OfflineMixContext,
        sourceProvider: any AudioSourceProvider,
        sourceCache: inout [UUID: AudioSourceBuffer],
        peaksByTriggerID: inout [UUID: [Double]]
    ) throws -> [Double] {
        if let cachedPeaks = peaksByTriggerID[triggerTrack.id] {
            return cachedPeaks
        }

        let peaks = try trackPeakLevels(
            triggerTrack,
            context: context,
            sourceProvider: sourceProvider,
            sourceCache: &sourceCache
        )
        peaksByTriggerID[triggerTrack.id] = peaks
        return peaks
    }

    static func trackPeakLevels(
        _ track: Track,
        context: OfflineMixContext,
        sourceProvider: any AudioSourceProvider,
        sourceCache: inout [UUID: AudioSourceBuffer]
    ) throws -> [Double] {
        var levels = Array(repeating: Double(0), count: context.frameCount)
        for item in track.items {
            guard case .clip(let clip) = item, clip.kind == .audio else {
                continue
            }

            let source = try sourceBuffer(
                for: clip,
                sourceProvider: sourceProvider,
                sourceCache: &sourceCache
            )
            try peakClipLevels(
                clip,
                track: track,
                source: source,
                levels: &levels,
                context: context
            )
        }
        return levels
    }

    static func peakClipLevels(
        _ clip: Clip,
        track: Track,
        source: AudioSourceBuffer,
        levels: inout [Double],
        context: OfflineMixContext
    ) throws {
        let intersection = try intersectionFrames(
            clip: clip,
            range: context.range,
            frameCount: context.frameCount,
            sampleRate: context.format.sampleRate
        )
        guard intersection.lowerBound < intersection.upperBound else {
            return
        }

        for outputFrame in intersection {
            try peakClipFrame(
                clip,
                track: track,
                source: source,
                levels: &levels,
                frame: OfflinePeakFrameContext(mix: context, outputFrame: outputFrame)
            )
        }
    }

    static func peakClipFrame(
        _ clip: Clip,
        track: Track,
        source: AudioSourceBuffer,
        levels: inout [Double],
        frame: OfflinePeakFrameContext
    ) throws {
        let renderTime = try renderTime(
            rangeStart: frame.mix.range.start,
            outputFrame: frame.outputFrame,
            sampleRate: frame.mix.format.sampleRate
        )
        let localTime = try subtract(renderTime, clip.timelineRange.start)
        let sourceTime = try clipSourceTime(clip, at: renderTime)
        let sourceFrame = sourceTime.seconds * Double(source.format.sampleRate)
        let gain = gainMultiplier(
            clip: clip,
            track: track,
            renderTime: renderTime,
            localTime: localTime
        )
        let pan = panValue(clip: clip, track: track, renderTime: renderTime)

        var peak = Double(0)
        for outputChannel in 0..<frame.mix.format.channelCount {
            let sourceSample = mappedSourceSample(
                source: source,
                framePosition: sourceFrame,
                outputChannel: outputChannel,
                outputChannelCount: frame.mix.format.channelCount
            )
            let panned = Double(abs(sourceSample))
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
        format: AudioRenderFormat
    ) throws -> [Double] {
        let reductionGain = clamped01(rule.reductionGain.doubleValue)
        let threshold = max(0, rule.threshold.doubleValue)
        let attackFrames = try envelopeFrameCount(for: rule.attack, format: format)
        let releaseFrames = try envelopeFrameCount(for: rule.release, format: format)
        let holdFrames = try envelopeFrameCount(for: rule.hold, format: format)

        var multipliers: [Double] = []
        multipliers.reserveCapacity(levels.count)
        var duckingAmount = Double(0)
        var holdRemaining = 0

        for level in levels {
            if level > threshold {
                holdRemaining = holdFrames
                duckingAmount = rampUp(duckingAmount, attackFrames: attackFrames)
            } else if holdRemaining > 0 {
                holdRemaining -= 1
            } else {
                duckingAmount = rampDown(duckingAmount, releaseFrames: releaseFrames)
            }

            multipliers.append(1 - ((1 - reductionGain) * duckingAmount))
        }

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
