// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Cache key for an FR-SPD-001 stretched timeline-domain buffer.
///
/// Keyed by the actual stretch inputs, not the clip ID alone: duplicate clip IDs are legal in
/// this codebase (decomposing two compound clips that share one nested sequence emits the same
/// inner clip IDs twice), so two same-ID clips with different windows or speeds must never
/// cross-serve stretched audio within one render. The clip ID stays in the key only as a
/// conservative extra discriminator; every field that shapes extraction or stretching is here.
struct PitchCorrectedSourceKey: Hashable {
    let clipID: UUID
    let sourceID: UUID
    let sourceIsSequence: Bool
    let window: TimeRange
    let speed: RationalValue
    let reverse: Bool
    let format: AudioRenderFormat
    let declaredTailSourceEndFrame: Double?
}

/// A stretched timeline-domain buffer together with its read mapping.
struct PitchCorrectedStretch {
    let buffer: AudioSourceBuffer
    let read: OfflineStretchedReadState
}

/// Whole-frame extraction bounds for an effective source window: floor of the window start,
/// ceiling of the window end, so the extraction covers the final partial frame (the mixer
/// renders half-open ranges with ceiling semantics) and a fractional start keeps its
/// sub-frame remainder.
struct PitchCorrectedFrameBounds {
    let startFrame: Int
    let endFrame: Int

    var frameCount: Int {
        max(0, endFrame - startFrame)
    }
}

extension OfflineAudioMixer {
    /// Per-clip mix state honoring the clip's FR-SPD-001 audio retime mode.
    ///
    /// `pitchShifted` clips keep the varispeed mapping (`clipMixState`). `pitchCorrected`
    /// clips replace the source with a deterministically stretched timeline-domain buffer:
    /// the clip's ADR-0015 §3 effective source window (source range plus the trailing
    /// crossfade tail image) is extracted with floor/ceiling frame bounds, EOF-clamped,
    /// reversed when the clip is reversed, and stretched by the clip's constant speed with
    /// `WSOLATimeStretcher`. The stretched stream is continuous across the clip-end boundary,
    /// so the crossfade tail is exact in the stretched domain. Both the mix pass and the
    /// ducking trigger detector build state through this one function, so detection can never
    /// hear audio the mix does not play.
    static func retimedClipMixState(
        clip: Clip,
        track: Track,
        source: AudioSourceBuffer,
        environment: inout OfflineAudioRenderEnvironment
    ) throws -> OfflineClipMixState {
        guard clip.audioMix.retimeMode == .pitchCorrected else {
            return clipMixState(
                clip: clip,
                track: track,
                source: source,
                environment: environment
            )
        }
        // Composition policy (FR-SPD-001): freeze frames hold one instant and time-remap
        // curves are variable-rate; both are typed rejections, mirroring central validation.
        guard !clip.freezeFrame, clip.timeRemap == nil else {
            throw AudioRenderError.pitchCorrectedRetimeUnsupported(clipID: clip.id)
        }
        let stretch = try pitchCorrectedStretch(
            clip: clip,
            source: source,
            environment: &environment
        )
        return OfflineClipMixState(
            clip: clip,
            track: track,
            source: stretch.buffer,
            declaredTailSourceEndFrame: nil,
            stretchedRead: stretch.read
        )
    }

    /// The stretched timeline-domain buffer and read mapping for a pitch-corrected clip,
    /// cached by the full stretch-input identity for the lifetime of one render environment.
    static func pitchCorrectedStretch(
        clip: Clip,
        source: AudioSourceBuffer,
        environment: inout OfflineAudioRenderEnvironment
    ) throws -> PitchCorrectedStretch {
        let window = try effectiveSourceWindow(for: clip)
        let declaredEndFrame = declaredTailSourceEndFrame(
            clip: clip,
            source: source,
            environment: environment
        )
        let key = pitchCorrectedSourceKey(
            clip: clip,
            window: window,
            format: source.format,
            declaredTailSourceEndFrame: declaredEndFrame
        )
        if let cached = environment.pitchCorrectedSourceCache[key] {
            return cached
        }

        let stretch = try makePitchCorrectedStretch(
            clip: clip,
            source: source,
            window: window,
            declaredEndFrame: declaredEndFrame,
            cancellationCheck: environment.cancellationCheck
        )
        environment.pitchCorrectedSourceCache[key] = stretch
        return stretch
    }

    static func pitchCorrectedSourceKey(
        clip: Clip,
        window: TimeRange,
        format: AudioRenderFormat,
        declaredTailSourceEndFrame: Double?
    ) -> PitchCorrectedSourceKey {
        let sourceID: UUID
        let sourceIsSequence: Bool
        switch clip.source {
        case .media(let mediaID):
            sourceID = mediaID
            sourceIsSequence = false
        case .sequence(let sequenceID):
            sourceID = sequenceID
            sourceIsSequence = true
        case .title:
            // Title generators have no audio source; key still needs a stable UUID.
            sourceID = clip.id
            sourceIsSequence = false
        }
        return PitchCorrectedSourceKey(
            clipID: clip.id,
            sourceID: sourceID,
            sourceIsSequence: sourceIsSequence,
            window: window,
            speed: clip.speed,
            reverse: clip.reverse,
            format: format,
            declaredTailSourceEndFrame: declaredTailSourceEndFrame
        )
    }

