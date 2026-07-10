// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Static parameters for the placeholder effect kind.
///
/// `amount` is a normalized 0...1 control; zero is a documented no-op identity for the kind.
public struct ClipPlaceholderEffectParameters: Codable, Equatable, Sendable {
    /// Normalized amount in 0...1. Zero is identity for this kind.
    public let amount: RationalValue

    private enum CodingKeys: String, CodingKey {
        case amount
    }

    /// Identity parameters (no-op amount).
    public static let identity = ClipPlaceholderEffectParameters(amount: .zero)

    /// Creates placeholder parameters.
    public init(amount: RationalValue = .zero) {
        self.amount = amount
    }

    /// Decodes placeholder parameters with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount = try container.decodeIfPresent(RationalValue.self, forKey: .amount) ?? .zero
    }
}

/// Keyframable parameters for the placeholder effect kind.
public struct AnimatableClipPlaceholderSettings: Codable, Equatable, Sendable {
    /// Keyframable normalized amount.
    public let amount: Animatable<RationalValue>

    private enum CodingKeys: String, CodingKey {
        case amount
    }

    /// Identity parameters (constant zero amount).
    public static let identity = AnimatableClipPlaceholderSettings(amount: .constant(.zero))

    /// Creates keyframable placeholder parameters.
    public init(amount: Animatable<RationalValue> = .constant(.zero)) {
        self.amount = amount
    }

    /// Decodes keyframable placeholder parameters with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .amount
            ) ?? .constant(.zero)
    }

    /// Creates keyframable parameters with constant values.
    public static func constant(
        _ parameters: ClipPlaceholderEffectParameters
    ) -> AnimatableClipPlaceholderSettings {
        AnimatableClipPlaceholderSettings(amount: .constant(parameters.amount))
    }

    /// Evaluates parameters at a sequence time.
    public func value(at time: RationalTime) -> ClipPlaceholderEffectParameters {
        ClipPlaceholderEffectParameters(amount: amount.value(at: time))
    }

    /// Static parameters represented by base keyframe values.
    public var baseParameters: ClipPlaceholderEffectParameters {
        ClipPlaceholderEffectParameters(amount: amount.base)
    }
}

/// One node in a per-clip ordered video effects stack (FR-FX-003, ADR-0016).
public struct ClipEffectNode: Codable, Equatable, Sendable {
    /// Stable node ID for edit commands and reorder.
    public let id: UUID

    /// Whether this node participates in rendering when the stack is evaluated.
    public let enabled: Bool

    /// Typed kind + parameters.
    public let definition: ClipEffectDefinition

    private enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case definition
    }

    /// Creates an effect node.
    public init(id: UUID, enabled: Bool = true, definition: ClipEffectDefinition) {
        self.id = id
        self.enabled = enabled
        self.definition = definition
    }

    /// Decodes an effect node with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        definition = try container.decode(ClipEffectDefinition.self, forKey: .definition)
    }

    /// Kind identity.
    public var kind: ClipEffectKind {
        definition.kind
    }

    /// Returns a node with replacement enabled state.
    public func replacing(enabled: Bool) -> ClipEffectNode {
        ClipEffectNode(id: id, enabled: enabled, definition: definition)
    }

    /// Returns a node with replacement definition (must match existing kind).
    public func replacing(definition: ClipEffectDefinition) -> ClipEffectNode {
        ClipEffectNode(id: id, enabled: enabled, definition: definition)
    }
}

/// Keyframable effect node.
public struct AnimatableClipEffectNode: Codable, Equatable, Sendable {
    /// Stable node ID for edit commands and reorder.
    public let id: UUID

    /// Whether this node participates in rendering when the stack is evaluated.
    public let enabled: Bool

    /// Keyframable kind + parameters.
    public let definition: AnimatableClipEffectDefinition

    private enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case definition
    }

    /// Creates a keyframable effect node.
    public init(id: UUID, enabled: Bool = true, definition: AnimatableClipEffectDefinition) {
        self.id = id
        self.enabled = enabled
        self.definition = definition
    }

    /// Decodes a keyframable effect node with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        definition = try container.decode(
            AnimatableClipEffectDefinition.self,
            forKey: .definition
        )
    }

    /// Kind identity.
    public var kind: ClipEffectKind {
        definition.kind
    }

    /// Creates a keyframable node with constant parameters.
    public static func constant(_ node: ClipEffectNode) -> AnimatableClipEffectNode {
        AnimatableClipEffectNode(
            id: node.id,
            enabled: node.enabled,
            definition: .constant(node.definition)
        )
    }

    /// Evaluates the node at a sequence time.
    public func value(at time: RationalTime) -> ClipEffectNode {
        ClipEffectNode(
            id: id,
            enabled: enabled,
            definition: definition.value(at: time)
        )
    }

    /// Static node represented by base keyframe values.
    public var baseNode: ClipEffectNode {
        ClipEffectNode(
            id: id,
            enabled: enabled,
            definition: definition.baseDefinition
        )
    }

    /// Returns a node with replacement enabled state.
    public func replacing(enabled: Bool) -> AnimatableClipEffectNode {
        AnimatableClipEffectNode(id: id, enabled: enabled, definition: definition)
    }

    /// Returns a node with replacement static definition (constant animation).
    public func replacing(definition: ClipEffectDefinition) -> AnimatableClipEffectNode {
        AnimatableClipEffectNode(
            id: id,
            enabled: enabled,
            definition: .constant(definition)
        )
    }
}

