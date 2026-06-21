// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Timeline track kind.
public enum TrackKind: String, Codable, Equatable, Sendable {
    /// Video/composited visual track.
    case video

    /// Audio/mix track.
    case audio
}

/// A timeline track with sorted, non-overlapping items.
public struct Track: Codable, Equatable, Sendable {
    /// Stable track ID.
    public let id: UUID

    /// Track kind.
    public let kind: TrackKind

    /// Timeline items for this track. Validation enforces sorted, non-overlapping ranges.
    public let items: [TimelineItem]

    /// Whether the track participates in playback/rendering.
    public let enabled: Bool

    /// Whether edits are prevented on this track.
    public let locked: Bool

    /// Whether audio is muted. Meaningful for audio tracks.
    public let muted: Bool

    /// Whether this audio track is soloed. Meaningful for audio tracks.
    public let solo: Bool

    /// Whether video is hidden. Meaningful for video tracks.
    public let hidden: Bool

    /// Creates a timeline track.
    public init(
        id: UUID,
        kind: TrackKind,
        items: [TimelineItem],
        enabled: Bool = true,
        locked: Bool = false,
        muted: Bool = false,
        solo: Bool = false,
        hidden: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.items = items
        self.enabled = enabled
        self.locked = locked
        self.muted = muted
        self.solo = solo
        self.hidden = hidden
    }
}

/// An item on a timeline track.
public enum TimelineItem: Codable, Equatable, Sendable {
    /// A clip with a source and timeline range.
    case clip(Clip)

    /// Empty timeline space. A gap can appear on either track kind.
    case gap(TimeRange)

    /// A thin transition placeholder for later timeline editing work.
    case transition(Transition)

    /// The item's timeline range.
    public var timelineRange: TimeRange {
        switch self {
        case .clip(let clip):
            clip.timelineRange
        case .gap(let range):
            range
        case .transition(let transition):
            transition.timelineRange
        }
    }

    /// The item kind when the item is kind-specific.
    public var kind: TrackKind? {
        switch self {
        case .clip(let clip):
            clip.kind
        case .gap:
            nil
        case .transition(let transition):
            transition.kind
        }
    }
}

/// A clip source. Sequence references reserve schema space for future compound clips.
public enum ClipSource: Codable, Equatable, Sendable {
    /// A clip backed by an imported media reference.
    case media(id: UUID)

    /// A future compound clip backed by another sequence. Cycle validation lands with M7.
    case sequence(id: UUID)
}

/// A media or future compound clip placed on a timeline.
public struct Clip: Codable, Equatable, Sendable {
    /// Stable clip ID.
    public let id: UUID

    /// Clip source.
    public let source: ClipSource

    /// Source media range.
    public let sourceRange: TimeRange

    /// Timeline placement.
    public let timelineRange: TimeRange

    /// Track kind required for this clip.
    public let kind: TrackKind

    /// Human-readable clip name.
    public let name: String

    /// Creates a timeline clip.
    public init(
        id: UUID,
        source: ClipSource,
        sourceRange: TimeRange,
        timelineRange: TimeRange,
        kind: TrackKind,
        name: String
    ) {
        self.id = id
        self.source = source
        self.sourceRange = sourceRange
        self.timelineRange = timelineRange
        self.kind = kind
        self.name = name
    }
}

/// A minimal transition placeholder.
public struct Transition: Codable, Equatable, Sendable {
    /// Stable transition ID.
    public let id: UUID

    /// Timeline placement.
    public let timelineRange: TimeRange

    /// Track kind required for this transition.
    public let kind: TrackKind

    /// Human-readable transition name.
    public let name: String

    /// Creates a transition placeholder.
    public init(id: UUID, timelineRange: TimeRange, kind: TrackKind, name: String) {
        self.id = id
        self.timelineRange = timelineRange
        self.kind = kind
        self.name = name
    }
}
