// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// A conservative source-time window needed from one imported media item for an audio render.
///
/// The range remains exact and sample-rate independent. Platform decoders convert it into native
/// source-frame coordinates only after discovering the file's actual audio sample rate.
public struct AudioSourceTimeWindow: Equatable, Hashable, Sendable {
    /// Media-pool identifier of the source to decode.
    public let mediaID: UUID

    /// Half-open source-media time range needed by the mix.
    public let range: TimeRange

    /// Creates a source-time request. Callers normally receive these from `AudioSourcePlanner`.
    public init(mediaID: UUID, range: TimeRange) {
        self.mediaID = mediaID
        self.range = range
    }

    /// Native source frames to request from a decoder, including interpolation guard frames.
    ///
    /// The lower edge is padded by two frames and clamped at zero. The exclusive upper edge is
    /// padded by one frame. This covers the mixer's linear interpolation neighbor without deriving
    /// source addressing from the (possibly different) project sample rate.
    public func decodingFrameRange(sampleRate: Int) throws -> Range<Int> {
        try OfflineAudioMixer.paddedDecodingFrameRange(
            for: range,
            sampleRate: sampleRate
        )
    }
}

/// All imported-media audio required for one timeline render window.
public struct AudioSourcePlan: Equatable, Sendable {
    /// Deterministic, overlap-merged windows. One media ID may have several sparse windows.
    public let windows: [AudioSourceTimeWindow]

    /// Whether this render window references no audible imported media.
    public var isEmpty: Bool {
        windows.isEmpty
    }

    /// The sole planned window for `mediaID`, or `nil` when absent or represented sparsely.
    ///
    /// Existing one-window callers retain their convenient lookup. Sparse-aware callers use
    /// ``windows(for:)`` so they cannot accidentally recreate a large hull across source gaps.
    public func window(for mediaID: UUID) -> AudioSourceTimeWindow? {
        let matches = windows(for: mediaID)
        return matches.count == 1 ? matches[0] : nil
    }

    /// All bounded source windows for `mediaID`, ordered by source time.
    public func windows(for mediaID: UUID) -> [AudioSourceTimeWindow] {
        windows.filter { $0.mediaID == mediaID }
    }
}

/// Builds decoder requests using the same contributor and source-window rules as the audio mixer.
public enum AudioSourcePlanner {
    /// Plans imported-media source windows for `range` in `sequence`.
    ///
    /// Ordinary clips contribute only the source-time image of their intersection with the render.
    /// Pitch-corrected WSOLA clips retain their full effective source window because the stretch
    /// algorithm depends on the complete stream. Both choices delegate to the mixer's own mapping
    /// helper so decoder preparation, export, meters, ducking, and playback cannot drift. Compound
    /// padding uses `outputSampleRate`, defaulting to the project rate for existing callers.
    public static func plan(
        project: Project,
        sequence: Sequence,
        range: TimeRange,
        outputSampleRate: Int? = nil
    ) throws -> AudioSourcePlan {
        let resolvedOutputSampleRate = outputSampleRate ?? project.settings.audioSampleRate
        guard resolvedOutputSampleRate > 0 else {
            throw AudioRenderError.invalidFormat(
                sampleRate: resolvedOutputSampleRate,
                channelCount: 2,
                frameCount: 0
            )
        }
        var rangesByMediaID: [UUID: [TimeRange]] = [:]
        let context = AudioSourcePlanningContext(
            project: project,
            outputSampleRate: resolvedOutputSampleRate
        )
        try accumulate(
            context: context,
            sequence: sequence,
            range: range,
            nestingDepth: 0,
            rangesByMediaID: &rangesByMediaID
        )
        var windows: [AudioSourceTimeWindow] = []
        for mediaID in rangesByMediaID.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            let ranges = try mergedOverlappingRanges(rangesByMediaID[mediaID] ?? [])
            windows.append(
                contentsOf: ranges.map { sourceRange in
                    AudioSourceTimeWindow(mediaID: mediaID, range: sourceRange)
                })
        }
        return AudioSourcePlan(windows: windows)
    }
}

private struct AudioSourcePlanningContext {
    let project: Project
    let outputSampleRate: Int
}

extension AudioSourcePlanner {
    private static func accumulate(
        context: AudioSourcePlanningContext,
        sequence: Sequence,
        range: TimeRange,
        nestingDepth: Int,
        rangesByMediaID: inout [UUID: [TimeRange]]
    ) throws {
        try OfflineAudioMixer.validateCrossfades(in: sequence)
        let tracks = OfflineAudioMixer.audioContributorTracks(
            in: sequence,
            project: context.project,
            nestingDepth: nestingDepth
        )

        for track in tracks {
            try accumulate(
                context: context,
                track: track,
                range: range,
                nestingDepth: nestingDepth,
                rangesByMediaID: &rangesByMediaID
            )
        }
    }

