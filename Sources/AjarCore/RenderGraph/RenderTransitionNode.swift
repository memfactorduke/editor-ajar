// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Resolved two-input video transition for one sequence time (FR-FX-001 / ADR-0016 §5).
///
/// The outgoing clip's source continues past its timeline out-point over the fade-tail
/// region `[T, T + D)` (ADR-0015 vocabulary). Progress is `elapsed / duration` at the
/// sequence time; rendering is owned by the outgoing trailing record.
public struct RenderTransitionNode: Codable, Equatable, Sendable {
    /// Outgoing clip ID (tail sampling).
    public let outgoingClipID: UUID

    /// Incoming clip ID (normal sampling).
    public let incomingClipID: UUID

    /// Transition kind.
    public let kind: ClipVideoTransitionKind

    /// Normalized progress in `[0, 1]` at the requested sequence time.
    public let progress: RationalValue

    /// Dip-to-color / fade fill color.
    public let color: ClipRGBColor

    /// Direction for push / slide / wipe.
    public let direction: ClipVideoTransitionDirection

    /// Outgoing clip transform evaluated at sequence time.
    public let outgoingTransform: ClipTransform

    /// Outgoing clip effects evaluated at sequence time.
    public let outgoingEffects: ClipEffects

    /// Outgoing effect stack (nil when empty).
    public let outgoingEffectStack: ClipEffectStack?

    /// Incoming clip transform evaluated at sequence time.
    public let incomingTransform: ClipTransform

    /// Incoming clip effects evaluated at sequence time.
    public let incomingEffects: ClipEffects

    /// Incoming effect stack (nil when empty).
    public let incomingEffectStack: ClipEffectStack?

    /// Creates resolved transition node parameters.
    public init(
        outgoingClipID: UUID,
        incomingClipID: UUID,
        kind: ClipVideoTransitionKind,
        progress: RationalValue,
        color: ClipRGBColor,
        direction: ClipVideoTransitionDirection,
        outgoingTransform: ClipTransform,
        outgoingEffects: ClipEffects,
        outgoingEffectStack: ClipEffectStack?,
        incomingTransform: ClipTransform,
        incomingEffects: ClipEffects,
        incomingEffectStack: ClipEffectStack?
    ) {
        self.outgoingClipID = outgoingClipID
        self.incomingClipID = incomingClipID
        self.kind = kind
        self.progress = progress
        self.color = color
        self.direction = direction
        self.outgoingTransform = outgoingTransform
        self.outgoingEffects = outgoingEffects
        if let outgoingEffectStack, !outgoingEffectStack.nodes.isEmpty {
            self.outgoingEffectStack = outgoingEffectStack
        } else {
            self.outgoingEffectStack = nil
        }
        self.incomingTransform = incomingTransform
        self.incomingEffects = incomingEffects
        if let incomingEffectStack, !incomingEffectStack.nodes.isEmpty {
            self.incomingEffectStack = incomingEffectStack
        } else {
            self.incomingEffectStack = nil
        }
    }
}
