// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Errors produced by pure render graph construction.
public enum RenderGraphBuildError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A media-backed clip references a missing media ID.
    case missingMediaReference(clipID: UUID, mediaID: UUID)

    /// A compound clip references a missing sequence ID.
    case missingSequenceReference(clipID: UUID, sequenceID: UUID)

    /// A nested graph did not produce its declared output node.
    case missingNestedOutputNode(sequenceID: UUID)

    /// Compound nesting exceeded the defensive render graph recursion limit.
    case maximumCompoundNestingDepthExceeded(clipID: UUID, depth: Int)

    /// M2 only supports one active video clip at the requested time.
    case multipleActiveVideoClips(time: RationalTime, clipIDs: [UUID])

    /// Exact time math failed while selecting or mapping a clip.
    case timeMappingFailed(RationalTimeError)

    /// Clip speed mapping failed while selecting a source frame.
    case clipSpeedMappingFailed(clipID: UUID, error: ClipSpeedMappingError)

    /// Internal node factory input IDs and hashes were mismatched.
    case inputHashCountMismatch(nodeID: RenderNodeID, inputIDCount: Int, inputHashCount: Int)

    /// Stable hash payload encoding failed.
    case contentHashEncodingFailed(String)

    /// A human-readable description of the build failure.
    public var description: String {
        switch self {
        case .missingMediaReference(let clipID, let mediaID):
            "clip \(clipID) references missing media \(mediaID)"
        case .missingSequenceReference(let clipID, let sequenceID):
            "clip \(clipID) references missing sequence \(sequenceID)"
        case .missingNestedOutputNode(let sequenceID):
            "nested sequence \(sequenceID) did not produce an output node"
        case .maximumCompoundNestingDepthExceeded(let clipID, let depth):
            "clip \(clipID) exceeded maximum compound nesting depth \(depth)"
        case .multipleActiveVideoClips(let time, let clipIDs):
            "multiple active video clips at \(time): \(clipIDs)"
        case .timeMappingFailed(let error):
            "render graph time mapping failed: \(error)"
        case .clipSpeedMappingFailed(let clipID, let error):
            "render graph speed mapping failed for clip \(clipID): \(error)"
        case .inputHashCountMismatch(let nodeID, let inputIDCount, let inputHashCount):
            "node \(nodeID) has \(inputIDCount) input IDs but \(inputHashCount) input hashes"
        case .contentHashEncodingFailed(let message):
            "render graph content hash encoding failed: \(message)"
        }
    }
}

/// Pure builder for immutable render graph descriptions.
public enum RenderGraphBuilder {
    /// Defensive nesting limit for malformed projects that bypass validation.
    public static let maximumCompoundNestingDepth = 16

    /// Builds a render graph for `sequence` at `time` using project media references.
    public static func build(
        for sequence: Sequence,
        at time: RationalTime,
        in project: Project
    ) throws -> RenderGraph {
        try build(for: sequence, at: time, in: project, nestingDepth: 0)
    }

    private static func build(
        for sequence: Sequence,
        at time: RationalTime,
        in project: Project,
        nestingDepth: Int
    ) throws -> RenderGraph {
        let candidates = try activeMediaClips(in: sequence, at: time)
        guard !candidates.isEmpty else {
            return try transparentGraph(outputColorSpace: project.settings.colorSpace)
        }

        return try graph(
            for: candidates,
            at: time,
            in: project,
            nestingDepth: nestingDepth
        )
    }

    private struct ActiveClipCandidate {
        let clip: Clip
        let trackOpacity: RationalValue
        let trackBlendMode: ClipBlendMode
    }

    private static func activeMediaClips(
        in sequence: Sequence,
        at time: RationalTime
    ) throws -> [ActiveClipCandidate] {
        var candidates: [ActiveClipCandidate] = []

        for track in sequence.videoTracks where track.enabled && !track.hidden {
            for item in track.items {
                guard case .clip(let clip) = item else {
                    continue
                }

                do {
                    if try clip.timelineRange.contains(time) {
                        candidates.append(
                            ActiveClipCandidate(
                                clip: clip,
                                trackOpacity: track.opacity.value(at: time),
                                trackBlendMode: track.blendMode
                            )
                        )
                    }
                } catch let error as RationalTimeError {
                    throw RenderGraphBuildError.timeMappingFailed(error)
                }
            }
        }

        return candidates
    }

    private static func transparentGraph(outputColorSpace: MediaColorSpace) throws -> RenderGraph {
        let compositeNode = try RenderNodeFactory.makeCompositeNode(
            inputs: [],
            workingColorSpace: outputColorSpace,
            outputColorSpace: outputColorSpace
        )
        return RenderGraph(nodes: [compositeNode], outputNodeID: compositeNode.id)
    }

    private static func graph(
        for candidates: [ActiveClipCandidate],
        at time: RationalTime,
        in project: Project,
        nestingDepth: Int
    ) throws -> RenderGraph {
        let sourceInputs = try candidates.map { candidate in
            RenderCompositeNodeInput(
                node: try sourceNode(
                    for: candidate.clip,
                    at: time,
                    in: project,
                    nestingDepth: nestingDepth
                ),
                transform: candidate.clip.transformAnimation.value(at: time),
                effects: candidate.clip.effectsAnimation.value(at: time),
                trackOpacity: candidate.trackOpacity,
                trackBlendMode: candidate.trackBlendMode
            )
        }
        let compositeNode = try RenderNodeFactory.makeCompositeNode(
            inputs: sourceInputs,
            workingColorSpace: project.settings.colorSpace,
            outputColorSpace: project.settings.colorSpace
        )

        return RenderGraph(
            nodes: sourceInputs.map(\.node) + [compositeNode],
            outputNodeID: compositeNode.id
        )
    }