    static func makePitchCorrectedStretch(
        clip: Clip,
        source: AudioSourceBuffer,
        window: TimeRange,
        declaredEndFrame: Double?,
        cancellationCheck: @escaping AudioRenderCancellationCheck
    ) throws -> PitchCorrectedStretch {
        let bounds = try extractionFrameBounds(window: window, source: source)
        // Refuse before allocating the extracted window. The production decoder has its own
        // source-buffer cap, but WSOLA simultaneously retains several larger analysis/output
        // arrays; this actual-format check is the authoritative bound for that temporary peak.
        do {
            try WSOLATimeStretcher.validateWorkingSet(
                inputFrameCount: bounds.frameCount,
                channelCount: source.format.channelCount,
                sampleRate: source.format.sampleRate,
                speed: clip.speed
            )
        } catch let error as WSOLATimeStretchError {
            throw AudioRenderError.pitchCorrectedStretchFailed(clipID: clip.id, error: error)
        }
        let extracted = try extractedWindowSamples(
            clip: clip,
            source: source,
            bounds: bounds,
            declaredEndFrame: declaredEndFrame,
            cancellationCheck: cancellationCheck
        )
        let stretched: [Float]
        do {
            stretched = try WSOLATimeStretcher.stretch(
                samples: extracted,
                channelCount: source.format.channelCount,
                sampleRate: source.format.sampleRate,
                speed: clip.speed,
                cancellationCheck: cancellationCheck
            )
        } catch let error as WSOLATimeStretchError {
            throw AudioRenderError.pitchCorrectedStretchFailed(clipID: clip.id, error: error)
        }
        return PitchCorrectedStretch(
            buffer: try AudioSourceBuffer(
                format: source.format,
                frameCount: stretched.count / source.format.channelCount,
                samples: stretched,
                frameOffset: 0
            ),
            read: OfflineStretchedReadState(
                startFrame: bounds.startFrame,
                anchor: try stretchedReadAnchor(
                    clip: clip,
                    window: window,
                    bounds: bounds,
                    sampleRate: source.format.sampleRate
                )
            )
        )
    }
}

extension OfflineAudioMixer {
    static func extractionFrameBounds(
        window: TimeRange,
        source: AudioSourceBuffer
    ) throws -> PitchCorrectedFrameBounds {
        try extractionFrameBounds(window: window, sampleRate: source.format.sampleRate)
    }

    static func extractionFrameBounds(
        window: TimeRange,
        sampleRate: Int
    ) throws -> PitchCorrectedFrameBounds {
        return PitchCorrectedFrameBounds(
            startFrame: try sampleIndex(
                for: window.start,
                sampleRate: sampleRate,
                rounding: .down
            ),
            endFrame: try sampleIndex(
                for: end(of: window),
                sampleRate: sampleRate,
                rounding: .up
            )
        )
    }

    /// Exact rational anchor aligning the stretched-domain read with the varispeed frame
    /// mapping (see `OfflineStretchedReadState.anchor`). Frame-aligned windows yield exactly
    /// zero, preserving the previous 1:1 timeline read.
    static func stretchedReadAnchor(
        clip: Clip,
        window: TimeRange,
        bounds: PitchCorrectedFrameBounds,
        sampleRate: Int
    ) throws -> RationalTime {
        do {
            if clip.reverse {
                // Reverse varispeed anchors playback at `round(windowEnd·rate) − 1`; the
                // ceiling extraction end may sit up to one frame later, so reads shift right
                // by the difference, scaled into the stretched domain by `1/speed`.
                let varispeedEndFrame = try sampleIndex(
                    for: end(of: window),
                    sampleRate: sampleRate,
                    rounding: .nearestOrAwayFromZero
                )
                return try RationalTime(
                    value: Int64(bounds.endFrame - varispeedEndFrame),
                    timescale: Int64(sampleRate)
                )
                .multiplied(by: clip.speed.denominator)
                .divided(by: clip.speed.numerator)
            }
            // Forward: the fractional part of the window start (`windowStart − floor`),
            // scaled into the stretched domain by `1/speed`.
            let startFrameTime = try RationalTime(
                value: Int64(bounds.startFrame),
                timescale: Int64(sampleRate)
            )
            return try window.start.subtracting(startFrameTime)
                .multiplied(by: clip.speed.denominator)
                .divided(by: clip.speed.numerator)
        } catch let error as AudioRenderError {
            throw error
        } catch {
            throw AudioRenderError.timeArithmetic(String(describing: error))
        }
    }

    /// Interleaved samples of the effective source window frames `[startFrame, endFrame)`,
    /// in playback order (reversed for `reverse` clips), with deterministic boundary policy:
    /// frames the provider did not deliver read as exact zeros, and forward crossfade-tail
    /// frames at or past the declared media end are exact zeros (ADR-0015 §7 EOF padding).
    static func extractedWindowSamples(
        clip: Clip,
        source: AudioSourceBuffer,
        bounds: PitchCorrectedFrameBounds,
        declaredEndFrame: Double?,
        cancellationCheck: AudioRenderCancellationCheck
    ) throws -> [Float] {
        let frameCount = bounds.frameCount
        let channelCount = source.format.channelCount
        var extracted = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            if frame & 1_023 == 0 {
                try cancellationCheck()
            }
            let sourceFrame = bounds.startFrame + frame
            if let declaredEndFrame, Double(sourceFrame) >= declaredEndFrame {
                continue
            }
            let localFrame = sourceFrame - source.frameOffset
            guard localFrame >= 0, localFrame < source.frameCount else {
                continue
            }
            let outputFrame = clip.reverse ? frameCount - 1 - frame : frame
            for channel in 0..<channelCount {
                extracted[(outputFrame * channelCount) + channel] =
                    source.samples[(localFrame * channelCount) + channel]
            }
        }
        return extracted
    }
}
