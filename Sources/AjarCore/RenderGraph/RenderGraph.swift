// SPDX-License-Identifier: GPL-3.0-or-later
// swiftlint:disable file_length

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

    /// Ordered FR-FX library stack applied before compositing (includes FR-COL-004 LUT).
    ///
    /// `nil` means an empty stack so pre-stack content hashes stay byte-identical
    /// (synthesized Codable omits absent optionals; ADR-0009). Empty stacks are normalized
    /// to `nil` on init/decode so large LUT tables never enter the hash path accidentally.
    public let effectStack: ClipEffectStack?

    /// Evaluated track opacity to apply while compositing the track result.
    public let trackOpacity: RationalValue

    /// Track blend mode to use when compositing this track onto lower tracks.
    public let trackBlendMode: ClipBlendMode

    private enum CodingKeys: String, CodingKey {
        case sourceNodeID
        case transform
        case effects
        case effectStack
        case trackOpacity
        case trackBlendMode
    }

    /// Creates a composite input.
    public init(
        sourceNodeID: RenderNodeID,
        transform: ClipTransform,
        effects: ClipEffects = .none,
        effectStack: ClipEffectStack? = nil,
        trackOpacity: RationalValue = .one,
        trackBlendMode: ClipBlendMode = .normal
    ) {
        self.sourceNodeID = sourceNodeID
        self.transform = transform
        self.effects = effects
        // Normalize empty stacks to nil so content hashes stay stable (and so LUT lattices
        // are never serialized into graph hashes via a vacuous empty stack).
        if let effectStack, !effectStack.nodes.isEmpty {
            self.effectStack = effectStack
        } else {
            self.effectStack = nil
        }
        self.trackOpacity = trackOpacity
        self.trackBlendMode = trackBlendMode
    }

    /// Decodes a composite input, defaulting a missing stack to nil/empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceNodeID = try container.decode(RenderNodeID.self, forKey: .sourceNodeID)
        transform = try container.decode(ClipTransform.self, forKey: .transform)
        effects = try container.decodeIfPresent(ClipEffects.self, forKey: .effects) ?? .none
        let decodedStack = try container.decodeIfPresent(ClipEffectStack.self, forKey: .effectStack)
        if let decodedStack, !decodedStack.nodes.isEmpty {
            effectStack = decodedStack
        } else {
            effectStack = nil
        }
        trackOpacity = try container.decodeIfPresent(RationalValue.self, forKey: .trackOpacity)
            ?? .one
        trackBlendMode =
            try container.decodeIfPresent(ClipBlendMode.self, forKey: .trackBlendMode) ?? .normal
    }

    /// Encodes a composite input, omitting an empty/absent effect stack.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceNodeID, forKey: .sourceNodeID)
        try container.encode(transform, forKey: .transform)
        try container.encode(effects, forKey: .effects)
        if let effectStack, !effectStack.nodes.isEmpty {
            try container.encode(effectStack, forKey: .effectStack)
        }
        try container.encode(trackOpacity, forKey: .trackOpacity)
        try container.encode(trackBlendMode, forKey: .trackBlendMode)
    }

    /// Resolved stack for render (empty when absent).
    public var resolvedEffectStack: ClipEffectStack {
        effectStack ?? .empty
    }
}

struct RenderCompositeNodeInput {
    let node: RenderNode
    let transform: ClipTransform
    let effects: ClipEffects
    let effectStack: ClipEffectStack?
    let trackOpacity: RationalValue
    let trackBlendMode: ClipBlendMode
}

struct RenderCompoundNodeSpec {
    let sequenceID: UUID
    let clipID: UUID
    let sourceRange: TimeRange
    let sequenceTime: RationalTime
    let speed: RationalValue
    let reverse: Bool
    let freezeFrame: Bool
    let timeRemap: ClipTimeRemap?
    let graph: RenderGraph
    let colorSpace: MediaColorSpace
}

