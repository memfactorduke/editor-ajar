// SPDX-License-Identifier: GPL-3.0-or-later

/// Whether an edit should propagate through linked clip groups.
public enum LinkedClipEditMode: String, Codable, Equatable, Sendable {
    /// Apply the same compatible edit to linked partner clips.
    case linked

    /// Edit only the addressed clip, used by momentary unlink gestures.
    case unlinked
}

/// Optional track-state fields changed by `EditCommand.setTrackState`.
public struct TrackStatePatch: Codable, Equatable, Sendable {
    /// Replacement enabled state, or `nil` to leave it unchanged.
    public let enabled: Bool?

    /// Replacement locked state, or `nil` to leave it unchanged.
    public let locked: Bool?

    /// Replacement muted state, or `nil` to leave it unchanged.
    public let muted: Bool?

    /// Replacement solo state, or `nil` to leave it unchanged.
    public let solo: Bool?

    /// Replacement hidden state, or `nil` to leave it unchanged.
    public let hidden: Bool?

    /// Creates a track-state patch.
    public init(
        enabled: Bool? = nil,
        locked: Bool? = nil,
        muted: Bool? = nil,
        solo: Bool? = nil,
        hidden: Bool? = nil
    ) {
        self.enabled = enabled
        self.locked = locked
        self.muted = muted
        self.solo = solo
        self.hidden = hidden
    }
}

/// Optional track-compositing fields changed by `EditCommand.setTrackCompositing`.
public struct TrackCompositingPatch: Codable, Equatable, Sendable {
    /// Replacement track opacity animation, or `nil` to leave it unchanged.
    public let opacity: Animatable<RationalValue>?

    /// Replacement track blend mode, or `nil` to leave it unchanged.
    public let blendMode: ClipBlendMode?

    /// Creates a track-compositing patch.
    public init(
        opacity: Animatable<RationalValue>? = nil,
        blendMode: ClipBlendMode? = nil
    ) {
        self.opacity = opacity
        self.blendMode = blendMode
    }
}
