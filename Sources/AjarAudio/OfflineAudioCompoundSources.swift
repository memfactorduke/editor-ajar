// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Cache key for rendered nested-sequence audio. `sourceRange` is the clip's ADR-0015 §3
/// **effective read window** — `sourceRange` extended by the trailing crossfade tail — so
/// adding, removing, or resizing a crossfade can never return a stale, tail-less buffer.
struct CompoundAudioSourceKey: Hashable {
    let sequenceID: UUID
    let sourceRange: TimeRange
    let format: AudioRenderFormat
    /// Instance path also keys ducking continuation. Two references to the same nested sequence
    /// can enter the same source window with different envelope histories across export chunks.
    let renderPath: OfflineAudioRenderPath
}

/// One imported-media window requested by a particular clip mapping.
struct MediaAudioSourceKey: Hashable {
    let mediaID: UUID
    let sourceRange: TimeRange
}

struct OfflineAudioRenderEnvironment {
    let project: Project?
    let sourceProvider: any AudioSourceProvider
    let cancellationCheck: AudioRenderCancellationCheck
    var sourceCache: [MediaAudioSourceKey: AudioSourceBuffer]
    var compoundSourceCache: [CompoundAudioSourceKey: AudioSourceBuffer]
    var continuation: OfflineAudioRenderContinuation

    /// FR-SPD-001 stretched timeline-domain buffers keyed by the full stretch-input identity
    /// (`PitchCorrectedSourceKey`), never by clip ID alone — duplicate clip IDs are legal
    /// (compound decompose can emit the same inner clip IDs twice), so same-ID clips with
    /// different windows or speeds get independent stretches while the mix and
    /// ducking-detection passes still share one deterministic stretch per identity per render.
    var pitchCorrectedSourceCache: [PitchCorrectedSourceKey: PitchCorrectedStretch]

    init(
        project: Project?,
        sourceProvider: any AudioSourceProvider,
        continuation: OfflineAudioRenderContinuation,
        cancellationCheck: @escaping AudioRenderCancellationCheck
    ) {
        self.project = project
        self.sourceProvider = sourceProvider
        self.cancellationCheck = cancellationCheck
        self.continuation = continuation
        sourceCache = [:]
        compoundSourceCache = [:]
        pitchCorrectedSourceCache = [:]
    }

    init(project: Project?, sourceProvider: any AudioSourceProvider) {
        self.init(
            project: project,
            sourceProvider: sourceProvider,
            continuation: OfflineAudioRenderContinuation(),
            cancellationCheck: {}
        )
    }
}

extension OfflineAudioMixer {
    /// Tracks that contribute audio to an offline mix (FR-CMP-001, FR-AUD-003).
    ///
    /// Enabled, unmuted audio tracks contribute their audio clips. Enabled, unmuted video
    /// tracks contribute only sequence-backed compound clips whose nested sequence actually
    /// carries audio content: an FR-CMP-001 collapse replaces the selection with one `.video`
    /// compound clip on a video track holding the collapsed audio, so skipping video tracks
    /// would silence it — while a visual-only compound never joins the contributor set, so its
    /// track's solo flag cannot mute real audio tracks. Solo applies across both sets: if any
    /// contributor is soloed, only soloed contributors play.
    static func audioContributorTracks(
        in sequence: Sequence,
        project: Project?,
        nestingDepth: Int
    ) -> [Track] {
        let audioTracks = sequence.audioTracks.filter { track in
            track.kind == .audio && track.enabled && !track.muted
        }
        let compoundVideoTracks = sequence.videoTracks.filter { track in
            videoTrackContributesAudio(track, project: project, nestingDepth: nestingDepth)
        }
        let contributors = audioTracks + compoundVideoTracks
        let soloContributors = contributors.filter(\.solo)
        return soloContributors.isEmpty ? contributors : soloContributors
    }

