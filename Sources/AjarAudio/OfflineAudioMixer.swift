// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Deterministic offline audio mixer for golden tests and `ajar render-audio`.
public enum OfflineAudioMixer {
    /// Renders the first-stage master mix for a project sequence.
    public static func render(
        project: Project,
        sequence: Sequence,
        range: TimeRange,
        sourceProvider: any AudioSourceProvider,
        channelCount: Int = 2
    ) throws -> RenderedAudioBuffer {
        try render(
            sequence: sequence,
            range: range,
            format: AudioRenderFormat(
                sampleRate: project.settings.audioSampleRate,
                channelCount: channelCount
            ),
            sourceProvider: sourceProvider
        )
    }

    /// Renders the first-stage master mix for a sequence.
    ///
    /// The master bus is a 32-bit floating-point mix bus. FR-AUD-003 renders preserve
    /// above-unity headroom instead of clipping or limiting to +/-1.0; integer export paths must
    /// add their own limiter, true-peak warning, or attenuation policy before quantization.
    public static func render(
        sequence: Sequence,
        range: TimeRange,
        format: AudioRenderFormat,
        sourceProvider: any AudioSourceProvider
    ) throws -> RenderedAudioBuffer {
        try AudioBufferValidator.validate(format: format, frameCount: 0, samples: [])
        try validateCrossfades(in: sequence)

        let frameCount = try sampleIndex(
            for: range.duration,
            sampleRate: format.sampleRate,
            rounding: .nearestOrAwayFromZero
        )
        let outputSampleCount = try sampleCount(
            frameCount: frameCount,
            channelCount: format.channelCount
        )
        let context = OfflineMixContext(frameCount: frameCount, range: range, format: format)
        var output = Array(repeating: Float(0), count: outputSampleCount)
        var sourceCache: [UUID: AudioSourceBuffer] = [:]
        let audioTracks = selectedAudioTracks(sequence.audioTracks)
        let duckingMultipliers = try duckingMultipliersByTrackID(
            rules: sequence.audioDucking,
            tracks: audioTracks,
            context: context,
            sourceProvider: sourceProvider,
            sourceCache: &sourceCache
        )

        for track in audioTracks {
            try mixTrack(
                track,
                into: &output,
                context: OfflineTrackMixContext(
                    mix: context,
                    duckingMultipliers: duckingMultipliers[track.id]
                ),
                sourceProvider: sourceProvider,
                sourceCache: &sourceCache
            )
        }

        return try RenderedAudioBuffer(format: format, frameCount: frameCount, samples: output)
    }
}

struct OfflineMixContext {
    let frameCount: Int
    let range: TimeRange
    let format: AudioRenderFormat
}

struct OfflineTrackMixContext {
    let mix: OfflineMixContext
    let duckingMultipliers: [Double]?
}

struct OfflineMixFrameContext {
    let renderTime: RationalTime
    let outputFrame: Int
    let format: AudioRenderFormat
    let duckingMultiplier: Double
}

extension OfflineAudioMixer {
    static func selectedAudioTracks(_ tracks: [Track]) -> [Track] {
        let enabledTracks = tracks.filter { track in
            track.kind == .audio && track.enabled && !track.muted
        }
        let soloTracks = enabledTracks.filter(\.solo)
        return soloTracks.isEmpty ? enabledTracks : soloTracks
    }
}

extension OfflineAudioMixer {
    static func mixTrack(
        _ track: Track,
        into output: inout [Float],
        context: OfflineTrackMixContext,
        sourceProvider: any AudioSourceProvider,
        sourceCache: inout [UUID: AudioSourceBuffer]
    ) throws {
        for item in track.items {
            guard case .clip(let clip) = item, clip.kind == .audio else {
                continue
            }
            let source = try sourceBuffer(
                for: clip,
                sourceProvider: sourceProvider,
                sourceCache: &sourceCache
            )
            try mixClip(
                clip,
                track: track,
                source: source,
                into: &output,
                context: context
            )
        }
    }

    static func sourceBuffer(
        for clip: Clip,
        sourceProvider: any AudioSourceProvider,
        sourceCache: inout [UUID: AudioSourceBuffer]
    ) throws -> AudioSourceBuffer {
        guard case .media(let mediaID) = clip.source else {
            throw AudioRenderError.unsupportedClipSource(clipID: clip.id)
        }
        if let cached = sourceCache[mediaID] {
            return cached
        }
        let source = try sourceProvider.audioSource(for: mediaID)
        sourceCache[mediaID] = source
        return source
    }

