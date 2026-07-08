// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Read mapping for an FR-SPD-001 stretched timeline-domain buffer.
struct OfflineStretchedReadState {
    /// First extracted source frame: the floor of the effective window start, so a fractional
    /// window start keeps its sub-frame remainder inside the extracted buffer.
    let startFrame: Int

    /// Exact rational read anchor added to the clip-local timeline offset before frame
    /// conversion. Forward clips carry the fractional window start scaled into the stretched
    /// domain (`(windowStart − startFrame/rate) / speed`); reverse clips carry the offset
    /// between the ceiling extraction end and the varispeed frame anchor
    /// (`(endFrame − round(windowEnd·rate)) / (speed·rate)`). Frame-aligned clips keep an
    /// anchor of exactly zero and match the varispeed frame mapping one to one.
    let anchor: RationalTime
}

/// Per-clip mixing state resolved once before the frame loop.
struct OfflineClipMixState {
    let clip: Clip
    let track: Track
    let source: AudioSourceBuffer

    /// Declared media end in source frames for ADR-0015 §7 tail EOF clamping, or `nil` when
    /// the clip has no trailing crossfade, is not media-backed, or no project is available.
    let declaredTailSourceEndFrame: Double?

    /// FR-SPD-001 pitch-corrected clips read a pre-stretched buffer in the timeline domain:
    /// positions advance 1:1 with timeline time from the read state's anchor. Reverse,
    /// crossfade-tail, and EOF handling were baked in at stretch time. `nil` for varispeed.
    let stretchedRead: OfflineStretchedReadState?
}

extension OfflineAudioMixer {
    /// End of a clip's mix window: its timeline out-point extended by the trailing crossfade
    /// duration, so the outgoing source stays audible across the ADR-0015 §1 region (FR-AUD-002).
    static func mixWindowEnd(of clip: Clip) throws -> RationalTime {
        let clipEnd = try end(of: clip.timelineRange)
        guard let trailing = clip.audioMix.trailingCrossfade, trailing.duration > .zero else {
            return clipEnd
        }
        return try add(clipEnd, trailing.duration)
    }

    /// ADR-0015 §3 effective audio read window: `sourceRange` extended by the source-time image
    /// of the trailing crossfade tail under the clip's constant-rate mapping. Forward clips
    /// extend past `sourceRange.end`, `reverse` clips extend before `sourceRange.start`
    /// (clamped at media time zero), and `freezeFrame` clips hold their frame, so the window
    /// is unchanged. This window — not `sourceRange` — is the unit of audio source acquisition
    /// and the value every audio cache key must hash.
    static func effectiveSourceWindow(for clip: Clip) throws -> TimeRange {
        guard let trailing = clip.audioMix.trailingCrossfade, trailing.duration > .zero,
            !clip.freezeFrame, clip.timeRemap == nil
        else {
            return clip.sourceRange
        }
        let tail = try tailSourceDuration(for: clip, trailing: trailing)
        let sourceEnd = try end(of: clip.sourceRange)
        if clip.reverse {
            let start: RationalTime
            if clip.sourceRange.start < tail {
                start = .zero
            } else {
                start = try subtract(clip.sourceRange.start, tail)
            }
            return try makeTimeRange(start: start, duration: subtract(sourceEnd, start))
        }
        return try makeTimeRange(
            start: clip.sourceRange.start,
            duration: add(clip.sourceRange.duration, tail)
        )
    }

    /// ADR-0015 §4 gain multiplier for the crossfade region `[T, T + D)`.
    ///
    /// Rendering is owned per clip: past its out-point the outgoing clip's tail applies
    /// `g_out(x) = curve(1 - x)`; inside its first `D` the incoming clip applies
    /// `g_in(x) = curve(x)`. With the two ADR-0015 curves this yields
    /// `cos(πx/2)`/`sin(πx/2)` for `equalPower` and `1 - x`/`x` for `linear`.
    static func crossfadeGainMultiplier(clip: Clip, renderTime: RationalTime) throws -> Double {
        let clipEnd = try end(of: clip.timelineRange)
        if let trailing = clip.audioMix.trailingCrossfade, trailing.duration > .zero,
            renderTime >= clipEnd {
            let elapsed = try subtract(renderTime, clipEnd)
            let fraction = try crossfadeFraction(elapsed: elapsed, duration: trailing.duration)
            return trailing.curve.value(at: 1 - fraction)
        }
        if let leading = clip.audioMix.leadingCrossfade, leading.duration > .zero {
            let localTime = try subtract(renderTime, clip.timelineRange.start)
            if localTime < leading.duration {
                let fraction = try crossfadeFraction(
                    elapsed: localTime,
                    duration: leading.duration
                )
                return leading.curve.value(at: fraction)
            }
        }
        return 1
    }

