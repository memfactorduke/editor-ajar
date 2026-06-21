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

    /// Creates a composite input.
    public init(sourceNodeID: RenderNodeID, transform: ClipTransform) {
        self.sourceNodeID = sourceNodeID
        self.transform = transform
    }
}

/// Resolved media source parameters for a source render node.
public struct RenderSourceNode: Codable, Equatable, Sendable {
    /// Stable media reference ID to decode.
    public let mediaID: UUID

    /// Stable clip ID that requested this source frame.
    public let clipID: UUID

    /// Exact time in source media coordinates.
    public let sourceTime: RationalTime

    /// Creates resolved source node parameters.
    public init(mediaID: UUID, clipID: UUID, sourceTime: RationalTime) {
        self.mediaID = mediaID
        self.clipID = clipID
        self.sourceTime = sourceTime
    }
}

/// Resolved composite parameters for the M2 output node.
public struct RenderCompositeNode: Codable, Equatable, Sendable {
    /// Output background when there are no inputs.
    public let background: RenderCompositeBackground

    /// Source inputs in composite order.
    public let inputs: [RenderCompositeInput]

    /// Creates resolved composite node parameters.
    public init(
        background: RenderCompositeBackground = .transparent,
        inputs: [RenderCompositeInput] = []
    ) {
        self.background = background
        self.inputs = inputs
    }
}

/// Typed render node payloads emitted by `AjarCore`.
public enum RenderNodeKind: Codable, Equatable, Sendable {
    /// A decoded media frame request.
    case source(RenderSourceNode)

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
        sourceTime: RationalTime
    ) throws -> RenderNode {
        let kind = RenderNodeKind.source(
            RenderSourceNode(mediaID: mediaID, clipID: clipID, sourceTime: sourceTime)
        )
        return try makeNode(
            id: RenderNodeID(rawValue: "source:\(clipID.uuidString)"),
            kind: kind,
            inputIDs: [],
            inputHashes: []
        )
    }

    static func makeCompositeNode(inputs: [(node: RenderNode, transform: ClipTransform)]) throws
        -> RenderNode {
        let compositeInputs = inputs.map { input in
            RenderCompositeInput(sourceNodeID: input.node.id, transform: input.transform)
        }
        return try makeNode(
            id: RenderNodeID(rawValue: "composite:output"),
            kind: .composite(RenderCompositeNode(inputs: compositeInputs)),
            inputIDs: inputs.map(\.node.id),
            inputHashes: inputs.map(\.node.contentHash)
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
