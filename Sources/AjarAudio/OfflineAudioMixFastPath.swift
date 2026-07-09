// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Precomputed constant clip/track gain×pan per output channel (ducking applied later).
struct OfflineConstantEnvelopePlan {
    let channelGains: [Float]
}

/// Linear source-frame mapping validated against the exact rational resolver at the ends of a run.
struct OfflineLinearSourceFrameStepper {
    let originOutputFrame: Int
    let originSourceFrame: Double
    let step: Double

    func sourceFrame(at outputFrame: Int) -> Double {
        originSourceFrame + step * Double(outputFrame - originOutputFrame)
    }
}

/// Shared inputs for the constant-gain bulk mix helpers.
struct OfflineConstantGainMixRequest {
    let source: AudioSourceBuffer
    let intersection: Range<Int>
    let channelGains: [Float]
    let format: AudioRenderFormat
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
        context: OfflineTrackMixContext
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

        // FR-AUD-007 / #178: hoist constant envelopes and step linear source frames in the
        // sample domain (same floats, far fewer RationalTime ops on the plan-build path).
        if try mixClipOptimized(
            state: state,
            into: &output,
            context: context,
            intersection: intersection
        ) {
            return
        }

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

    /// Bit-identical fast mix when gain/pan are constant and source frames advance linearly.
    ///
    /// Returns `true` when handled; callers fall back to the per-sample rational path otherwise.
    static func mixClipOptimized(
        state: OfflineClipMixState,
        into output: inout [Float],
        context: OfflineTrackMixContext,
        intersection: Range<Int>
    ) throws -> Bool {
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
            let stepper = try makeLinearSourceFrameStepper(
                state: state,
                context: context,
                intersection: intersection
            )
        else {
            return false
        }

        let request = OfflineConstantGainMixRequest(
            source: state.source,
            intersection: intersection,
            channelGains: plan.channelGains,
            format: context.mix.format
        )
        if context.duckingMultipliers == nil {
            return mixClipLinearSourceConstantGain(
                request: request,
                into: &output,
                stepper: stepper
            )
        }
        return mixClipLinearSourceWithDucking(
            request: request,
            into: &output,
            stepper: stepper,
            duckingMultipliers: context.duckingMultipliers
        )
    }
}

