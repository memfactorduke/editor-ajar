// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A deterministic identifier for a render graph node.
public struct RenderNodeID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    /// Stable node ID string.
    public let rawValue: String

    /// Creates a node ID from a stable string.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A human-readable representation of the node ID.
    public var description: String {
        rawValue
    }
}

/// Background value for a composite node.
public enum RenderCompositeBackground: String, Codable, Equatable, Sendable {
    /// Transparent black output.
    case transparent
}

/// One source input plus its compositing instructions.
public struct RenderCompositeInput: Codable, Equatable, Sendable {
    /// Source node to composite.
    public let sourceNodeID: RenderNodeID

    /// Static transform to apply while compositing the source.
    public let transform: ClipTransform

    /// Clip effects to apply while compositing the source.
    public let effects: ClipEffects

    /// Evaluated track opacity to apply while compositing the track result.
    public let trackOpacity: RationalValue

    /// Track blend mode to use when compositing this track onto lower tracks.
    public let trackBlendMode: ClipBlendMode

    /// Creates a composite input.
    public init(
        sourceNodeID: RenderNodeID,
        transform: ClipTransform,
        effects: ClipEffects = .none,
        trackOpacity: RationalValue = .one,
        trackBlendMode: ClipBlendMode = .normal
    ) {
        self.sourceNodeID = sourceNodeID
        self.transform = transform
        self.effects = effects
        self.trackOpacity = trackOpacity
        self.trackBlendMode = trackBlendMode
    }
}

struct RenderCompositeNodeInput {
    let node: RenderNode
    let transform: ClipTransform
    let effects: ClipEffects
    let trackOpacity: RationalValue
    let trackBlendMode: ClipBlendMode
}

struct RenderCompoundNodeSpec {
    let sequenceID: UUID
    let clipID: UUID
    let sequenceTime: RationalTime
    let speed: RationalValue
    let graph: RenderGraph
    let colorSpace: MediaColorSpace
}

/// Resolved media source parameters for a source render node.
public struct RenderSourceNode: Codable, Equatable, Sendable {
    /// Stable media reference ID to decode.
    public let mediaID: UUID

    /// Stable clip ID that requested this source frame.
    public let clipID: UUID

    /// Exact time in source media coordinates.
    public let sourceTime: RationalTime

    /// Constant-rate playback speed that mapped sequence time to source time.
    public let speed: RationalValue

    /// Tagged source color space used by the render pipeline.
    public let colorSpace: MediaColorSpace

    /// Creates resolved source node parameters.
    public init(
        mediaID: UUID,
        clipID: UUID,
        sourceTime: RationalTime,
        speed: RationalValue = .one,
        colorSpace: MediaColorSpace = .rec709
    ) {
        self.mediaID = mediaID
        self.clipID = clipID
        self.sourceTime = sourceTime
        self.speed = speed
        self.colorSpace = colorSpace
    }
}

/// Resolved compound clip source parameters for a nested sequence render node.
public struct RenderCompoundNode: Codable, Equatable, Sendable {
    /// Stable sequence ID to render as the nested source.
    public let sequenceID: UUID

    /// Stable clip ID that requested this nested sequence frame.
    public let clipID: UUID

    /// Exact time in nested sequence coordinates.
    public let sequenceTime: RationalTime

    /// Constant-rate playback speed that mapped sequence time to nested sequence time.
    public let speed: RationalValue

    /// Nested sequence graph evaluated at `sequenceTime`.
    public let graph: RenderGraph

    /// Encoded color space of the nested render output.
    public let colorSpace: MediaColorSpace

    /// Creates resolved compound node parameters.
    public init(
        sequenceID: UUID,
        clipID: UUID,
        sequenceTime: RationalTime,
        speed: RationalValue = .one,
        graph: RenderGraph,
        colorSpace: MediaColorSpace
    ) {
        self.sequenceID = sequenceID
        self.clipID = clipID
        self.sequenceTime = sequenceTime
        self.speed = speed
        self.graph = graph
        self.colorSpace = colorSpace
    }
}

/// Resolved composite parameters for the M2 output node.
public struct RenderCompositeNode: Codable, Equatable, Sendable {
    /// Output background when there are no inputs.
    public let background: RenderCompositeBackground

    /// Source inputs in composite order.
    public let inputs: [RenderCompositeInput]

    /// Linear-light working space primaries for compositing.
    public let workingColorSpace: MediaColorSpace

    /// Encoded output/display color space.
    public let outputColorSpace: MediaColorSpace

    /// Creates resolved composite node parameters.
    public init(
        background: RenderCompositeBackground = .transparent,
        inputs: [RenderCompositeInput] = [],
        workingColorSpace: MediaColorSpace = .rec709,
        outputColorSpace: MediaColorSpace = .rec709
    ) {
        self.background = background
        self.inputs = inputs
        self.workingColorSpace = workingColorSpace
        self.outputColorSpace = outputColorSpace
    }
}

/// Typed render node payloads emitted by `AjarCore`.
public enum RenderNodeKind: Codable, Equatable, Sendable {
    /// A decoded media frame request.
    case source(RenderSourceNode)

    /// A nested sequence rendered as a compound clip source.
    case compound(RenderCompoundNode)

