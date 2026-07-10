// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// FR-FX-001 video transition kinds at a cut (ADR-0016 §5).
public enum ClipVideoTransitionKind: String, Codable, Equatable, Sendable, CaseIterable {
    /// Linear cross-dissolve between outgoing and incoming frames.
    case crossDissolve
    /// Dip through a solid color (default black) at mid-progress.
    case dipToColor
    /// Fade out/in through black (same shader family as dip with fixed black).
    case fade
    /// Push: outgoing slides out as incoming slides in (direction).
    case push
    /// Slide: incoming slides over the static outgoing frame (direction).
    case slide
    /// Wipe: hard edge sweeps across the frame (linear + diagonal directions).
    case wipe
    /// Zoom: outgoing scales out while incoming scales in.
    case zoom
}

/// Direction for push / slide / wipe transitions.
///
/// Linear cases cover left/right/top/bottom; diagonal cases are wipe-only in v1
/// (push/slide reject diagonal with a typed validation error).
///
/// ## Push / slide motion (matches `ajar_transition_push_offset` in MSL)
///
/// The shader offsets sample UVs; positive UV shift moves the **image** opposite the
/// offset. Named cases describe the **wipe/push axis label**, not the apparent travel
/// of the outgoing frame:
///
/// - ``left``: outgoing shifts **right**; for push/slide the incoming enters from the
///   **right** (outgoing UV offset `(-t, 0)`).
/// - ``right``: outgoing shifts **left**; incoming enters from the **left**
///   (offset `(+t, 0)`).
/// - ``top``: outgoing shifts **down**; incoming enters from the **bottom**
///   (offset `(0, -t)` in UV-y where 0 is top).
/// - ``bottom``: outgoing shifts **up**; incoming enters from the **top**
///   (offset `(0, +t)`).
///
/// Wipe uses the same codes as an edge mask (``.left`` = left→right reveal of the
/// incoming frame), not a UV slide.
public enum ClipVideoTransitionDirection: String, Codable, Equatable, Sendable, CaseIterable {
    /// Push/slide: rightward image motion; incoming enters from the right.
    case left
    /// Push/slide: leftward image motion; incoming enters from the left.
    case right
    /// Push/slide: downward image motion; incoming enters from the bottom.
    case top
    /// Push/slide: upward image motion; incoming enters from the top.
    case bottom
    /// Wipe only: reveal progressing from the top-left corner.
    case topLeft
    /// Wipe only: reveal progressing from the top-right corner.
    case topRight
    /// Wipe only: reveal progressing from the bottom-left corner.
    case bottomLeft
    /// Wipe only: reveal progressing from the bottom-right corner.
    case bottomRight

    /// True for the four cardinal directions.
    public var isLinear: Bool {
        switch self {
        case .left, .right, .top, .bottom:
            true
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            false
        }
    }

    /// True for the four diagonal wipe directions.
    public var isDiagonal: Bool {
        !isLinear
    }
}

/// Which edge of a clip carries a video transition record (mirrors `ClipAudioFadeEdge`).
public enum ClipVideoTransitionEdge: String, Codable, Equatable, Sendable {
    /// Transition from the previous abutting clip into this clip (mirror side).
    case leading
    /// Transition from this clip into the next abutting clip (render-owning side).
    case trailing
}

/// Cut-edge video transition metadata (FR-FX-001 / ADR-0016 §5).
///
/// Parallel to `ClipAudioCrossfade`: one transition per cut, owned by the outgoing
/// clip's trailing record with the incoming clip's leading record as a non-rendering
/// mirror. Pair agreement requires identical kind, duration, and parameters on both
/// edges. Sequence duration is unchanged when a transition is added, adjusted, or
/// removed — the fade-tail model reuses ADR-0015 vocabulary.
public struct ClipVideoTransition: Codable, Equatable, Sendable {
    /// Adjacent clip that participates in the transition.
    public let partnerClipID: UUID

    /// Transition duration in exact timeline time.
    public let duration: RationalTime

    /// Transition kind.
    public let kind: ClipVideoTransitionKind

    /// Dip-to-color fill (also the implicit black for `.fade`). Defaults to black.
    public let color: ClipRGBColor

    /// Direction for push / slide / wipe. Defaults to `.left`.
    public let direction: ClipVideoTransitionDirection

    /// Creates cut-edge transition metadata.
    public init(
        partnerClipID: UUID,
        duration: RationalTime,
        kind: ClipVideoTransitionKind,
        color: ClipRGBColor = ClipRGBColor(red: .zero, green: .zero, blue: .zero),
        direction: ClipVideoTransitionDirection = .left
    ) {
        self.partnerClipID = partnerClipID
        self.duration = duration
        self.kind = kind
        self.color = color
        self.direction = direction
    }

    private enum CodingKeys: String, CodingKey {
        case partnerClipID
        case duration
        case kind
        case color
        case direction
    }

    /// Decodes with `decodeIfPresent` defaults so additive fields stay legacy-safe.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        partnerClipID = try container.decode(UUID.self, forKey: .partnerClipID)
        duration = try container.decode(RationalTime.self, forKey: .duration)
        kind = try container.decode(ClipVideoTransitionKind.self, forKey: .kind)
        color =
            try container.decodeIfPresent(ClipRGBColor.self, forKey: .color)
            ?? ClipRGBColor(red: .zero, green: .zero, blue: .zero)
        direction =
            try container.decodeIfPresent(ClipVideoTransitionDirection.self, forKey: .direction)
            ?? .left
    }

    /// Encodes the full transition payload.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(partnerClipID, forKey: .partnerClipID)
        try container.encode(duration, forKey: .duration)
        try container.encode(kind, forKey: .kind)
        try container.encode(color, forKey: .color)
        try container.encode(direction, forKey: .direction)
    }

    /// True when `other` agrees on kind, duration, and parameters (pair agreement).
    public func agrees(with other: ClipVideoTransition) -> Bool {
        duration == other.duration
            && kind == other.kind
            && color == other.color
            && direction == other.direction
    }
}