    private static func sourceNode(
        for clip: Clip,
        at time: RationalTime,
        in project: Project,
        nestingDepth: Int
    ) throws -> RenderNode {
        switch clip.source {
        case .media(let mediaID):
            return try mediaSourceNode(mediaID: mediaID, clip: clip, at: time, in: project)
        case .sequence(let sequenceID):
            return try compoundSourceNode(
                sequenceID: sequenceID,
                clip: clip,
                at: time,
                in: project,
                nestingDepth: nestingDepth
            )
        case .title(let title):
            return try RenderNodeFactory.makeTitleNode(
                clipID: clip.id,
                title: title,
                colorSpace: project.settings.colorSpace
            )
        }
    }

    private static func mediaSourceNode(
        mediaID: UUID,
        clip: Clip,
        at time: RationalTime,
        in project: Project
    ) throws -> RenderNode {
        guard let media = project.mediaPool.first(where: { media in media.id == mediaID }) else {
            throw RenderGraphBuildError.missingMediaReference(clipID: clip.id, mediaID: mediaID)
        }

        let sourceTime = try mapTimelineTime(time, toSourceTimeFor: clip)
        return try RenderNodeFactory.makeSourceNode(
            RenderSourceNodeSpec(
                mediaID: mediaID,
                clipID: clip.id,
                sourceTime: sourceTime,
                sourceRange: clip.sourceRange,
                speed: clip.speed,
                reverse: clip.reverse,
                freezeFrame: clip.freezeFrame,
                timeRemap: clip.timeRemap,
                frameSampling: renderFrameSampling(for: clip),
                colorSpace: media.metadata.colorSpace
            )
        )
    }

    /// Maps the clip's FR-SPD-004 sampling mode onto the optional source node field.
    ///
    /// `nearest` maps to `nil` so pre-FR-SPD-004 projects and clips left on the default keep
    /// byte-identical source node content hashes.
    private static func renderFrameSampling(for clip: Clip) -> ClipFrameSamplingMode? {
        clip.frameSampling == .nearest ? nil : clip.frameSampling
    }

    private static func compoundSourceNode(
        sequenceID: UUID,
        clip: Clip,
        at time: RationalTime,
        in project: Project,
        nestingDepth: Int
    ) throws -> RenderNode {
        guard nestingDepth < maximumCompoundNestingDepth else {
            throw RenderGraphBuildError.maximumCompoundNestingDepthExceeded(
                clipID: clip.id,
                depth: nestingDepth
            )
        }
        guard
            let sequence = project.sequences.first(where: { sequence in
                sequence.id == sequenceID
            })
        else {
            throw RenderGraphBuildError.missingSequenceReference(
                clipID: clip.id,
                sequenceID: sequenceID
            )
        }

        let sequenceTime = try renderableSequenceTime(
            try mapTimelineTime(time, toSourceTimeFor: clip),
            for: clip,
            in: sequence
        )
        let graph = try build(
            for: sequence,
            at: sequenceTime,
            in: project,
            nestingDepth: nestingDepth + 1
        )
        return try RenderNodeFactory.makeCompoundNode(
            RenderCompoundNodeSpec(
                sequenceID: sequenceID,
                clipID: clip.id,
                sourceRange: clip.sourceRange,
                sequenceTime: sequenceTime,
                speed: clip.speed,
                reverse: clip.reverse,
                freezeFrame: clip.freezeFrame,
                timeRemap: clip.timeRemap,
                graph: graph,
                colorSpace: project.settings.colorSpace
            )
        )
    }

    private static func mapTimelineTime(
        _ time: RationalTime,
        toSourceTimeFor clip: Clip
    ) throws -> RationalTime {
        do {
            return try clip.sourceTime(at: time)
        } catch let error as ClipSpeedMappingError {
            throw RenderGraphBuildError.clipSpeedMappingFailed(clipID: clip.id, error: error)
        }
    }

    private static func renderableSequenceTime(
        _ time: RationalTime,
        for clip: Clip,
        in sequence: Sequence
    ) throws -> RationalTime {
        guard clip.reverse && !clip.freezeFrame else {
            return time
        }
        do {
            let sourceEnd = try clip.sourceRange.end()
            let sourceOffsetFromEnd = try sourceEnd.subtracting(time)
            let frameDuration = try sequence.timebase.duration(ofFrames: 1)
            let lastFrameTime = max(
                clip.sourceRange.start,
                try sourceEnd.subtracting(frameDuration)
            )
            return max(
                clip.sourceRange.start,
                try lastFrameTime.subtracting(sourceOffsetFromEnd)
            )
        } catch let error as RationalTimeError {
            throw RenderGraphBuildError.timeMappingFailed(error)
        }
    }
}

/// Builds a render graph for `sequence` at `time` using project media references.
public func buildRenderGraph(
    for sequence: Sequence,
    at time: RationalTime,
    in project: Project
) throws -> RenderGraph {
    try RenderGraphBuilder.build(for: sequence, at: time, in: project)
}