struct RenderSourceNodeSpec {
    let mediaID: UUID
    let clipID: UUID
    let sourceTime: RationalTime
    let sourceRange: TimeRange
    let speed: RationalValue
    let reverse: Bool
    let freezeFrame: Bool
    let timeRemap: ClipTimeRemap?
    let frameSampling: ClipFrameSamplingMode?
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

    /// Source range used for discrete reverse/freeze boundary resolution.
    public let sourceRange: TimeRange?

    /// Constant-rate playback speed that mapped sequence time to source time.
    public let speed: RationalValue

    /// Whether the source node was resolved from a reversed clip.
    public let reverse: Bool

    /// Whether the source node was resolved from a freeze-frame clip.
    public let freezeFrame: Bool

    /// FR-SPD-002 time-remap curve that mapped sequence time to source time, when present.
    public let timeRemap: ClipTimeRemap?

    /// FR-SPD-004 frame sampling mode, when the clip opted out of nearest sampling.
    ///
    /// `nil` means nearest sampling. The field stays optional so pre-FR-SPD-004 source nodes
    /// keep byte-identical content-hash payloads: synthesized Codable omits absent optionals.
    public let frameSampling: ClipFrameSamplingMode?

    /// Tagged source color space used by the render pipeline.
    public let colorSpace: MediaColorSpace

    /// Creates resolved source node parameters.
    public init(
        mediaID: UUID,
        clipID: UUID,
        sourceTime: RationalTime,
        sourceRange: TimeRange? = nil,
        speed: RationalValue = .one,
        reverse: Bool = false,
        freezeFrame: Bool = false,
        timeRemap: ClipTimeRemap? = nil,
        frameSampling: ClipFrameSamplingMode? = nil,
        colorSpace: MediaColorSpace = .rec709
    ) {
        self.mediaID = mediaID
        self.clipID = clipID
        self.sourceTime = sourceTime
        self.sourceRange = sourceRange
        self.speed = speed
        self.reverse = reverse
        self.freezeFrame = freezeFrame
        self.timeRemap = timeRemap
        self.frameSampling = frameSampling
        self.colorSpace = colorSpace
    }
}

