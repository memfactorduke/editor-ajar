// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Constant envelope: `pmF = Float(pm_d)` per channel; `baseGain` stays Double for duck fold.
struct OfflineConstantEnvelopePlan {
    /// `Float(panMultiplier(...))` per output channel.
    let panMultipliers: [Float]

    /// Clip×track×fade gain in double (crossfade is 1 on this path; ducking applied later).
    let baseGain: Double
}

/// Integer 1:1 source-frame mapping for unit-rate, non-retimed clips.
struct OfflineUnitRateIntegerMapping {
    let originOutputFrame: Int
    let originSourceFrame: Int
}

/// Shared inputs for the unit-rate bulk mix helpers.
struct OfflineUnitRateMixRequest {
    let source: AudioSourceBuffer
    let intersection: Range<Int>
    let plan: OfflineConstantEnvelopePlan
    let format: AudioRenderFormat
    let originSourceFrame: Int
}

extension OfflineAudioMixer {
    static func mixTrack(
        _ track: Track,
        into output: inout [Float],
        context: OfflineTrackMixContext,
        environment: inout OfflineAudioRenderEnvironment,
        nestingDepth: Int
    ) throws {
        for item in track.items {
            guard case .clip(let clip) = item, clipCarriesAudio(clip, on: track) else {
                continue
            }
            let source = try sourceBuffer(
                for: clip,
                context: context.mix,
                environment: &environment,
                nestingDepth: nestingDepth
            )
            try validateTailSourceDelivery(
                clip: clip,
                source: source,
                context: context.mix,
                environment: environment
            )
            try mixClip(
                state: retimedClipMixState(
                    clip: clip,
                    track: track,
                    source: source,
                    environment: &environment
                ),
                into: &output,
                context: context
            )
        }
    }

    static func mixClip(
        state: OfflineClipMixState,
        into output: inout [Float],
        context: OfflineTrackMixContext,
        forceExact: Bool = false
    ) throws {
        let intersection = try intersectionFrames(
            clip: state.clip,
            range: context.mix.range,
            frameCount: context.mix.frameCount,
            sampleRate: context.mix.format.sampleRate
        )
        guard intersection.lowerBound < intersection.upperBound else {
            return
        }

        // FR-AUD-007 / #178: unit-rate integer bulk path when constructively eligible.
        if !forceExact {
            if try mixClipOptimized(
                state: state,
                into: &output,
                context: context,
                intersection: intersection
            ) {
                return
            }
        }

        try mixClipExact(
            state: state,
            into: &output,
            context: context,
            intersection: intersection
        )
    }

    /// Per-sample rational path (exact). Fallback and differential-test baseline.
    static func mixClipExact(
        state: OfflineClipMixState,
        into output: inout [Float],
        context: OfflineTrackMixContext,
        intersection: Range<Int>
    ) throws {
        for outputFrame in intersection {
            let renderTime = try renderTime(
                rangeStart: context.mix.range.start,
                outputFrame: outputFrame,
                sampleRate: context.mix.format.sampleRate
            )
            try mixClipFrame(
                state: state,
                frame: OfflineMixFrameContext(
                    renderTime: renderTime,
                    outputFrame: outputFrame,
                    format: context.mix.format,
                    duckingMultiplier: context.duckingMultipliers?[outputFrame] ?? 1
                ),
                output: &output
            )
        }
    }

    static func mixClipFrame(
        state: OfflineClipMixState,
        frame: OfflineMixFrameContext,
        output: inout [Float]
    ) throws {
        let clip = state.clip
        let source = state.source
        let renderTime = frame.renderTime
        let format = frame.format
        let localTime = try subtract(renderTime, clip.timelineRange.start)
        // ADR-0015 §7 confirmed EOF (`nil`): the mapped tail passed the declared media end, so
        // it silence-pads deterministically regardless of how many frames the provider had.
        guard
            let sourceFrame = try resolvedSourceFramePosition(
                state: state,
                renderTime: renderTime
            )
        else {
            return
        }
        let crossfadeGain = try crossfadeGainMultiplier(clip: clip, renderTime: renderTime)
        let gain =
            gainMultiplier(
                clip: clip,
                track: state.track,
                renderTime: renderTime,
                localTime: localTime
            ) * frame.duckingMultiplier * crossfadeGain
        let pan = panValue(clip: clip, track: state.track, renderTime: renderTime)

        for outputChannel in 0..<format.channelCount {
            let sourceSample = mappedSourceSample(
                source: source,
                framePosition: sourceFrame,
                outputChannel: outputChannel,
                outputChannelCount: format.channelCount
            )
            let panned =
                sourceSample
                * Float(
                    panMultiplier(pan: pan, channel: outputChannel, format: format)
                )
            let outputIndex = (frame.outputFrame * format.channelCount) + outputChannel
            output[outputIndex] += panned * Float(gain)
        }
    }