    /// Tail-aware source frame position for one output frame, or `nil` when the frame is
    /// ADR-0015 §7 EOF silence (the mapped tail passed the declared media end).
    ///
    /// Both the mix path and the ducking trigger detector resolve samples through this single
    /// mapping, so detection can never hear audio the mix does not play — reverse tails read
    /// backward past `sourceRange.start` and EOF-clamped tails stay silent in both.
    static func resolvedSourceFramePosition(
        state: OfflineClipMixState,
        renderTime: RationalTime
    ) throws -> Double? {
        let clip = state.clip
        if let stretchedRead = state.stretchedRead {
            // FR-SPD-001 pitch-corrected: the stretched buffer already lives in the timeline
            // domain, so playback is a 1:1 read at the clip-local timeline offset plus the
            // fractional-start anchor. Tail EOF and reverse mapping were resolved when the
            // buffer was stretched.
            let sampleRate = Double(state.source.format.sampleRate)
            if clip.speed == .one, !clip.reverse {
                // Bit-identity with varispeed at unit speed: compute the identical rational
                // source time, convert once, then shift by the integer extraction start —
                // an exact floating-point subtraction — so interpolation positions match
                // the varispeed path bit for bit, crossfade tail included.
                let sourceTime = try clipSourceTime(clip, at: renderTime)
                return (sourceTime.seconds * sampleRate) - Double(stretchedRead.startFrame)
            }
            let timelineOffset = try subtract(renderTime, clip.timelineRange.start)
            return try add(timelineOffset, stretchedRead.anchor).seconds * sampleRate
        }
        let sourceTime = try clipSourceTime(clip, at: renderTime)
        let isTailFrame = try renderTime >= end(of: clip.timelineRange)
        let framePosition = try sourceFramePosition(
            clip: clip,
            source: state.source,
            sourceTime: sourceTime,
            allowsTailBeforeSourceStart: isTailFrame
        )
        if isTailFrame, let declaredEnd = state.declaredTailSourceEndFrame,
            framePosition >= declaredEnd {
            return nil
        }
        return framePosition
    }

    /// Per-clip mixing state shared by the mix and ducking-detection paths.
    static func clipMixState(
        clip: Clip,
        track: Track,
        source: AudioSourceBuffer,
        environment: OfflineAudioRenderEnvironment
    ) -> OfflineClipMixState {
        OfflineClipMixState(
            clip: clip,
            track: track,
            source: source,
            declaredTailSourceEndFrame: declaredTailSourceEndFrame(
                clip: clip,
                source: source,
                environment: environment
            ),
            stretchedRead: nil
        )
    }

    /// Exact rational position of `elapsed` inside `duration`, clamped to `0...1`.
    static func crossfadeFraction(
        elapsed: RationalTime,
        duration: RationalTime
    ) throws -> Double {
        do {
            let values = try elapsed.valuesAtCommonTimescale(with: duration)
            guard values.right != 0 else {
                return 1
            }
            return max(0, min(1, Double(values.left) / Double(values.right)))
        } catch {
            throw AudioRenderError.timeArithmetic(String(describing: error))
        }
    }
}