extension OfflineAudioMixer {
    /// Builds constant per-channel gains when clip/track automation, fades, and crossfades are
    /// all static over the mix window. Returns `nil` when any envelope varies with time.
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
        // Crossfade is absent (guarded above), so the multiplier is exactly 1.
        let gain = gainMultiplier(
            clip: clip,
            track: track,
            renderTime: renderTime,
            localTime: localTime
        )
        let pan = panValue(clip: clip, track: track, renderTime: renderTime)
        var channelGains: [Float] = []
        channelGains.reserveCapacity(format.channelCount)
        for channel in 0..<format.channelCount {
            let channelGain = gain * panMultiplier(pan: pan, channel: channel, format: format)
            channelGains.append(Float(channelGain))
        }
        return OfflineConstantEnvelopePlan(channelGains: channelGains)
    }

    /// Validates linear source-frame advance across `intersection` against the rational resolver.
    ///
    /// Returns `nil` for tail-EOF silence or non-linear mappings (time-remap / freeze / reverse).
    static func makeLinearSourceFrameStepper(
        state: OfflineClipMixState,
        context: OfflineTrackMixContext,
        intersection: Range<Int>
    ) throws -> OfflineLinearSourceFrameStepper? {
        // Declared-media tail EOF can insert mid-run silence (`nil`); keep the exact path.
        guard state.declaredTailSourceEndFrame == nil else {
            return nil
        }

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
        if intersection.count == 1 {
            return OfflineLinearSourceFrameStepper(
                originOutputFrame: startFrame,
                originSourceFrame: originSourceFrame,
                step: 0
            )
        }
        guard
            let secondSourceFrame = try sourceFrameAtOutput(
                state: state,
                context: context,
                outputFrame: startFrame + 1
            )
        else {
            return nil
        }
        let step = secondSourceFrame - originSourceFrame
        guard
            try linearSourceStepMatchesEnd(
                state: state,
                context: context,
                intersection: intersection,
                originSourceFrame: originSourceFrame,
                step: step
            )
        else {
            return nil
        }
        return OfflineLinearSourceFrameStepper(
            originOutputFrame: startFrame,
            originSourceFrame: originSourceFrame,
            step: step
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

    /// Confirms the linear step reproduces the rational resolver at the last sample of the run.
    static func linearSourceStepMatchesEnd(
        state: OfflineClipMixState,
        context: OfflineTrackMixContext,
        intersection: Range<Int>,
        originSourceFrame: Double,
        step: Double
    ) throws -> Bool {
        let startFrame = intersection.lowerBound
        let lastFrame = intersection.upperBound - 1
        guard lastFrame > startFrame + 1 else {
            return true
        }
        guard
            let lastSourceFrame = try sourceFrameAtOutput(
                state: state,
                context: context,
                outputFrame: lastFrame
            )
        else {
            return false
        }
        let expectedLast = originSourceFrame + step * Double(lastFrame - startFrame)
        // Bit-identical output requires the stepped position to match the rational resolver.
        return lastSourceFrame == expectedLast
    }

    /// Mixes a constant-gain linear-source run, using a direct integer sample path when the
    /// source positions are whole frames advancing by 1 (the common unit-speed case).
    static func mixClipLinearSourceConstantGain(
        request: OfflineConstantGainMixRequest,
        into output: inout [Float],
        stepper: OfflineLinearSourceFrameStepper
    ) -> Bool {
        // Unit-rate, sample-aligned: source frame N maps to output sample without interpolation.
        let isUnitRateInteger =
            stepper.step == 1
            && stepper.originSourceFrame == Double(stepper.originSourceFrame.rounded(.towardZero))
            && stepper.originSourceFrame >= 0
        if isUnitRateInteger {
            let originSourceInt = Int(stepper.originSourceFrame)
            if mixClipUnitRateIntegerSource(
                request: request,
                into: &output,
                originSourceFrame: originSourceInt
            ) {
                return true
            }
        }

        for outputFrame in request.intersection {
            let sourceFrame = stepper.sourceFrame(at: outputFrame)
            accumulateMappedSource(
                request: request,
                into: &output,
                outputFrame: outputFrame,
                sourceFrame: sourceFrame,
                gainScale: 1
            )
        }
        return true
    }

    /// Linear source stepping with per-frame ducking multipliers.
    static func mixClipLinearSourceWithDucking(
        request: OfflineConstantGainMixRequest,
        into output: inout [Float],
        stepper: OfflineLinearSourceFrameStepper,
        duckingMultipliers: [Double]?
    ) -> Bool {
        guard let duckingMultipliers else {
            return false
        }
        for outputFrame in request.intersection {
            let sourceFrame = stepper.sourceFrame(at: outputFrame)
            accumulateMappedSource(
                request: request,
                into: &output,
                outputFrame: outputFrame,
                sourceFrame: sourceFrame,
                gainScale: Float(duckingMultipliers[outputFrame])
            )
        }
        return true
    }

    /// Adds one output frame from a mapped source position under a constant channel-gain plan.
    static func accumulateMappedSource(
        request: OfflineConstantGainMixRequest,
        into output: inout [Float],
        outputFrame: Int,
        sourceFrame: Double,
        gainScale: Float
    ) {
        let format = request.format
        for outputChannel in 0..<format.channelCount {
            let sourceSample = mappedSourceSample(
                source: request.source,
                framePosition: sourceFrame,
                outputChannel: outputChannel,
                outputChannelCount: format.channelCount
            )
            let outputIndex = (outputFrame * format.channelCount) + outputChannel
            output[outputIndex] += sourceSample * request.channelGains[outputChannel] * gainScale
        }
    }

    /// Direct integer-index mix for 1:1 sample-aligned unit-rate runs (no interpolation).
    ///
    /// Returns `false` when the run would read outside the delivered source buffer, so the
    /// caller can fall back to the interpolating path (which silence-pads OOB reads).
    static func mixClipUnitRateIntegerSource(
        request: OfflineConstantGainMixRequest,
        into output: inout [Float],
        originSourceFrame: Int
    ) -> Bool {
        let source = request.source
        let intersection = request.intersection
        let channelGains = request.channelGains
        let outputChannels = request.format.channelCount
        let sourceChannels = source.format.channelCount
        let localOrigin = originSourceFrame - source.frameOffset
        let localEnd = localOrigin + intersection.count
        guard localOrigin >= 0, localEnd <= source.frameCount else {
            return false
        }

        // Matching channel layouts: tight per-frame channel loop.
        if sourceChannels == outputChannels {
            var outputIndex = intersection.lowerBound * outputChannels
            var sourceIndex = localOrigin * sourceChannels
            for _ in intersection {
                for channel in 0..<outputChannels {
                    output[outputIndex + channel] +=
                        source.samples[sourceIndex + channel] * channelGains[channel]
                }
                outputIndex += outputChannels
                sourceIndex += sourceChannels
            }
            return true
        }

        // Mono source → N-channel output (duplicate).
        if sourceChannels == 1 {
            var outputIndex = intersection.lowerBound * outputChannels
            var sourceIndex = localOrigin
            for _ in intersection {
                let sample = source.samples[sourceIndex]
                for channel in 0..<outputChannels {
                    output[outputIndex + channel] += sample * channelGains[channel]
                }
                outputIndex += outputChannels
                sourceIndex += 1
            }
            return true
        }

        // Remaining layouts (N→1 average, 5.1→stereo, etc.): use mappedSourceSample with
        // integer frame positions so channel mapping stays identical to the slow path.
        for (offset, outputFrame) in intersection.enumerated() {
            accumulateMappedSource(
                request: request,
                into: &output,
                outputFrame: outputFrame,
                sourceFrame: Double(originSourceFrame + offset),
                gainScale: 1
            )
        }
        return true
    }
}