    /// Unit-rate bulk mix when constructively eligible. `true` => handled (FR-AUD-007 / #178).
    static func mixClipOptimized(
        state: OfflineClipMixState,
        into output: inout [Float],
        context: OfflineTrackMixContext,
        intersection: Range<Int>
    ) throws -> Bool {
        guard isConstructivelyUnitRateEligible(state: state) else {
            return false
        }
        guard
            let plan = try makeConstantEnvelopePlan(
                state: state,
                context: context,
                intersection: intersection
            )
        else {
            return false
        }
        guard
            let mapping = try makeUnitRateIntegerMapping(
                state: state,
                context: context,
                intersection: intersection
            )
        else {
            return false
        }

        let request = OfflineUnitRateMixRequest(
            source: state.source,
            intersection: intersection,
            plan: plan,
            format: context.mix.format,
            originSourceFrame: mapping.originSourceFrame
        )
        return mixClipUnitRateIntegerSource(
            request: request,
            into: &output,
            duckingMultipliers: context.duckingMultipliers
        )
    }

    /// Constructive eligibility: no retiming of any kind (the #178 hot case is flat unit-speed).
    static func isConstructivelyUnitRateEligible(state: OfflineClipMixState) -> Bool {
        let clip = state.clip
        return state.stretchedRead == nil
            && state.declaredTailSourceEndFrame == nil
            && clip.speed == .one
            && !clip.reverse
            && !clip.freezeFrame
            && clip.timeRemap == nil
    }
}

extension OfflineAudioMixer {
    /// Builds a constant envelope plan when gain/pan/fades/crossfades are static.
    static func makeConstantEnvelopePlan(
        state: OfflineClipMixState,
        context: OfflineTrackMixContext,
        intersection: Range<Int>
    ) throws -> OfflineConstantEnvelopePlan? {
        let clip = state.clip
        let track = state.track
        guard clip.audioMix.gain.keyframes.isEmpty,
            track.audioGain.keyframes.isEmpty,
            clip.audioMix.pan.keyframes.isEmpty,
            track.audioPan.keyframes.isEmpty,
            clip.audioMix.fadeIn.duration <= .zero,
            clip.audioMix.fadeOut.duration <= .zero,
            clip.audioMix.leadingCrossfade == nil,
            clip.audioMix.trailingCrossfade == nil
        else {
            return nil
        }

        let format = context.mix.format
        let renderTime = try renderTime(
            rangeStart: context.mix.range.start,
            outputFrame: intersection.lowerBound,
            sampleRate: format.sampleRate
        )
        let localTime = try subtract(renderTime, clip.timelineRange.start)
        let baseGain = gainMultiplier(
            clip: clip,
            track: track,
            renderTime: renderTime,
            localTime: localTime
        )
        let pan = panValue(clip: clip, track: track, renderTime: renderTime)
        var panMultipliers: [Float] = []
        panMultipliers.reserveCapacity(format.channelCount)
        for channel in 0..<format.channelCount {
            // Match slow path: convert pan multiplier to Float independently of gain.
            panMultipliers.append(
                Float(panMultiplier(pan: pan, channel: channel, format: format))
            )
        }
        return OfflineConstantEnvelopePlan(panMultipliers: panMultipliers, baseGain: baseGain)
    }

    /// Integer unit-rate mapping (origin integer, step == 1) plus endpoint invariant check.
    static func makeUnitRateIntegerMapping(
        state: OfflineClipMixState,
        context: OfflineTrackMixContext,
        intersection: Range<Int>
    ) throws -> OfflineUnitRateIntegerMapping? {
        let startFrame = intersection.lowerBound
        guard
            let originSourceFrame = try sourceFrameAtOutput(
                state: state,
                context: context,
                outputFrame: startFrame
            )
        else {
            return nil
        }
        guard let originInt = exactNonNegativeInteger(originSourceFrame) else {
            return nil
        }

        if intersection.count > 1 {
            guard
                let secondSourceFrame = try sourceFrameAtOutput(
                    state: state,
                    context: context,
                    outputFrame: startFrame + 1
                ),
                secondSourceFrame == Double(originInt + 1)
            else {
                return nil
            }
        }

        // Invariant: last sample must also land on origin + (count - 1).
        let lastFrame = intersection.upperBound - 1
        if lastFrame > startFrame + 1 {
            guard
                let lastSourceFrame = try sourceFrameAtOutput(
                    state: state,
                    context: context,
                    outputFrame: lastFrame
                ),
                lastSourceFrame == Double(originInt + (lastFrame - startFrame))
            else {
                return nil
            }
        }

        return OfflineUnitRateIntegerMapping(
            originOutputFrame: startFrame,
            originSourceFrame: originInt
        )
    }

    /// Exact resolver position for one output sample, or `nil` for ADR-0015 §7 EOF silence.
    static func sourceFrameAtOutput(
        state: OfflineClipMixState,
        context: OfflineTrackMixContext,
        outputFrame: Int
    ) throws -> Double? {
        let renderTime = try renderTime(
            rangeStart: context.mix.range.start,
            outputFrame: outputFrame,
            sampleRate: context.mix.format.sampleRate
        )
        return try resolvedSourceFramePosition(state: state, renderTime: renderTime)
    }