extension OfflineAudioMixer {
    /// ADR-0015 §7: when a render is about to mix crossfade tail frames, the provider must have
    /// delivered every tail frame that lies **within the declared media bounds**. A shortfall
    /// past the declared duration is confirmed EOF and silence-pads deterministically (media
    /// drifted after validation); a shortfall inside the declared bounds is a decoder fault and
    /// surfaces as `AudioRenderError.sourceUnderDelivered` — never silent zeros.
    static func validateTailSourceDelivery(
        clip: Clip,
        source: AudioSourceBuffer,
        context: OfflineMixContext,
        environment: OfflineAudioRenderEnvironment
    ) throws {
        guard let trailing = clip.audioMix.trailingCrossfade, trailing.duration > .zero,
            case .media(let mediaID) = clip.source,
            let media = environment.project?.mediaPool.first(where: { $0.id == mediaID })
        else {
            return
        }
        // Only when this render actually mixes tail frames: the render range must intersect
        // the tail region `[clipEnd, clipEnd + D)` — a window wholly before or after the
        // clip's extended mix window plays none of the tail and must not fail for it.
        let clipEnd = try end(of: clip.timelineRange)
        let tailEnd = try mixWindowEnd(of: clip)
        guard try end(of: context.range) > clipEnd, context.range.start < tailEnd else {
            return
        }
        guard let tailWindow = try tailSourceWindow(for: clip, trailing: trailing) else {
            return
        }

        let declaredEnd = media.metadata.duration
        let neededStart = max(tailWindow.start, .zero)
        let neededEnd = min(tailWindow.end, declaredEnd)
        guard neededStart < neededEnd else {
            return
        }

        let sampleRate = source.format.sampleRate
        let neededLowerFrame = try sampleIndex(
            for: neededStart,
            sampleRate: sampleRate,
            rounding: .down
        )
        let neededUpperFrame = try sampleIndex(
            for: neededEnd,
            sampleRate: sampleRate,
            rounding: .up
        )
        let deliveredFrames = source.frameOffset..<(source.frameOffset + source.frameCount)
        if let missingFrames = missingFrames(
            needed: neededLowerFrame..<neededUpperFrame,
            delivered: deliveredFrames
        ) {
            throw AudioRenderError.sourceUnderDelivered(
                clipID: clip.id,
                missingRange: try makeTimeRange(
                    start: RationalTime(
                        value: Int64(missingFrames.lowerBound),
                        timescale: Int64(sampleRate)
                    ),
                    duration: RationalTime(
                        value: Int64(missingFrames.count),
                        timescale: Int64(sampleRate)
                    )
                )
            )
        }
    }

    /// Source-time window read only by the trailing crossfade tail, before clamping to the
    /// declared media bounds. `nil` when the mapping needs no tail media (`freezeFrame`).
    static func tailSourceWindow(
        for clip: Clip,
        trailing: ClipAudioCrossfade
    ) throws -> (start: RationalTime, end: RationalTime)? {
        guard !clip.freezeFrame, clip.timeRemap == nil else {
            return nil
        }
        let tail = try tailSourceDuration(for: clip, trailing: trailing)
        if clip.reverse {
            let windowEnd = clip.sourceRange.start
            if windowEnd < tail {
                return (start: .zero, end: windowEnd)
            }
            return (start: try subtract(windowEnd, tail), end: windowEnd)
        }
        let windowStart = try end(of: clip.sourceRange)
        return (start: windowStart, end: try add(windowStart, tail))
    }

    /// Source-time length of the tail under the clip's constant-rate mapping (`D × speed`).
    static func tailSourceDuration(
        for clip: Clip,
        trailing: ClipAudioCrossfade
    ) throws -> RationalTime {
        do {
            return try Clip.sourceDuration(
                forTimelineDuration: trailing.duration,
                speed: clip.speed
            )
        } catch {
            throw AudioRenderError.timeArithmetic(String(describing: error))
        }
    }

    /// Declared media end in source-frame units, used to clamp forward tail reads so EOF
    /// silence-padding never depends on how many extra frames a provider happens to deliver.
    static func declaredTailSourceEndFrame(
        clip: Clip,
        source: AudioSourceBuffer,
        environment: OfflineAudioRenderEnvironment
    ) -> Double? {
        guard clip.audioMix.trailingCrossfade != nil,
            case .media(let mediaID) = clip.source,
            let media = environment.project?.mediaPool.first(where: { $0.id == mediaID })
        else {
            return nil
        }
        return media.metadata.duration.seconds * Double(source.format.sampleRate)
    }

    private static func missingFrames(
        needed: Range<Int>,
        delivered: Range<Int>
    ) -> Range<Int>? {
        if needed.lowerBound < delivered.lowerBound {
            return needed.lowerBound..<min(needed.upperBound, delivered.lowerBound)
        }
        if needed.upperBound > delivered.upperBound {
            return max(needed.lowerBound, delivered.upperBound)..<needed.upperBound
        }
        return nil
    }

    static func makeTimeRange(
        start: RationalTime,
        duration: RationalTime
    ) throws -> TimeRange {
        do {
            return try TimeRange(start: start, duration: duration)
        } catch {
            throw AudioRenderError.timeArithmetic(String(describing: error))
        }
    }
}
