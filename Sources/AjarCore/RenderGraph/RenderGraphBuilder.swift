// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Errors produced by pure render graph construction.
public enum RenderGraphBuildError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A media-backed clip references a missing media ID.
    case missingMediaReference(clipID: UUID, mediaID: UUID)

    /// M2 only supports media-backed clips.
    case unsupportedClipSource(clipID: UUID, source: ClipSource)

    /// M2 only supports one active video clip at the requested time.
    case multipleActiveVideoClips(time: RationalTime, clipIDs: [UUID])

    /// Exact time math failed while selecting or mapping a clip.
    case timeMappingFailed(RationalTimeError)

    /// Internal node factory input IDs and hashes were mismatched.
    case inputHashCountMismatch(nodeID: RenderNodeID, inputIDCount: Int, inputHashCount: Int)

    /// Stable hash payload encoding failed.
    case contentHashEncodingFailed(String)

    /// A human-readable description of the build failure.
    public var description: String {
        switch self {
        case .missingMediaReference(let clipID, let mediaID):
            "clip \(clipID) references missing media \(mediaID)"
        case .unsupportedClipSource(let clipID, let source):
            "clip \(clipID) uses unsupported render source \(source)"
        case .multipleActiveVideoClips(let time, let clipIDs):
            "multiple active video clips at \(time): \(clipIDs)"
        case .timeMappingFailed(let error):
            "render graph time mapping failed: \(error)"
        case .inputHashCountMismatch(let nodeID, let inputIDCount, let inputHashCount):
            "node \(nodeID) has \(inputIDCount) input IDs but \(inputHashCount) input hashes"
        case .contentHashEncodingFailed(let message):
            "render graph content hash encoding failed: \(message)"
        }
    }
}

/// Pure builder for immutable render graph descriptions.
public enum RenderGraphBuilder {
    /// Builds a render graph for `sequence` at `time` using project media references.
    public static func build(
        for sequence: Sequence,
        at time: RationalTime,
        in project: Project
    ) throws -> RenderGraph {
        let candidates = try activeMediaClips(in: sequence, at: time)
        guard !candidates.isEmpty else {
            return try transparentGraph()
        }

        return try graph(for: candidates.map(\.clip), at: time, in: project)
    }

    private struct ActiveClipCandidate {
        let clip: Clip
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
                        candidates.append(ActiveClipCandidate(clip: clip))
                    }
                } catch let error as RationalTimeError {
                    throw RenderGraphBuildError.timeMappingFailed(error)
                }
            }
        }

        return candidates
    }

    private static func transparentGraph() throws -> RenderGraph {
        let compositeNode = try RenderNodeFactory.makeCompositeNode(inputs: [])
        return RenderGraph(nodes: [compositeNode], outputNodeID: compositeNode.id)
    }

    private static func graph(
        for clips: [Clip],
        at time: RationalTime,
        in project: Project
    ) throws -> RenderGraph {
        let sourceInputs = try clips.map { clip in
            RenderCompositeNodeInput(
                node: try sourceNode(for: clip, at: time, in: project),
                transform: clip.transformAnimation.value(at: time),
                effects: clip.effects
            )
        }
        let compositeNode = try RenderNodeFactory.makeCompositeNode(inputs: sourceInputs)

        return RenderGraph(
            nodes: sourceInputs.map(\.node) + [compositeNode],
            outputNodeID: compositeNode.id
        )
    }

    private static func sourceNode(
        for clip: Clip,
        at time: RationalTime,
        in project: Project
    ) throws -> RenderNode {
        let mediaID: UUID
        switch clip.source {
        case .media(let id):
            mediaID = id
        case .sequence:
            throw RenderGraphBuildError.unsupportedClipSource(clipID: clip.id, source: clip.source)
        }

        guard project.mediaPool.contains(where: { media in media.id == mediaID }) else {
            throw RenderGraphBuildError.missingMediaReference(clipID: clip.id, mediaID: mediaID)
        }

        let sourceTime = try mapTimelineTime(time, toSourceTimeFor: clip)
        return try RenderNodeFactory.makeSourceNode(
            mediaID: mediaID,
            clipID: clip.id,
            sourceTime: sourceTime
        )
    }

    private static func mapTimelineTime(
        _ time: RationalTime,
        toSourceTimeFor clip: Clip
    ) throws -> RationalTime {
        do {
            let offset = try time.subtracting(clip.timelineRange.start)
            return try clip.sourceRange.start.adding(offset)
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
