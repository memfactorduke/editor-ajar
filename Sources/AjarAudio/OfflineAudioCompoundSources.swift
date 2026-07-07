// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

struct CompoundAudioSourceKey: Hashable {
    let sequenceID: UUID
    let sourceRange: TimeRange
    let format: AudioRenderFormat
}

struct OfflineAudioRenderEnvironment {
    let project: Project?
    let sourceProvider: any AudioSourceProvider
    var sourceCache: [UUID: AudioSourceBuffer]
    var compoundSourceCache: [CompoundAudioSourceKey: AudioSourceBuffer]

    init(project: Project?, sourceProvider: any AudioSourceProvider) {
        self.project = project
        self.sourceProvider = sourceProvider
        sourceCache = [:]
        compoundSourceCache = [:]
    }
}

extension OfflineAudioMixer {
    /// Tracks that contribute audio to an offline mix (FR-CMP-001, FR-AUD-003).
    ///
    /// Enabled, unmuted audio tracks contribute their audio clips. Enabled, unmuted video
    /// tracks contribute only sequence-backed compound clips: an FR-CMP-001 collapse replaces
    /// the selection with one `.video` compound clip on a video track whose nested sequence
    /// carries the collapsed audio, so skipping video tracks would silence it. Solo applies
    /// across both sets: if any contributor is soloed, only soloed contributors play.
    static func audioContributorTracks(in sequence: Sequence) -> [Track] {
        let audioTracks = sequence.audioTracks.filter { track in
            track.kind == .audio && track.enabled && !track.muted
        }
        let compoundVideoTracks = sequence.videoTracks.filter { track in
            track.kind == .video && track.enabled && !track.muted
                && track.items.contains { item in
                    guard case .clip(let clip) = item else {
                        return false
                    }
                    return clipCarriesAudio(clip, on: track)
                }
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

    static func sourceBuffer(
        for clip: Clip,
        context: OfflineMixContext,
        environment: inout OfflineAudioRenderEnvironment,
        nestingDepth: Int
    ) throws -> AudioSourceBuffer {
        switch clip.source {
        case .media(let mediaID):
            if let cached = environment.sourceCache[mediaID] {
                return cached
            }
            let source = try environment.sourceProvider.audioSource(for: mediaID)
            environment.sourceCache[mediaID] = source
            return source
        case .sequence(let sequenceID):
            return try compoundSourceBuffer(
                sequenceID: sequenceID,
                clip: clip,
                context: context,
                environment: &environment,
                nestingDepth: nestingDepth
            )
        }
    }

    static func compoundSourceBuffer(
        sequenceID: UUID,
        clip: Clip,
        context: OfflineMixContext,
        environment: inout OfflineAudioRenderEnvironment,
        nestingDepth: Int
    ) throws -> AudioSourceBuffer {
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

        let sourceWindow = try alignedSourceWindow(
            for: clip.sourceRange,
            sampleRate: context.format.sampleRate
        )
        let key = CompoundAudioSourceKey(
            sequenceID: sequenceID,
            sourceRange: sourceWindow.range,
            format: context.format
        )
        if let cached = environment.compoundSourceCache[key] {
            return cached
        }

        let nestedBuffer = try render(
            sequence: sequence,
            range: sourceWindow.range,
            format: context.format,
            environment: &environment,
            nestingDepth: nestingDepth + 1
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
}