    /// The output composite node.
    case composite(RenderCompositeNode)
}

/// A typed immutable render graph node with deterministic cache identity.
public struct RenderNode: Codable, Equatable, Sendable {
    /// Stable node ID used by downstream executors.
    public let id: RenderNodeID

    /// Resolved node payload.
    public let kind: RenderNodeKind

    /// Input node IDs in evaluation order.
    public let inputIDs: [RenderNodeID]

    /// Cache identity derived from node type, resolved params, and input content hashes.
    public let contentHash: ContentHash

    /// Creates a node with a precomputed content hash.
    public init(
        id: RenderNodeID,
        kind: RenderNodeKind,
        inputIDs: [RenderNodeID],
        contentHash: ContentHash
    ) {
        self.id = id
        self.kind = kind
        self.inputIDs = inputIDs
        self.contentHash = contentHash
    }
}

/// An immutable render graph DAG for one sequence time.
public struct RenderGraph: Codable, Equatable, Sendable {
    /// Nodes in dependency order: inputs before consumers.
    public let nodes: [RenderNode]

    /// Final output node ID.
    public let outputNodeID: RenderNodeID

    /// Creates a render graph.
    public init(nodes: [RenderNode], outputNodeID: RenderNodeID) {
        self.nodes = nodes
        self.outputNodeID = outputNodeID
    }

    /// The final output node, when present in `nodes`.
    public var outputNode: RenderNode? {
        node(withID: outputNodeID)
    }

    /// Returns a node by ID.
    public func node(withID id: RenderNodeID) -> RenderNode? {
        nodes.first { node in
            node.id == id
        }
    }
}

enum RenderNodeFactory {
    static func makeSourceNode(
        mediaID: UUID,
        clipID: UUID,
        sourceTime: RationalTime,
        speed: RationalValue,
        colorSpace: MediaColorSpace
    ) throws -> RenderNode {
        let kind = RenderNodeKind.source(
            RenderSourceNode(
                mediaID: mediaID,
                clipID: clipID,
                sourceTime: sourceTime,
                speed: speed,
                colorSpace: colorSpace
            )
        )
        return try makeNode(
            id: RenderNodeID(rawValue: "source:\(clipID.uuidString)"),
            kind: kind,
            inputIDs: [],
            inputHashes: []
        )
    }

    static func makeCompositeNode(
        inputs: [RenderCompositeNodeInput],
        workingColorSpace: MediaColorSpace,
        outputColorSpace: MediaColorSpace
    ) throws -> RenderNode {
        let compositeInputs = inputs.map { input in
            RenderCompositeInput(
                sourceNodeID: input.node.id,
                transform: input.transform,
                effects: input.effects,
                trackOpacity: input.trackOpacity,
                trackBlendMode: input.trackBlendMode
            )
        }
        return try makeNode(
            id: RenderNodeID(rawValue: "composite:output"),
            kind: .composite(
                RenderCompositeNode(
                    inputs: compositeInputs,
                    workingColorSpace: workingColorSpace,
                    outputColorSpace: outputColorSpace
                )
            ),
            inputIDs: inputs.map(\.node.id),
            inputHashes: inputs.map(\.node.contentHash)
        )
    }

    static func makeCompoundNode(_ spec: RenderCompoundNodeSpec) throws -> RenderNode {
        guard let outputHash = spec.graph.outputNode?.contentHash else {
            throw RenderGraphBuildError.missingNestedOutputNode(sequenceID: spec.sequenceID)
        }
        let kind = RenderNodeKind.compound(
            RenderCompoundNode(
                sequenceID: spec.sequenceID,
                clipID: spec.clipID,
                sequenceTime: spec.sequenceTime,
                speed: spec.speed,
                graph: spec.graph,
                colorSpace: spec.colorSpace
            )
        )
        return try makeNode(
            id: RenderNodeID(rawValue: "compound:\(spec.clipID.uuidString)"),
            kind: kind,
            inputIDs: [spec.graph.outputNodeID],
            inputHashes: [outputHash]
        )
    }

    private static func makeNode(
        id: RenderNodeID,
        kind: RenderNodeKind,
        inputIDs: [RenderNodeID],
        inputHashes: [ContentHash]
    ) throws -> RenderNode {
        guard inputIDs.count == inputHashes.count else {
            throw RenderGraphBuildError.inputHashCountMismatch(
                nodeID: id,
                inputIDCount: inputIDs.count,
                inputHashCount: inputHashes.count
            )
        }

        return RenderNode(
            id: id,
            kind: kind,
            inputIDs: inputIDs,
            contentHash: try contentHash(kind: kind, inputHashes: inputHashes)
        )
    }

    private static func contentHash(
        kind: RenderNodeKind,
        inputHashes: [ContentHash]
    ) throws -> ContentHash {
        let payload = RenderNodeHashPayload(kind: kind, inputHashes: inputHashes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        do {
            return ContentHash.sha256(data: try encoder.encode(payload))
        } catch {
            throw RenderGraphBuildError.contentHashEncodingFailed(String(describing: error))
        }
    }
}

private struct RenderNodeHashPayload: Codable {
    let kind: RenderNodeKind
    let inputHashes: [ContentHash]
}
