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