    private static func accumulate(
        context: AudioSourcePlanningContext,
        track: Track,
        range: TimeRange,
        nestingDepth: Int,
        rangesByMediaID: inout [UUID: [TimeRange]]
    ) throws {
        for item in track.items {
            guard case .clip(let clip) = item,
                OfflineAudioMixer.clipCarriesAudio(clip, on: track),
                try OfflineAudioMixer.clipIntersectsMixRange(clip, range: range)
            else {
                continue
            }
            guard
                let sourceRange = try OfflineAudioMixer.requiredSourceWindow(
                    for: clip,
                    renderRange: range
                )
            else {
                continue
            }
            try accumulate(
                context: context,
                clip: clip,
                sourceRange: sourceRange,
                nestingDepth: nestingDepth,
                rangesByMediaID: &rangesByMediaID
            )
        }
    }

    private static func accumulate(
        context: AudioSourcePlanningContext,
        clip: Clip,
        sourceRange: TimeRange,
        nestingDepth: Int,
        rangesByMediaID: inout [UUID: [TimeRange]]
    ) throws {
        try validatePitchCorrectedWorkingSetEstimate(
            project: context.project,
            clip: clip,
            sourceRange: sourceRange,
            outputSampleRate: context.outputSampleRate
        )
        switch clip.source {
        case .media(let mediaID):
            rangesByMediaID[mediaID, default: []].append(sourceRange)
        case .sequence(let sequenceID):
            guard nestingDepth < RenderGraphBuilder.maximumCompoundNestingDepth else {
                throw AudioRenderError.maximumCompoundNestingDepthExceeded(
                    clipID: clip.id,
                    depth: nestingDepth
                )
            }
            guard
                let nested = context.project.sequences.first(where: { $0.id == sequenceID })
            else {
                throw AudioRenderError.missingSequenceReference(
                    clipID: clip.id,
                    sequenceID: sequenceID
                )
            }
            let nestedWindow = try OfflineAudioMixer.paddedAlignedSourceWindow(
                for: sourceRange,
                sampleRate: context.outputSampleRate
            ).range
            try accumulate(
                context: context,
                sequence: nested,
                range: nestedWindow,
                nestingDepth: nestingDepth + 1,
                rangesByMediaID: &rangesByMediaID
            )
        case .title:
            throw AudioRenderError.unsupportedClipSource(clipID: clip.id)
        }
    }

    /// Fails planning before a production provider decodes an obviously over-budget whole
    /// source window. The output rate is necessarily an estimate for native-rate media; the
    /// mixer repeats the same check with the decoded buffer's actual format before extraction.
    private static func validatePitchCorrectedWorkingSetEstimate(
        project: Project,
        clip: Clip,
        sourceRange: TimeRange,
        outputSampleRate: Int
    ) throws {
        guard clip.audioMix.retimeMode == .pitchCorrected else {
            return
        }
        let estimatedChannelCount: Int
        switch clip.source {
        case .media(let mediaID):
            estimatedChannelCount =
                project.mediaPool
                .first(where: { $0.id == mediaID })?
                .metadata.audioChannelLayout?.channelCount ?? 2
        case .sequence, .title:
            estimatedChannelCount = 2
        }
        let sampleRate = outputSampleRate
        let bounds = try OfflineAudioMixer.extractionFrameBounds(
            window: sourceRange,
            sampleRate: sampleRate
        )
        do {
            try WSOLATimeStretcher.validateWorkingSet(
                inputFrameCount: bounds.frameCount,
                channelCount: estimatedChannelCount,
                sampleRate: sampleRate,
                speed: clip.speed
            )
        } catch let error as WSOLATimeStretchError {
            throw AudioRenderError.pitchCorrectedStretchFailed(clipID: clip.id, error: error)
        }
    }

    private static func mergedOverlappingRanges(_ ranges: [TimeRange]) throws -> [TimeRange] {
        let ordered = ranges.sorted { left, right in
            if left.start != right.start {
                return left.start < right.start
            }
            return left.duration < right.duration
        }
        guard var current = ordered.first else {
            return []
        }
        var merged: [TimeRange] = []
        for incoming in ordered.dropFirst() {
            let currentEnd = try current.end()
            if incoming.start <= currentEnd {
                let mergedEnd = max(currentEnd, try incoming.end())
                current = try TimeRange(
                    start: current.start,
                    duration: mergedEnd.subtracting(current.start)
                )
            } else {
                merged.append(current)
                current = incoming
            }
        }
        merged.append(current)
        return merged
    }
}