/// Ordered per-clip video effects stack (FR-FX-003, ADR-0016).
public struct ClipEffectStack: Codable, Equatable, Sendable {
    /// Effect nodes in application order (index 0 is applied first).
    public let nodes: [ClipEffectNode]

    private enum CodingKeys: String, CodingKey {
        case nodes
    }

    /// Empty stack.
    public static let empty = ClipEffectStack(nodes: [])

    /// Creates a stack.
    public init(nodes: [ClipEffectNode] = []) {
        self.nodes = nodes
    }

    /// Decodes a stack with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decodeIfPresent([ClipEffectNode].self, forKey: .nodes) ?? []
    }

    /// Returns a stack with replacement nodes.
    public func replacing(nodes: [ClipEffectNode]) -> ClipEffectStack {
        ClipEffectStack(nodes: nodes)
    }

    /// Ordered FR-COL-007 color-grade subset of this effect stack.
    public var grade: ClipEffectStack {
        ClipEffectStack(nodes: nodes.filter { $0.kind.isColorGrade })
    }

    /// Replaces this stack's color-grade nodes while preserving every non-color node in order.
    ///
    /// The replacement is inserted contiguously where the first old grade node appeared. If this
    /// stack had no grade, the replacement is appended. Only color-grade nodes from `grade` are
    /// inserted; callers assign fresh node IDs before invoking this helper.
    public func replacingGrade(with grade: ClipEffectStack) -> ClipEffectStack {
        let replacementNodes = grade.grade.nodes
        guard let firstGradeIndex = nodes.firstIndex(where: { $0.kind.isColorGrade }) else {
            return ClipEffectStack(nodes: nodes + replacementNodes)
        }

        let insertionIndex = nodes[..<firstGradeIndex].filter { !$0.kind.isColorGrade }.count
        var preservedNodes = nodes.filter { !$0.kind.isColorGrade }
        preservedNodes.insert(contentsOf: replacementNodes, at: insertionIndex)
        return ClipEffectStack(nodes: preservedNodes)
    }
}

/// Keyframable ordered per-clip video effects stack.
public struct AnimatableClipEffectStack: Codable, Equatable, Sendable {
    /// Keyframable effect nodes in application order.
    public let nodes: [AnimatableClipEffectNode]

    private enum CodingKeys: String, CodingKey {
        case nodes
    }

    /// Empty stack.
    public static let empty = AnimatableClipEffectStack(nodes: [])

    /// Creates a keyframable stack.
    public init(nodes: [AnimatableClipEffectNode] = []) {
        self.nodes = nodes
    }

    /// Decodes a keyframable stack with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes =
            try container.decodeIfPresent(
                [AnimatableClipEffectNode].self,
                forKey: .nodes
            ) ?? []
    }

    /// Creates a keyframable stack with constant node parameters.
    public static func constant(_ stack: ClipEffectStack) -> AnimatableClipEffectStack {
        AnimatableClipEffectStack(nodes: stack.nodes.map(AnimatableClipEffectNode.constant))
    }

    /// Evaluates the stack at a sequence time.
    public func value(at time: RationalTime) -> ClipEffectStack {
        ClipEffectStack(nodes: nodes.map { node in node.value(at: time) })
    }

    /// Static stack represented by base keyframe values.
    public var baseStack: ClipEffectStack {
        ClipEffectStack(nodes: nodes.map(\.baseNode))
    }

    /// Returns a stack with replacement nodes.
    public func replacing(nodes: [AnimatableClipEffectNode]) -> AnimatableClipEffectStack {
        AnimatableClipEffectStack(nodes: nodes)
    }

    /// Replaces animation for nodes whose static snapshot changed, preserving others.
    ///
    /// Enable-only changes keep the existing keyframed definition (ADR-0016 §2: toggling
    /// enable must not invent or destroy keyframes). Definition changes constant-replace
    /// that node's parameters while applying the new enabled flag.
    public func replacingChangedNodes(
        from oldStack: ClipEffectStack,
        to newStack: ClipEffectStack
    ) -> AnimatableClipEffectStack {
        let oldByID = Dictionary(uniqueKeysWithValues: oldStack.nodes.map { ($0.id, $0) })
        let existingByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let replaced = newStack.nodes.map { newNode -> AnimatableClipEffectNode in
            replacementAnimatedNode(
                for: newNode,
                oldByID: oldByID,
                existingByID: existingByID
            )
        }
        return AnimatableClipEffectStack(nodes: replaced)
    }

    private func replacementAnimatedNode(
        for newNode: ClipEffectNode,
        oldByID: [UUID: ClipEffectNode],
        existingByID: [UUID: AnimatableClipEffectNode]
    ) -> AnimatableClipEffectNode {
        // Fully unchanged static node: keep the existing animation as-is.
        if let oldNode = oldByID[newNode.id], oldNode == newNode {
            if let existing = existingByID[newNode.id] {
                return existing
            }
        }
        // Same kind: preserve keyframes when only enabled (or other non-definition fields)
        // change; constant-replace definition only when parameters actually changed.
        guard let existing = existingByID[newNode.id], existing.kind == newNode.kind else {
            return .constant(newNode)
        }
        if existing.definition.baseDefinition == newNode.definition {
            return existing.replacing(enabled: newNode.enabled)
        }
        return AnimatableClipEffectNode(
            id: newNode.id,
            enabled: newNode.enabled,
            definition: .constant(newNode.definition)
        )
    }
}

