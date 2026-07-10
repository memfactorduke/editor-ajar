// SPDX-License-Identifier: GPL-3.0-or-later
// swiftlint:disable file_length

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

// swiftlint:disable type_body_length
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
        let layers = try activeTrackLayers(in: sequence, at: time)
        guard !layers.isEmpty else {
            return try transparentGraph(outputColorSpace: project.settings.colorSpace)
        }

        return try graph(
            for: layers,
            at: time,
            in: project,
            nestingDepth: nestingDepth
        )
    }

    /// One track's contribution at `time`: a single clip, or a transition pair under the
    /// ADR-0015 fade-tail model (ADR-0016 §5).
    private enum TrackLayer {
        case clip(ActiveClipCandidate)
        case transition(outgoing: ActiveClipCandidate, incoming: ActiveClipCandidate)
    }

    private struct ActiveClipCandidate {
        let clip: Clip
        let trackOpacity: RationalValue
        let trackBlendMode: ClipBlendMode
        /// True when the clip is active only via its trailing transition fade-tail window
        /// (timeline geometry already ended; source keeps reading past the out-point).
        let isFadeTail: Bool
    }

    /// Collects per-track active layers, including fade-tail outgoing clips that own an
    /// active transition region covering `time`.
    private static func activeTrackLayers(
        in sequence: Sequence,
        at time: RationalTime
    ) throws -> [TrackLayer] {
        var layers: [TrackLayer] = []

        for track in sequence.videoTracks where track.enabled && !track.hidden {
            let candidates = try activeCandidates(
                on: track,
                at: time
            )
            if candidates.isEmpty {
                continue
            }
            if let layer = try resolveTrackLayer(candidates: candidates, at: time) {
                layers.append(layer)
            }
        }

        return layers
    }

    private static func activeCandidates(
        on track: Track,
        at time: RationalTime
    ) throws -> [ActiveClipCandidate] {
        var candidates: [ActiveClipCandidate] = []
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
                            trackBlendMode: track.blendMode,
                            isFadeTail: false
                        )
                    )
                    continue
                }
                // Fade-tail window: outgoing trailing transition keeps the source readable
                // for D past the timeline out-point without changing sequence duration.
                if let trailing = clip.trailingTransition, trailing.duration > .zero {
                    let clipEnd = try clip.timelineRange.end()
                    let tailEnd = try clipEnd.adding(trailing.duration)
                    if time >= clipEnd && time < tailEnd {
                        candidates.append(
                            ActiveClipCandidate(
                                clip: clip,
                                trackOpacity: track.opacity.value(at: time),
                                trackBlendMode: track.blendMode,
                                isFadeTail: true
                            )
                        )
                    }
                }
            } catch let error as RationalTimeError {
                throw RenderGraphBuildError.timeMappingFailed(error)
            }
        }
        return candidates
    }

    /// Prefer a validated transition pair (outgoing fade-tail + incoming normal) when both
    /// sides are active; otherwise a single non-tail clip. Multiple unrelated candidates on
    /// one track are a model error under ADR-0008 (non-overlap).
    ///
    /// **Broken / one-sided pairs:** when a fade-tail candidate and a live clip share the
    /// window but fail pair agreement (mirror missing, partner mismatch), the tail is
    /// dropped and the incoming clip renders alone — matching the audio model's
    /// render-off-trailing-record posture so playback never hard-fails mid-frame.
    /// Project validation (`ClipVideoTransitionValidator`) still reports the taxonomy as a
    /// typed model error; the graph has no soft-diagnostic channel beyond that.
    private static func resolveTrackLayer(
        candidates: [ActiveClipCandidate],
        at time: RationalTime
    ) throws -> TrackLayer? {
        let tails = candidates.filter(\.isFadeTail)
        let normals = candidates.filter { !$0.isFadeTail }

        if let outgoing = tails.first, let incoming = normals.first {
            if let trailing = outgoing.clip.trailingTransition,
                trailing.partnerClipID == incoming.clip.id,
                incoming.clip.leadingTransition?.partnerClipID == outgoing.clip.id {
                return .transition(outgoing: outgoing, incoming: incoming)
            }
            // One-sided or mismatched transition metadata: drop the fade-tail and keep the
            // live (incoming) clip so frames in [T, T+D) still render.
            return .clip(incoming)
        }

        if normals.count == 1, tails.isEmpty {
            return .clip(normals[0])
        }
        if normals.isEmpty, tails.count == 1 {
            // Orphan fade-tail without a live partner — treat as ordinary source (still
            // decodable via sourceTime past the out-point) so playback does not go black.
            return .clip(tails[0])
        }
        if candidates.count > 1 {
            throw RenderGraphBuildError.multipleActiveVideoClips(
                time: time,
                clipIDs: candidates.map(\.clip.id)
            )
        }
        return candidates.first.map { .clip($0) }
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
        for layers: [TrackLayer],
        at time: RationalTime,
        in project: Project,
        nestingDepth: Int
    ) throws -> RenderGraph {
        var nodes: [RenderNode] = []
        var compositeInputs: [RenderCompositeNodeInput] = []

        for layer in layers {
            switch layer {
            case .clip(let candidate):
                let source = try sourceNode(
                    for: candidate.clip,
                    at: time,
                    in: project,
                    nestingDepth: nestingDepth
                )
                nodes.append(source)
                compositeInputs.append(compositeInput(for: candidate, source: source, at: time))
            case .transition(let outgoing, let incoming):
                let built = try transitionLayer(
                    outgoing: outgoing,
                    incoming: incoming,
                    at: time,
                    in: project,
                    nestingDepth: nestingDepth
                )
                nodes.append(contentsOf: built.nodes)
                compositeInputs.append(built.compositeInput)
            }
        }

        let compositeNode = try RenderNodeFactory.makeCompositeNode(
            inputs: compositeInputs,
            workingColorSpace: project.settings.colorSpace,
            outputColorSpace: project.settings.colorSpace
        )
        nodes.append(compositeNode)
        return RenderGraph(nodes: nodes, outputNodeID: compositeNode.id)
    }

    private static func compositeInput(
        for candidate: ActiveClipCandidate,
        source: RenderNode,
        at time: RationalTime
    ) -> RenderCompositeNodeInput {
        let stack = candidate.clip.effectStackAnimation.value(at: time)
        let effectStack: ClipEffectStack? = stack.nodes.isEmpty ? nil : stack
        return RenderCompositeNodeInput(
            node: source,
            transform: candidate.clip.transformAnimation.value(at: time),
            effects: candidate.clip.effectsAnimation.value(at: time),
            effectStack: effectStack,
            trackOpacity: candidate.trackOpacity,
            trackBlendMode: candidate.trackBlendMode
        )
    }

    // swiftlint:disable:next function_body_length
    private static func transitionLayer(
        outgoing: ActiveClipCandidate,
        incoming: ActiveClipCandidate,
        at time: RationalTime,
        in project: Project,
        nestingDepth: Int
    ) throws -> (nodes: [RenderNode], compositeInput: RenderCompositeNodeInput) {
        guard let trailing = outgoing.clip.trailingTransition else {
            // Unreachable when resolveTrackLayer only emits pairs with a trailing record.
            let source = try sourceNode(
                for: incoming.clip,
                at: time,
                in: project,
                nestingDepth: nestingDepth
            )
            return (
                [source],
                compositeInput(for: incoming, source: source, at: time)
            )
        }

        let outgoingSource = try sourceNode(
            for: outgoing.clip,
            at: time,
            in: project,
            nestingDepth: nestingDepth
        )
        let incomingSource = try sourceNode(
            for: incoming.clip,
            at: time,
            in: project,
            nestingDepth: nestingDepth
        )

        let progress = try transitionProgress(
            at: time,
            cutTime: try outgoing.clip.timelineRange.end(),
            duration: trailing.duration
        )
        let outgoingStack = outgoing.clip.effectStackAnimation.value(at: time)
        let incomingStack = incoming.clip.effectStackAnimation.value(at: time)
        let transition = RenderTransitionNode(
            outgoingClipID: outgoing.clip.id,
            incomingClipID: incoming.clip.id,
            kind: trailing.kind,
            progress: progress,
            color: trailing.color,
            direction: trailing.direction,
            outgoingTransform: outgoing.clip.transformAnimation.value(at: time),
            outgoingEffects: outgoing.clip.effectsAnimation.value(at: time),
            outgoingEffectStack: outgoingStack.nodes.isEmpty ? nil : outgoingStack,
            incomingTransform: incoming.clip.transformAnimation.value(at: time),
            incomingEffects: incoming.clip.effectsAnimation.value(at: time),
            incomingEffectStack: incomingStack.nodes.isEmpty ? nil : incomingStack
        )
        let transitionNode = try RenderNodeFactory.makeTransitionNode(
            transition: transition,
            outgoingSource: outgoingSource,
            incomingSource: incomingSource
        )
        // Composite receives the already-blended transition result with identity transform;
        // per-side transform/effects are applied inside the transition pass.
        let compositeInput = RenderCompositeNodeInput(
            node: transitionNode,
            transform: .identity,
            effects: .none,
            effectStack: nil,
            trackOpacity: incoming.trackOpacity,
            trackBlendMode: incoming.trackBlendMode
        )
        return (
            [outgoingSource, incomingSource, transitionNode],
            compositeInput
        )
    }

    /// `elapsed / duration` clamped to `[0, 1]` for the fade-tail region `[T, T + D)`.
    private static func transitionProgress(
        at time: RationalTime,
        cutTime: RationalTime,
        duration: RationalTime
    ) throws -> RationalValue {
        do {
            let elapsed = try time.subtracting(cutTime)
            if elapsed <= .zero {
                return .zero
            }
            if elapsed >= duration {
                return .one
            }
            // progress = elapsed / duration as RationalValue (exact fraction of seconds).
            // elapsed = e.value/e.timescale, duration = d.value/d.timescale
            // ratio = (e.value * d.timescale) / (d.value * e.timescale)
            let numerator = try Self.multiplied(elapsed.value, by: duration.timescale)
            let denominator = try Self.multiplied(duration.value, by: elapsed.timescale)
            guard denominator > 0 else {
                return .zero
            }
            return try RationalValue(numerator: numerator, denominator: denominator)
        } catch let error as RationalTimeError {
            throw RenderGraphBuildError.timeMappingFailed(error)
        } catch let error as RationalValueError {
            throw RenderGraphBuildError.contentHashEncodingFailed(String(describing: error))
        }
    }

    private static func multiplied(_ left: Int64, by right: Int64) throws -> Int64 {
        let (result, overflow) = left.multipliedReportingOverflow(by: right)
        if overflow {
            throw RationalTimeError.arithmeticOverflow
        }
        return result
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
            // Evaluate revealFraction at the graph time so typewriter frames hash distinctly
            // (FR-TXT-004 / ADR-0009). The full keyframed model lives on the clip; the node
            // carries a constant snapshot for cache identity + rasterization.
            return try RenderNodeFactory.makeTitleNode(
                clipID: clip.id,
                title: title.evaluated(at: time),
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

        // Fade-tail: `sourceTime(at:)` continues linearly past the timeline out-point using
        // the same constant-rate mapping as audio (ADR-0015 §2 / ADR-0016 §5).
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
                colorSpace: media.metadata.colorSpace,
                mediaContentHash: media.contentHash,
                mediaAvailability: media.availability,
                offlineSlateDimensions: media.metadata.pixelDimensions
                    ?? project.settings.resolution
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
// swiftlint:enable type_body_length

/// Builds a render graph for `sequence` at `time` using project media references.
public func buildRenderGraph(
    for sequence: Sequence,
    at time: RationalTime,
    in project: Project
) throws -> RenderGraph {
    try RenderGraphBuilder.build(for: sequence, at: time, in: project)
}
