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

/// Stable reference to a clip on a specific timeline track.
public struct ClipReference: Codable, Equatable, Hashable, Sendable {
    /// Track containing the clip.
    public let trackID: UUID

    /// Referenced clip ID.
    public let clipID: UUID

    /// Creates a clip reference.
    public init(trackID: UUID, clipID: UUID) {
        self.trackID = trackID
        self.clipID = clipID
    }
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

    /// Optional linked A/V group shared by clips that should edit together.
    public let linkGroupID: UUID?

    /// Per-clip visual transform. Audio clips keep identity unless future audio tooling needs it.
    public let transform: ClipTransform

    /// Keyframable visual transform parameters. Evaluates to `transform` when constant.
    public let transformAnimation: AnimatableClipTransform

    /// Per-clip visual effects.
    public let effects: ClipEffects

    /// Creates a timeline clip.
    public init(
        id: UUID,
        source: ClipSource,
        sourceRange: TimeRange,
        timelineRange: TimeRange,
        kind: TrackKind,
        name: String,
        linkGroupID: UUID? = nil,
        transform: ClipTransform = .identity,
        transformAnimation: AnimatableClipTransform? = nil,
        effects: ClipEffects = .none
    ) {
        self.id = id
        self.source = source
        self.sourceRange = sourceRange
        self.timelineRange = timelineRange
        self.kind = kind
        self.name = name
        self.linkGroupID = linkGroupID
        self.transform = transform
        self.transformAnimation = transformAnimation ?? .constant(transform)
        self.effects = effects
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case sourceRange
        case timelineRange
        case kind
        case name
        case linkGroupID
        case transform
        case transformAnimation
        case effects
    }

    /// Decodes clips from current and legacy project schemas.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        source = try container.decode(ClipSource.self, forKey: .source)
        sourceRange = try container.decode(TimeRange.self, forKey: .sourceRange)
        timelineRange = try container.decode(TimeRange.self, forKey: .timelineRange)
        kind = try container.decode(TrackKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        linkGroupID = try container.decodeIfPresent(UUID.self, forKey: .linkGroupID)
        transform = try container.decodeIfPresent(ClipTransform.self, forKey: .transform)
            ?? .identity
        transformAnimation = try container.decodeIfPresent(
            AnimatableClipTransform.self,
            forKey: .transformAnimation
        ) ?? .constant(transform)
        effects = try container.decodeIfPresent(ClipEffects.self, forKey: .effects) ?? .none
    }

    /// Encodes the complete clip payload.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encode(sourceRange, forKey: .sourceRange)
        try container.encode(timelineRange, forKey: .timelineRange)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(linkGroupID, forKey: .linkGroupID)
        try container.encode(transform, forKey: .transform)
        try container.encode(transformAnimation, forKey: .transformAnimation)
        try container.encode(effects, forKey: .effects)
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