/// Typed validation failures for the per-clip effects stack (FR-FX-002, FR-FX-003).
public enum ClipEffectStackValidationError: Equatable, Sendable {
    /// Two nodes share the same stable ID.
    case duplicateEffectNodeID(UUID)

    /// A placeholder amount is outside the normalized 0...1 range.
    case placeholderAmountOutOfRange(RationalValue)

    /// A Gaussian blur radius is outside 0...64.
    case gaussianBlurRadiusOutOfRange(RationalValue)

    /// A box blur radius is outside 0...16 (single-pass tap budget).
    case boxBlurRadiusOutOfRange(RationalValue)

    /// A zoom blur amount is outside the normalized 0...1 range.
    case zoomBlurAmountOutOfRange(RationalValue)

    /// A zoom blur center component is outside the normalized 0...1 range.
    case zoomBlurCenterOutOfRange(axis: ClipEffectCenterAxis, value: RationalValue)

    /// A sharpen amount is outside the normalized 0...1 range.
    case sharpenAmountOutOfRange(RationalValue)

    /// A sharpen radius is outside 0...8.
    case sharpenRadiusOutOfRange(RationalValue)

    /// A glow radius is outside 0...64.
    case glowRadiusOutOfRange(RationalValue)

    /// A glow amount is outside the normalized 0...1 range.
    case glowAmountOutOfRange(RationalValue)

    /// A LUT strength is outside the normalized 0...1 range (FR-COL-004).
    case lutStrengthOutOfRange(RationalValue)

    /// The inline LUT table failed size/entry validation (FR-COL-004 payload ceiling).
    case lutTableInvalid(CubeLUTValidationError)

    /// A vignette amount is outside the normalized 0...1 range.
    case vignetteAmountOutOfRange(RationalValue)

    /// A vignette radius is outside the normalized 0...1 range.
    case vignetteRadiusOutOfRange(RationalValue)

    /// A vignette softness is outside the normalized 0...1 range.
    case vignetteSoftnessOutOfRange(RationalValue)

    /// A mosaic cell size is outside 1...256 source pixels.
    case mosaicCellSizeOutOfRange(RationalValue)

    /// Color-adjust brightness is outside -1...1.
    case colorAdjustBrightnessOutOfRange(RationalValue)

    /// Color-adjust contrast is outside 0...4.
    case colorAdjustContrastOutOfRange(RationalValue)

    /// Color-adjust saturation is outside 0...4.
    case colorAdjustSaturationOutOfRange(RationalValue)

    /// Color-adjust tint is outside -1...1.
    case colorAdjustTintOutOfRange(RationalValue)

    /// Posterize levels are outside 2...256.
    case posterizeLevelsOutOfRange(RationalValue)

    /// A curves strength is outside the normalized 0...1 range (FR-COL-002).
    case curvesStrengthOutOfRange(RationalValue)

    /// One of the RGB/master curves failed validation (FR-COL-002).
    case curvesInvalid(channel: ColorCurveChannel, error: ColorCurveValidationError)

    /// A set-parameter edit changed the node's kind.
    case effectNodeKindMismatch(
        nodeID: UUID,
        expected: ClipEffectKind,
        actual: ClipEffectKind
    )

    /// The static stack snapshot does not match `effectStackAnimation`'s base values
    /// (node IDs, order, kinds, enabled flags, and base parameter values).
    case staticAnimationParityMismatch
}

/// Axis label for zoom-blur center validation errors.
public enum ClipEffectCenterAxis: String, Equatable, Sendable {
    /// Horizontal center (normalized UV x).
    case x

    /// Vertical center (normalized UV y).
    case y
}
