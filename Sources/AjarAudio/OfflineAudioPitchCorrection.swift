// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

extension OfflineAudioMixer {
    /// Per-clip mix state honoring the clip's FR-SPD-001 audio retime mode.
    ///
    /// `pitchShifted` clips keep the varispeed mapping (`clipMixState`). `pitchCorrected`
    /// clips replace the source with a deterministically stretched timeline-domain buffer:
    /// the clip's ADR-0015 §3 effective source window (source range plus the trailing
    /// crossfade tail image) is extracted, EOF-clamped, reversed when the clip is reversed,
    /// and stretched by the clip's constant speed with `WSOLATimeStretcher`. The stretched
    /// stream is continuous across the clip-end boundary, so the crossfade tail is exact in
    /// the stretched domain. Both the mix pass and the ducking trigger detector build state
    /// through this one function, so detection can never hear audio the mix does not play.
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
        return OfflineClipMixState(
            clip: clip,
            track: track,
            source: try pitchCorrectedSourceBuffer(
                clip: clip,
                source: source,
                environment: &environment
            ),
            declaredTailSourceEndFrame: nil,
            readsStretchedTimelineDomain: true
        )
    }

    /// The stretched timeline-domain buffer for a pitch-corrected clip, cached per clip ID
    /// for the lifetime of one render environment.
    static func pitchCorrectedSourceBuffer(
        clip: Clip,
        source: AudioSourceBuffer,
        environment: inout OfflineAudioRenderEnvironment
    ) throws -> AudioSourceBuffer {
        if let cached = environment.pitchCorrectedSourceCache[clip.id] {
            return cached
        }

        let extracted = try extractedEffectiveWindowSamples(
            clip: clip,
            source: source,
            environment: environment
        )
        let stretched: [Float]
        do {
            stretched = try WSOLATimeStretcher.stretch(
                samples: extracted,
                channelCount: source.format.channelCount,
                sampleRate: source.format.sampleRate,
                speed: clip.speed
            )
        } catch let error as WSOLATimeStretchError {
            throw AudioRenderError.pitchCorrectedStretchFailed(clipID: clip.id, error: error)
        }
        let buffer = try AudioSourceBuffer(
            format: source.format,
            frameCount: stretched.count / source.format.channelCount,
            samples: stretched,
            frameOffset: 0
        )
        environment.pitchCorrectedSourceCache[clip.id] = buffer
        return buffer
    }

    /// Interleaved samples of the clip's ADR-0015 §3 effective source window, in playback
    /// order (reversed for `reverse` clips), with deterministic boundary policy: frames the
    /// provider did not deliver read as exact zeros, and forward crossfade-tail frames at or
    /// past the declared media end are exact zeros (ADR-0015 §7 EOF silence padding).
    static func extractedEffectiveWindowSamples(
        clip: Clip,
        source: AudioSourceBuffer,
        environment: OfflineAudioRenderEnvironment
    ) throws -> [Float] {
        let window = try effectiveSourceWindow(for: clip)
        let sampleRate = source.format.sampleRate
        let startFrame = try sampleIndex(
            for: window.start,
            sampleRate: sampleRate,
            rounding: .nearestOrAwayFromZero
        )
        let endFrame = try sampleIndex(
            for: end(of: window),
            sampleRate: sampleRate,
            rounding: .nearestOrAwayFromZero
        )
        let frameCount = max(0, endFrame - startFrame)
        let channelCount = source.format.channelCount
        let declaredEndFrame = declaredTailSourceEndFrame(
            clip: clip,
            source: source,
            environment: environment
        )

        var extracted = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let sourceFrame = startFrame + frame
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