    static func mixClip(
        _ clip: Clip,
        track: Track,
        source: AudioSourceBuffer,
        into output: inout [Float],
        context: OfflineTrackMixContext
    ) throws {
        let intersection = try intersectionFrames(
            clip: clip,
            range: context.mix.range,
            frameCount: context.mix.frameCount,
            sampleRate: context.mix.format.sampleRate
        )
        guard intersection.lowerBound < intersection.upperBound else {
            return
        }

        for outputFrame in intersection {
            let renderTime = try renderTime(
                rangeStart: context.mix.range.start,
                outputFrame: outputFrame,
                sampleRate: context.mix.format.sampleRate
            )
            try mixClipFrame(
                clip,
                track: track,
                source: source,
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
        _ clip: Clip,
        track: Track,
        source: AudioSourceBuffer,
        frame: OfflineMixFrameContext,
        output: inout [Float]
    ) throws {
        let renderTime = frame.renderTime
        let format = frame.format
        let localTime = try subtract(renderTime, clip.timelineRange.start)
        let sourceTime = try add(clip.sourceRange.start, localTime)
        let sourceFrame = sourceTime.seconds * Double(source.format.sampleRate)
        let gain = gainMultiplier(
            clip: clip,
            track: track,
            renderTime: renderTime,
            localTime: localTime
        ) * frame.duckingMultiplier
        let pan = panValue(clip: clip, track: track, renderTime: renderTime)

        for outputChannel in 0..<format.channelCount {
            let sourceSample = mappedSourceSample(
                source: source,
                framePosition: sourceFrame,
                outputChannel: outputChannel,
                outputChannelCount: format.channelCount
            )
            let panned = sourceSample * Float(
                panMultiplier(pan: pan, channel: outputChannel, format: format)
            )
            let outputIndex = (frame.outputFrame * format.channelCount) + outputChannel
            output[outputIndex] += panned * Float(gain)
        }
    }
}

extension OfflineAudioMixer {
    static func intersectionFrames(
        clip: Clip,
        range: TimeRange,
        frameCount: Int,
        sampleRate: Int
    ) throws -> Range<Int> {
        let clipEnd = try end(of: clip.timelineRange)
        let rangeEnd = try end(of: range)
        let intersectionStart = max(clip.timelineRange.start, range.start)
        let intersectionEnd = min(clipEnd, rangeEnd)
        guard intersectionStart < intersectionEnd else {
            return 0..<0
        }

        let relativeStart = try subtract(intersectionStart, range.start)
        let relativeEnd = try subtract(intersectionEnd, range.start)
        let start = try sampleIndex(for: relativeStart, sampleRate: sampleRate, rounding: .up)
        let end = try sampleIndex(for: relativeEnd, sampleRate: sampleRate, rounding: .up)
        return max(0, start)..<min(frameCount, end)
    }

    static func renderTime(
        rangeStart: RationalTime,
        outputFrame: Int,
        sampleRate: Int
    ) throws -> RationalTime {
        let sampleOffset = try RationalTime(value: Int64(outputFrame), timescale: Int64(sampleRate))
        return try add(rangeStart, sampleOffset)
    }

    static func sampleIndex(
        for time: RationalTime,
        sampleRate: Int,
        rounding: FrameRoundingRule
    ) throws -> Int {
        let rate = try FrameRate(frames: Int64(sampleRate))
        let value = try time.frameIndex(at: rate, rounding: rounding)
        guard value >= 0, value <= Int64(Int.max) else {
            throw AudioRenderError.timeArithmetic("sample index \(value) is out of range")
        }
        return Int(value)
    }

    static func sampleCount(frameCount: Int, channelCount: Int) throws -> Int {
        guard frameCount <= Int.max / channelCount else {
            throw AudioRenderError.sampleCountOverflow(
                frameCount: frameCount,
                channelCount: channelCount
            )
        }
        return frameCount * channelCount
    }
}

extension OfflineAudioMixer {
    static func gainMultiplier(
        clip: Clip,
        track: Track,
        renderTime: RationalTime,
        localTime: RationalTime
    ) -> Double {
        let clipGain = clampedGain(clip.audioMix.value(at: renderTime).gain)
        let trackGain = clampedGain(track.audioGain.value(at: renderTime))
        let fade = clamped01(
            clip.audioMix.fadeEnvelope(
                at: localTime,
                clipDuration: clip.timelineRange.duration
            ).doubleValue
        )
        return clipGain * trackGain * fade
    }

    static func panValue(clip: Clip, track: Track, renderTime: RationalTime) -> Double {
        let clipPan = clampedPan(clip.audioMix.value(at: renderTime).pan)
        let trackPan = clampedPan(track.audioPan.value(at: renderTime))
        return clamped(clipPan + trackPan, minimum: -1, maximum: 1)
    }

    static func clampedGain(_ value: RationalValue) -> Double {
        clamped(
            value.doubleValue,
            minimum: AudioMixLimits.minimumGain.doubleValue,
            maximum: AudioMixLimits.maximumGain.doubleValue
        )
    }

    static func clampedPan(_ value: RationalValue) -> Double {
        clamped(
            value.doubleValue,
            minimum: AudioMixLimits.minimumPan.doubleValue,
            maximum: AudioMixLimits.maximumPan.doubleValue
        )
    }

    static func clamped01(_ value: Double) -> Double {
        clamped(value, minimum: 0, maximum: 1)
    }

    static func clamped(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }

}

extension OfflineAudioMixer {
    static func mappedSourceSample(
        source: AudioSourceBuffer,
        framePosition: Double,
        outputChannel: Int,
        outputChannelCount: Int
    ) -> Float {
        if source.format.channelCount == outputChannelCount {
            return sourceSample(source, framePosition: framePosition, channel: outputChannel)
        }
        if source.format.channelCount == 1 {
            return sourceSample(source, framePosition: framePosition, channel: 0)
        }
        if outputChannelCount == 1 {
            return averagedSourceSample(source, framePosition: framePosition)
        }
        if outputChannelCount == 2, source.format.channelCount == 6 {
            return downmixedStereoSample(
                source,
                framePosition: framePosition,
                outputChannel: outputChannel
            )
        }
        // Non-5.1 multichannel layouts need layout metadata before a correct downmix.
        // Until then, preserve the previous deterministic first-channel mapping.
        let channel = min(outputChannel, source.format.channelCount - 1)
        return sourceSample(source, framePosition: framePosition, channel: channel)
    }

    static func averagedSourceSample(
        _ source: AudioSourceBuffer,
        framePosition: Double
    ) -> Float {
        var sum = Float(0)
        for channel in 0..<source.format.channelCount {
            sum += sourceSample(source, framePosition: framePosition, channel: channel)
        }
        return sum / Float(source.format.channelCount)
    }

    static func sourceSample(
        _ source: AudioSourceBuffer,
        framePosition: Double,
        channel: Int
    ) -> Float {
        guard framePosition.isFinite, framePosition >= 0, source.frameCount > 0 else {
            return 0
        }
        let localFramePosition = framePosition - Double(source.frameOffset)
        guard localFramePosition.isFinite, localFramePosition >= 0 else {
            return 0
        }

        let lowerFrame = Int(localFramePosition.rounded(.down))
        guard lowerFrame < source.frameCount else {
            return 0
        }
        let upperFrame = min(lowerFrame + 1, source.frameCount - 1)
        let fraction = Float(localFramePosition - Double(lowerFrame))
        let lower = source.samples[(lowerFrame * source.format.channelCount) + channel]
        let upper = source.samples[(upperFrame * source.format.channelCount) + channel]
        return lower + ((upper - lower) * fraction)
    }

    static func panMultiplier(pan: Double, channel: Int, format: AudioRenderFormat) -> Double {
        // FR-AUD-003 uses a linear-balance pan law: center is unity on both L/R channels.
        // This is intentionally not equal-power; tests and golden audio fixtures depend on it.
        guard format.channelCount >= 2 else {
            return 1
        }
        if channel == 0 {
            return pan > 0 ? 1 - pan : 1
        }
        if channel == 1 {
            return pan < 0 ? 1 + pan : 1
        }
        return 1
    }

    static func downmixedStereoSample(
        _ source: AudioSourceBuffer,
        framePosition: Double,
        outputChannel: Int
    ) -> Float {
        if outputChannel == 0 {
            return weightedSourceSample(source, framePosition: framePosition, terms: [
                (channel: 0, gain: 1),
                (channel: 2, gain: centerDownmixGain),
                (channel: 4, gain: surroundDownmixGain)
            ])
        }
        return weightedSourceSample(source, framePosition: framePosition, terms: [
            (channel: 1, gain: 1),
            (channel: 2, gain: centerDownmixGain),
            (channel: 5, gain: surroundDownmixGain)
        ])
    }

    static func weightedSourceSample(
        _ source: AudioSourceBuffer,
        framePosition: Double,
        terms: [(channel: Int, gain: Float)]
    ) -> Float {
        var sum = Float(0)
        for term in terms where term.channel < source.format.channelCount {
            sum += sourceSample(source, framePosition: framePosition, channel: term.channel)
                * term.gain
        }
        return sum
    }

    static var centerDownmixGain: Float {
        0.70710678
    }

    static var surroundDownmixGain: Float {
        0.70710678
    }
}

extension OfflineAudioMixer {
    static func add(_ left: RationalTime, _ right: RationalTime) throws -> RationalTime {
        do {
            return try left.adding(right)
        } catch {
            throw AudioRenderError.timeArithmetic(String(describing: error))
        }
    }

    static func subtract(_ left: RationalTime, _ right: RationalTime) throws -> RationalTime {
        do {
            return try left.subtracting(right)
        } catch {
            throw AudioRenderError.timeArithmetic(String(describing: error))
        }
    }

    static func end(of range: TimeRange) throws -> RationalTime {
        do {
            return try range.end()
        } catch {
            throw AudioRenderError.timeArithmetic(String(describing: error))
        }
    }
}