public extension RenderSourceNode {
    /// The frame sampling mode that applies at render time (FR-SPD-004).
    ///
    /// Freeze-frame sources hold a single decoded frame for the whole clip, so frame blending
    /// explicitly degenerates to nearest sampling here.
    var resolvedFrameSampling: ClipFrameSamplingMode {
        if freezeFrame {
            return .nearest
        }
        return frameSampling ?? .nearest
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

    /// Source range used for the nested sequence remap.
    public let sourceRange: TimeRange

    /// Constant-rate playback speed that mapped sequence time to nested sequence time.
    public let speed: RationalValue

    /// Whether the compound node was resolved from a reversed clip.
    public let reverse: Bool

    /// Whether the compound node was resolved from a freeze-frame clip.
    public let freezeFrame: Bool

    /// FR-SPD-002 time-remap curve that mapped sequence time to nested time, when present.
    public let timeRemap: ClipTimeRemap?

    /// Nested sequence graph evaluated at `sequenceTime`.
    public let graph: RenderGraph

    /// Encoded color space of the nested render output.
    public let colorSpace: MediaColorSpace

    /// Creates resolved compound node parameters.
    public init(
        sequenceID: UUID,
        clipID: UUID,
        sequenceTime: RationalTime,
        sourceRange: TimeRange,
        speed: RationalValue = .one,
        reverse: Bool = false,
        freezeFrame: Bool = false,
        timeRemap: ClipTimeRemap? = nil,
        graph: RenderGraph,
        colorSpace: MediaColorSpace
    ) {
        self.sequenceID = sequenceID
        self.clipID = clipID
        self.sequenceTime = sequenceTime
        self.sourceRange = sourceRange
        self.speed = speed
        self.reverse = reverse
        self.freezeFrame = freezeFrame
        self.timeRemap = timeRemap
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

/// Resolved title generator parameters for a title render node (FR-TXT-001, ADR-0017).
public struct RenderTitleNode: Codable, Equatable, Sendable {
    /// Stable clip ID that requested this title rasterization.
    public let clipID: UUID

    /// Title model to rasterize.
    public let title: TitleSource

    /// Tagged color space of the rasterized title texture (display-encoded Rec.709 for v1).
    public let colorSpace: MediaColorSpace

    /// Creates resolved title node parameters.
    public init(
        clipID: UUID,
        title: TitleSource,
        colorSpace: MediaColorSpace = .rec709
    ) {
        self.clipID = clipID
        self.title = title
        self.colorSpace = colorSpace
    }
}

/// Typed render node payloads emitted by `AjarCore`.
public enum RenderNodeKind: Codable, Equatable, Sendable {
    /// A decoded media frame request.
    case source(RenderSourceNode)

    /// A nested sequence rendered as a compound clip source.
    case compound(RenderCompoundNode)

    /// A title generator rasterization request (FR-TXT-001, ADR-0017).
    case title(RenderTitleNode)

    /// A two-input video transition over a fade-tail cut region (FR-FX-001 / ADR-0016 §5).
    case transition(RenderTransitionNode)

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
    static func makeSourceNode(_ spec: RenderSourceNodeSpec) throws -> RenderNode {
        let kind = RenderNodeKind.source(
            RenderSourceNode(
                mediaID: spec.mediaID,
                clipID: spec.clipID,
                sourceTime: spec.sourceTime,
                sourceRange: spec.sourceRange,
                speed: spec.speed,
                reverse: spec.reverse,
                freezeFrame: spec.freezeFrame,
                timeRemap: spec.timeRemap,
                frameSampling: spec.frameSampling,
                colorSpace: spec.colorSpace
            )
        )
        return try makeNode(
            id: RenderNodeID(rawValue: "source:\(spec.clipID.uuidString)"),
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
                effectStack: input.effectStack,
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
                sourceRange: spec.sourceRange,
                speed: spec.speed,
                reverse: spec.reverse,
                freezeFrame: spec.freezeFrame,
                timeRemap: spec.timeRemap,
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

    static func makeTitleNode(
        clipID: UUID,
        title: TitleSource,
        colorSpace: MediaColorSpace
    ) throws -> RenderNode {
        let kind = RenderNodeKind.title(
            RenderTitleNode(clipID: clipID, title: title, colorSpace: colorSpace)
        )
        return try makeNode(
            id: RenderNodeID(rawValue: "title:\(clipID.uuidString)"),
            kind: kind,
            inputIDs: [],
            inputHashes: []
        )
    }

    static func makeTransitionNode(
        transition: RenderTransitionNode,
        outgoingSource: RenderNode,
        incomingSource: RenderNode
    ) throws -> RenderNode {
        try makeNode(
            id: RenderNodeID(
                rawValue: "transition:\(transition.outgoingClipID.uuidString)"
            ),
            kind: .transition(transition),
            inputIDs: [outgoingSource.id, incomingSource.id],
            inputHashes: [outgoingSource.contentHash, incomingSource.contentHash]
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
        let payload = RenderNodeHashPayload(
            kind: RenderNodeHashKind(kind),
            inputHashes: inputHashes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        do {
            return ContentHash.sha256(data: try encoder.encode(payload))
        } catch {
            throw RenderGraphBuildError.contentHashEncodingFailed(String(describing: error))
        }
    }
}

private enum RenderNodeHashKind: Codable {
    case source(RenderSourceNode)
    case compound(RenderCompoundHashNode)
    case title(RenderTitleNode)
    case transition(RenderTransitionHashNode)
    /// Composite uses a digest-friendly stack payload so LUT tables are not re-encoded
    /// into every content hash (FR-COL-004 / PERFORMANCE §3).
    case composite(RenderCompositeHashNode)

    init(_ kind: RenderNodeKind) {
        switch kind {
        case .source(let source):
            self = .source(source)
        case .compound(let compound):
            self = .compound(RenderCompoundHashNode(compound))
        case .title(let title):
            self = .title(title)
        case .transition(let transition):
            self = .transition(RenderTransitionHashNode(transition))
        case .composite(let composite):
            self = .composite(RenderCompositeHashNode(composite))
        }
    }
}

/// Content-hash form of a transition: stacks carry digests, not full lattices.
private struct RenderTransitionHashNode: Codable {
    let outgoingClipID: UUID
    let incomingClipID: UUID
    let kind: ClipVideoTransitionKind
    let progress: RationalValue
    let color: ClipRGBColor
    let direction: ClipVideoTransitionDirection
    let outgoingTransform: ClipTransform
    let outgoingEffects: ClipEffects
    let outgoingEffectStack: RenderEffectStackHash?
    let incomingTransform: ClipTransform
    let incomingEffects: ClipEffects
    let incomingEffectStack: RenderEffectStackHash?

    init(_ transition: RenderTransitionNode) {
        outgoingClipID = transition.outgoingClipID
        incomingClipID = transition.incomingClipID
        kind = transition.kind
        progress = transition.progress
        color = transition.color
        direction = transition.direction
        outgoingTransform = transition.outgoingTransform
        outgoingEffects = transition.outgoingEffects
        if let stack = transition.outgoingEffectStack, !stack.nodes.isEmpty {
            outgoingEffectStack = RenderEffectStackHash(stack)
        } else {
            outgoingEffectStack = nil
        }
        incomingTransform = transition.incomingTransform
        incomingEffects = transition.incomingEffects
        if let stack = transition.incomingEffectStack, !stack.nodes.isEmpty {
            incomingEffectStack = RenderEffectStackHash(stack)
        } else {
            incomingEffectStack = nil
        }
    }
}

private struct RenderCompoundHashNode: Codable {
    let sequenceID: UUID
    let clipID: UUID
    let sequenceTime: RationalTime
    let sourceRange: TimeRange
    let speed: RationalValue
    let reverse: Bool
    let freezeFrame: Bool
    let timeRemap: ClipTimeRemap?
    let colorSpace: MediaColorSpace

    init(_ compound: RenderCompoundNode) {
        self.sequenceID = compound.sequenceID
        self.clipID = compound.clipID
        self.sequenceTime = compound.sequenceTime
        self.sourceRange = compound.sourceRange
        self.speed = compound.speed
        self.reverse = compound.reverse
        self.freezeFrame = compound.freezeFrame
        self.timeRemap = compound.timeRemap
        self.colorSpace = compound.colorSpace
    }
}

/// Content-hash form of a composite: effect stacks carry LUT digests, not full lattices.
private struct RenderCompositeHashNode: Codable {
    let background: RenderCompositeBackground
    let inputs: [RenderCompositeInputHash]
    let workingColorSpace: MediaColorSpace
    let outputColorSpace: MediaColorSpace

    init(_ composite: RenderCompositeNode) {
        background = composite.background
        inputs = composite.inputs.map(RenderCompositeInputHash.init)
        workingColorSpace = composite.workingColorSpace
        outputColorSpace = composite.outputColorSpace
    }
}

private struct RenderCompositeInputHash: Codable {
    let sourceNodeID: RenderNodeID
    let transform: ClipTransform
    let effects: ClipEffects
    let effectStack: RenderEffectStackHash?
    let trackOpacity: RationalValue
    let trackBlendMode: ClipBlendMode

    init(_ input: RenderCompositeInput) {
        sourceNodeID = input.sourceNodeID
        transform = input.transform
        effects = input.effects
        if let stack = input.effectStack, !stack.nodes.isEmpty {
            effectStack = RenderEffectStackHash(stack)
        } else {
            effectStack = nil
        }
        trackOpacity = input.trackOpacity
        trackBlendMode = input.trackBlendMode
    }
}

private struct RenderEffectStackHash: Codable {
    let nodes: [RenderEffectNodeHash]

    init(_ stack: ClipEffectStack) {
        nodes = stack.nodes.map(RenderEffectNodeHash.init)
    }
}

private struct RenderEffectNodeHash: Codable {
    let id: UUID
    let enabled: Bool
    let kind: String
    let parameters: RenderEffectParameterHash

    // swiftlint:disable:next cyclomatic_complexity
    init(_ node: ClipEffectNode) {
        id = node.id
        enabled = node.enabled
        kind = node.kind.rawValue
        switch node.definition {
        case .placeholder(let placeholderParameters):
            parameters = .placeholder(amount: placeholderParameters.amount)
        case .gaussianBlur(let blurParameters):
            parameters = .gaussianBlur(radius: blurParameters.radius)
        case .boxBlur(let blurParameters):
            parameters = .boxBlur(radius: blurParameters.radius)
        case .zoomBlur(let zoomParameters):
            parameters = .zoomBlur(
                amount: zoomParameters.amount,
                centerX: zoomParameters.centerX,
                centerY: zoomParameters.centerY
            )
        case .sharpen(let sharpenParameters):
            parameters = .sharpen(
                amount: sharpenParameters.amount,
                radius: sharpenParameters.radius
            )
        case .glow(let glowParameters):
            parameters = .glow(radius: glowParameters.radius, amount: glowParameters.amount)
        case .lut(let lutParameters):
            parameters = .lut(
                tableDigest: lutParameters.table.contentDigest,
                strength: lutParameters.strength,
                placement: lutParameters.placement
            )
        case .vignette(let vignetteParameters):
            parameters = .vignette(
                amount: vignetteParameters.amount,
                radius: vignetteParameters.radius,
                softness: vignetteParameters.softness
            )
        case .mirror(let mirrorParameters):
            parameters = .mirror(axis: mirrorParameters.axis)
        case .mosaic(let mosaicParameters):
            parameters = .mosaic(cellSize: mosaicParameters.cellSize)
        case .colorAdjust(let colorParameters):
            parameters = .colorAdjust(
                brightness: colorParameters.brightness,
                contrast: colorParameters.contrast,
                saturation: colorParameters.saturation,
                tint: colorParameters.tint
            )
        case .posterize(let posterizeParameters):
            parameters = .posterize(levels: posterizeParameters.levels)
        case .invert:
            parameters = .invert
        case .curves(let curvesParameters):
            parameters = .curves(
                rampDigest: curvesParameters.rampContentDigest,
                strength: curvesParameters.strength
            )
        }
    }
}

private enum RenderEffectParameterHash: Codable {
    case placeholder(amount: RationalValue)
    case gaussianBlur(radius: RationalValue)
    case boxBlur(radius: RationalValue)
    case zoomBlur(amount: RationalValue, centerX: RationalValue, centerY: RationalValue)
    case sharpen(amount: RationalValue, radius: RationalValue)
    case glow(radius: RationalValue, amount: RationalValue)
    case lut(tableDigest: ContentHash, strength: RationalValue, placement: ClipLUTPlacement)
    case vignette(amount: RationalValue, radius: RationalValue, softness: RationalValue)
    case mirror(axis: ClipMirrorAxis)
    case mosaic(cellSize: RationalValue)
    case colorAdjust(
        brightness: RationalValue,
        contrast: RationalValue,
        saturation: RationalValue,
        tint: RationalValue
    )
    case posterize(levels: RationalValue)
    case invert
    case curves(rampDigest: ContentHash, strength: RationalValue)
}

private struct RenderNodeHashPayload: Codable {
    let kind: RenderNodeHashKind
    let inputHashes: [ContentHash]
}