    /// Returns `value` as `Int` when it is a non-negative integer exactly representable as such.
    static func exactNonNegativeInteger(_ value: Double) -> Int? {
        guard value.isFinite, value >= 0 else {
            return nil
        }
        let rounded = value.rounded(.towardZero)
        guard value == rounded, rounded <= Double(Int.max) else {
            return nil
        }
        return Int(rounded)
    }

    /// Unit-rate integer bulk mix preserving slow-path float multiply order.
    static func mixClipUnitRateIntegerSource(
        request: OfflineUnitRateMixRequest,
        into output: inout [Float],
        duckingMultipliers: [Double]?
    ) -> Bool {
        let source = request.source
        let intersection = request.intersection
        let plan = request.plan
        let outputChannels = request.format.channelCount
        let sourceChannels = source.format.channelCount
        let localOrigin = request.originSourceFrame - source.frameOffset
        let localEnd = localOrigin + intersection.count
        guard localOrigin >= 0, localEnd <= source.frameCount else {
            return false
        }

        if sourceChannels == outputChannels {
            mixMatchingChannelUnitRate(
                request: request,
                into: &output,
                localOrigin: localOrigin,
                duckingMultipliers: duckingMultipliers
            )
            return true
        }

        if sourceChannels == 1 {
            mixMonoSourceUnitRate(
                request: request,
                into: &output,
                localOrigin: localOrigin,
                duckingMultipliers: duckingMultipliers
            )
            return true
        }

        // N→1 / 5.1→stereo / etc.: same float order via mappedSourceSample at integer frames.
        for (offset, outputFrame) in intersection.enumerated() {
            let sourceFrame = Double(request.originSourceFrame + offset)
            let gainF = floatGain(
                baseGain: plan.baseGain,
                ducking: duckingMultipliers,
                frame: outputFrame
            )
            accumulateMappedSourceExactOrder(
                request: request,
                into: &output,
                outputFrame: outputFrame,
                sourceFrame: sourceFrame,
                gainF: gainF
            )
        }
        return true
    }

    static func mixMatchingChannelUnitRate(
        request: OfflineUnitRateMixRequest,
        into output: inout [Float],
        localOrigin: Int,
        duckingMultipliers: [Double]?
    ) {
        let channelCount = request.format.channelCount
        let plan = request.plan
        var outputIndex = request.intersection.lowerBound * channelCount
        var sourceIndex = localOrigin * channelCount
        for outputFrame in request.intersection {
            let gainF = floatGain(
                baseGain: plan.baseGain,
                ducking: duckingMultipliers,
                frame: outputFrame
            )
            for channel in 0..<channelCount {
                let sourceSample = request.source.samples[sourceIndex + channel]
                let panned = sourceSample * plan.panMultipliers[channel]
                output[outputIndex + channel] += panned * gainF
            }
            outputIndex += channelCount
            sourceIndex += channelCount
        }
    }

    static func mixMonoSourceUnitRate(
        request: OfflineUnitRateMixRequest,
        into output: inout [Float],
        localOrigin: Int,
        duckingMultipliers: [Double]?
    ) {
        let outputChannels = request.format.channelCount
        let plan = request.plan
        var outputIndex = request.intersection.lowerBound * outputChannels
        var sourceIndex = localOrigin
        for outputFrame in request.intersection {
            let gainF = floatGain(
                baseGain: plan.baseGain,
                ducking: duckingMultipliers,
                frame: outputFrame
            )
            let sample = request.source.samples[sourceIndex]
            for channel in 0..<outputChannels {
                let panned = sample * plan.panMultipliers[channel]
                output[outputIndex + channel] += panned * gainF
            }
            outputIndex += outputChannels
            sourceIndex += 1
        }
    }

    /// `Float(g_d * duck_d)` — double-domain fold then one conversion, matching the slow path.
    static func floatGain(baseGain: Double, ducking: [Double]?, frame: Int) -> Float {
        let duck = ducking?[frame] ?? 1
        return Float(baseGain * duck)
    }

    static func accumulateMappedSourceExactOrder(
        request: OfflineUnitRateMixRequest,
        into output: inout [Float],
        outputFrame: Int,
        sourceFrame: Double,
        gainF: Float
    ) {
        let format = request.format
        let panMultipliers = request.plan.panMultipliers
        for outputChannel in 0..<format.channelCount {
            let sourceSample = mappedSourceSample(
                source: request.source,
                framePosition: sourceFrame,
                outputChannel: outputChannel,
                outputChannelCount: format.channelCount
            )
            let panned = sourceSample * panMultipliers[outputChannel]
            let outputIndex = (outputFrame * format.channelCount) + outputChannel
            output[outputIndex] += panned * gainF
        }
    }
}