    /// Whether a clip contributes audio when mixed from `track`.
    ///
    /// Audio tracks mix their audio clips. Video tracks mix only sequence-backed compound
    /// clips; media video clips keep their audio in linked audio clips, so mixing them here
    /// would double-count.
    static func clipCarriesAudio(_ clip: Clip, on track: Track) -> Bool {
        if track.kind == .audio {
            return clip.kind == .audio
        }
        guard case .sequence = clip.source else {
            return false
        }
        return true
    }

    /// Whether an enabled, unmuted video track holds at least one compound clip that resolves
    /// to audio content, making it an audio contributor (FR-CMP-001).
    static func videoTrackContributesAudio(
        _ track: Track,
        project: Project?,
        nestingDepth: Int
    ) -> Bool {
        guard track.kind == .video, track.enabled, !track.muted else {
            return false
        }
        return track.items.contains { item in
            guard case .clip(let clip) = item, case .sequence(let sequenceID) = clip.source
            else {
                return false
            }
            return nestedSequenceCarriesAudio(
                sequenceID,
                project: project,
                nestingDepth: nestingDepth + 1
            )
        }
    }

    /// Whether a referenced nested sequence carries any audio content: an enabled, unmuted
    /// audio track with at least one audio clip, or (recursively, bounded by the defensive
    /// compound nesting limit) a video track carrying an audible compound clip.
    static func nestedSequenceCarriesAudio(
        _ sequenceID: UUID,
        project: Project?,
        nestingDepth: Int
    ) -> Bool {
        guard nestingDepth < RenderGraphBuilder.maximumCompoundNestingDepth,
            let project,
            let sequence = project.sequences.first(where: { $0.id == sequenceID })
        else {
            return false
        }

        let audioTrackCarriesAudio = sequence.audioTracks.contains { track in
            guard track.kind == .audio, track.enabled, !track.muted else {
                return false
            }
            return track.items.contains { item in
                guard case .clip(let clip) = item, clip.kind == .audio else {
                    return false
                }
                guard case .sequence(let nestedID) = clip.source else {
                    return true
                }
                return nestedSequenceCarriesAudio(
                    nestedID,
                    project: project,
                    nestingDepth: nestingDepth + 1
                )
            }
        }
        if audioTrackCarriesAudio {
            return true
        }
        return sequence.videoTracks.contains { track in
            videoTrackContributesAudio(track, project: project, nestingDepth: nestingDepth)
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func sourceBuffer(
        for clip: Clip,
        requiredSourceWindow: TimeRange,
        context: OfflineMixContext,
        environment: inout OfflineAudioRenderEnvironment,
        nestingDepth: Int,
        renderPath: OfflineAudioRenderPath
    ) throws -> AudioSourceBuffer {
        switch clip.source {
        case .media(let mediaID):
            let key = MediaAudioSourceKey(
                mediaID: mediaID,
                sourceRange: requiredSourceWindow
            )
            if let cached = environment.sourceCache[key] {
                return cached
            }
            let source = try environment.sourceProvider.audioSource(
                for: mediaID,
                covering: requiredSourceWindow
            )
            environment.sourceCache[key] = source
            return source
        case .sequence:
            return try compoundSourceBuffer(
                clip: clip,
                requiredSourceWindow: requiredSourceWindow,
                context: context,
                environment: &environment,
                nestingDepth: nestingDepth,
                renderPath: renderPath
            )
        case .title:
            throw AudioRenderError.unsupportedClipSource(clipID: clip.id)
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func compoundSourceBuffer(
        clip: Clip,
        requiredSourceWindow: TimeRange,
        context: OfflineMixContext,
        environment: inout OfflineAudioRenderEnvironment,
        nestingDepth: Int,
        renderPath: OfflineAudioRenderPath
    ) throws -> AudioSourceBuffer {
        guard case .sequence(let sequenceID) = clip.source else {
            throw AudioRenderError.unsupportedClipSource(clipID: clip.id)
        }
        guard nestingDepth < RenderGraphBuilder.maximumCompoundNestingDepth else {
            throw AudioRenderError.maximumCompoundNestingDepthExceeded(
                clipID: clip.id,
                depth: nestingDepth
            )
        }
        guard let project = environment.project else {
            throw AudioRenderError.unsupportedClipSource(clipID: clip.id)
        }
        guard let sequence = project.sequences.first(where: { $0.id == sequenceID }) else {
            throw AudioRenderError.missingSequenceReference(clipID: clip.id, sequenceID: sequenceID)
        }

        let sourceWindow = try paddedAlignedSourceWindow(
            for: requiredSourceWindow,
            sampleRate: context.format.sampleRate
        )
        let nestedRenderPath = renderPath + [.sequence(sequence.id)]
        let key = CompoundAudioSourceKey(
            sequenceID: sequenceID,
            sourceRange: sourceWindow.range,
            format: context.format,
            renderPath: nestedRenderPath
        )
        if let cached = environment.compoundSourceCache[key] {
            return cached
        }

        let nestedBuffer = try render(
            sequence: sequence,
            range: sourceWindow.range,
            format: context.format,
            environment: &environment,
            nestingDepth: nestingDepth + 1,
            renderPath: nestedRenderPath
        )
        let source = try AudioSourceBuffer(
            format: nestedBuffer.format,
            frameCount: nestedBuffer.frameCount,
            samples: nestedBuffer.samples,
            frameOffset: sourceWindow.frameOffset
        )
        environment.compoundSourceCache[key] = source
        return source
    }

    static func alignedSourceWindow(
        for range: TimeRange,
        sampleRate: Int
    ) throws -> (range: TimeRange, frameOffset: Int) {
        let startFrame = try sampleIndex(for: range.start, sampleRate: sampleRate, rounding: .down)
        let endFrame = try sampleIndex(for: end(of: range), sampleRate: sampleRate, rounding: .up)
        let frameCount = max(0, endFrame - startFrame)
        let alignedStart = try RationalTime(value: Int64(startFrame), timescale: Int64(sampleRate))
        let duration = try RationalTime(value: Int64(frameCount), timescale: Int64(sampleRate))
        return (try TimeRange(start: alignedStart, duration: duration), startFrame)
    }

    /// Sample-aligned source window with the same interpolation padding requested from media
    /// decoders. Compound sources are rendered PCM buffers, so their nested render must materialize
    /// those guard frames before the parent clip interpolates across the window boundary.
    static func paddedAlignedSourceWindow(
        for range: TimeRange,
        sampleRate: Int
    ) throws -> (range: TimeRange, frameOffset: Int) {
        let frames = try paddedDecodingFrameRange(for: range, sampleRate: sampleRate)
        let start = try RationalTime(
            value: Int64(frames.lowerBound),
            timescale: Int64(sampleRate)
        )
        let duration = try RationalTime(
            value: Int64(frames.count),
            timescale: Int64(sampleRate)
        )
        return (try TimeRange(start: start, duration: duration), frames.lowerBound)
    }

    /// Frame conversion shared by public media requests and internal compound materialization.
    static func paddedDecodingFrameRange(
        for range: TimeRange,
        sampleRate: Int
    ) throws -> Range<Int> {
        guard sampleRate > 0 else {
            throw AudioRenderError.invalidFormat(
                sampleRate: sampleRate,
                channelCount: 1,
                frameCount: 0
            )
        }
        let startFrame = try sampleIndex(
            for: range.start,
            sampleRate: sampleRate,
            rounding: .down
        )
        let endFrame = try sampleIndex(
            for: end(of: range),
            sampleRate: sampleRate,
            rounding: .up
        )
        guard endFrame < Int.max else {
            throw AudioRenderError.timeArithmetic("padded decoder frame range overflows Int")
        }
        let lowerPadding = min(startFrame, 2)
        return (startFrame - lowerPadding)..<(endFrame + 1)
    }
}
