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

    /// Track-level opacity, evaluated at render time for video compositing.
    ///
    /// The current renderer can multiply this with clip opacity because project validation keeps
    /// timeline items non-overlapping inside a track. Future intra-track overlap must isolate the
    /// track before blending it over lower tracks.
    public let opacity: Animatable<RationalValue>

    /// Track-level blend mode for compositing this track onto lower video tracks.
    ///
    /// A non-normal track blend mode currently takes precedence over the selected clip's blend
    /// mode. This is exact while one active clip per track is enforced; future intra-track stacking
    /// will need separate clip-then-track blend stages.
    public let blendMode: ClipBlendMode

    /// Track-level keyframable linear audio gain. Meaningful for audio tracks.
    public let audioGain: Animatable<RationalValue>

    /// Track-level keyframable audio pan. Meaningful for audio tracks.
    public let audioPan: Animatable<RationalValue>

    /// Creates a timeline track.
    public init(
        id: UUID,
        kind: TrackKind,
        items: [TimelineItem],
        enabled: Bool = true,
        locked: Bool = false,
        muted: Bool = false,
        solo: Bool = false,
        hidden: Bool = false,
        opacity: Animatable<RationalValue> = .constant(.one),
        blendMode: ClipBlendMode = .normal,
        audioGain: Animatable<RationalValue> = .constant(.one),
        audioPan: Animatable<RationalValue> = .constant(.zero)
    ) {
        self.id = id
        self.kind = kind
        self.items = items
        self.enabled = enabled
        self.locked = locked
        self.muted = muted
        self.solo = solo
        self.hidden = hidden
        self.opacity = opacity
        self.blendMode = blendMode
        self.audioGain = audioGain
        self.audioPan = audioPan
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case items
        case enabled
        case locked
        case muted
        case solo
        case hidden
        case opacity
        case blendMode
        case audioGain
        case audioPan
    }

    /// Decodes tracks from current and legacy project schemas.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(TrackKind.self, forKey: .kind)
        items = try container.decode([TimelineItem].self, forKey: .items)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        solo = try container.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        opacity =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .opacity
            ) ?? .constant(.one)
        blendMode =
            try container.decodeIfPresent(ClipBlendMode.self, forKey: .blendMode)
            ?? .normal
        audioGain =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .audioGain
            ) ?? .constant(.one)
        audioPan =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .audioPan
            ) ?? .constant(.zero)
    }

    /// Encodes the complete track payload.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(items, forKey: .items)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(locked, forKey: .locked)
        try container.encode(muted, forKey: .muted)
        try container.encode(solo, forKey: .solo)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(blendMode, forKey: .blendMode)
        try container.encode(audioGain, forKey: .audioGain)
        try container.encode(audioPan, forKey: .audioPan)
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

/// A clip source.
public enum ClipSource: Codable, Equatable, Sendable {
    /// A clip backed by an imported media reference.
    case media(id: UUID)

    /// A compound clip backed by another sequence in the same project.
    case sequence(id: UUID)

    /// A title generator clip (FR-TXT-001, ADR-0017). No media-pool entry is required.
    case title(TitleSource)
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

/// A media or compound clip placed on a timeline.
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

    /// Keyframable visual effects. Evaluates to `effects` when constant.
    public let effectsAnimation: AnimatableClipEffects

    /// Ordered per-clip video effects stack (FR-FX-003, ADR-0016). Empty by default.
    public let effectStack: ClipEffectStack

    /// Keyframable effects stack. Evaluates to `effectStack` when constant.
    public let effectStackAnimation: AnimatableClipEffectStack

    /// Per-clip audio automation and fade metadata.
    public let audioMix: ClipAudioMix

    /// Constant-rate playback speed. `1/1` is normal speed; values above one are faster.
    public let speed: RationalValue

    /// Whether this clip maps timeline time backward through its source range.
    public let reverse: Bool

    /// Whether this clip holds its source range start for every rendered timeline time.
    public let freezeFrame: Bool

    /// Optional FR-SPD-002 keyframed time-remap curve. Absent means constant-rate playback.
    public let timeRemap: ClipTimeRemap?

    /// FR-SPD-004 source frame sampling mode. `nearest` preserves single-frame decoding;
    /// `frameBlend` opts a media-backed clip into fractional-position frame blending.
    public let frameSampling: ClipFrameSamplingMode

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
        effects: ClipEffects = .none,
        effectsAnimation: AnimatableClipEffects? = nil,
        effectStack: ClipEffectStack = .empty,
        effectStackAnimation: AnimatableClipEffectStack? = nil,
        audioMix: ClipAudioMix = .identity,
        speed: RationalValue = .one,
        reverse: Bool = false,
        freezeFrame: Bool = false,
        timeRemap: ClipTimeRemap? = nil,
        frameSampling: ClipFrameSamplingMode = .nearest
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
        self.effectsAnimation = effectsAnimation ?? .constant(effects)
        self.effectStack = effectStack
        self.effectStackAnimation = effectStackAnimation ?? .constant(effectStack)
        self.audioMix = audioMix
        self.speed = speed
        self.reverse = reverse
        self.freezeFrame = freezeFrame
        self.timeRemap = timeRemap
        self.frameSampling = frameSampling
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
        case effectsAnimation
        case effectStack
        case effectStackAnimation
        case audioMix
        case speed
        case reverse
        case freezeFrame
        case timeRemap
        case frameSampling
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
        transform =
            try container.decodeIfPresent(ClipTransform.self, forKey: .transform)
            ?? .identity
        transformAnimation =
            try container.decodeIfPresent(
                AnimatableClipTransform.self,
                forKey: .transformAnimation
            ) ?? .constant(transform)
        effects = try container.decodeIfPresent(ClipEffects.self, forKey: .effects) ?? .none
        effectsAnimation = try container.decodeIfPresent(
            AnimatableClipEffects.self,
            forKey: .effectsAnimation
        ) ?? .constant(effects)
        effectStack = try container.decodeIfPresent(
            ClipEffectStack.self,
            forKey: .effectStack
        ) ?? .empty
        effectStackAnimation = try container.decodeIfPresent(
            AnimatableClipEffectStack.self,
            forKey: .effectStackAnimation
        ) ?? .constant(effectStack)
        audioMix = try container.decodeIfPresent(ClipAudioMix.self, forKey: .audioMix)
            ?? .identity
        speed = try container.decodeIfPresent(RationalValue.self, forKey: .speed) ?? .one
        reverse = try container.decodeIfPresent(Bool.self, forKey: .reverse) ?? false
        freezeFrame = try container.decodeIfPresent(Bool.self, forKey: .freezeFrame) ?? false
        timeRemap = try container.decodeIfPresent(ClipTimeRemap.self, forKey: .timeRemap)
        frameSampling =
            try container.decodeIfPresent(
                ClipFrameSamplingMode.self,
                forKey: .frameSampling
            ) ?? .nearest
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
        try container.encode(effectsAnimation, forKey: .effectsAnimation)
        try container.encode(effectStack, forKey: .effectStack)
        try container.encode(effectStackAnimation, forKey: .effectStackAnimation)
        try container.encode(audioMix, forKey: .audioMix)
        try container.encode(speed, forKey: .speed)
        try container.encode(reverse, forKey: .reverse)
        try container.encode(freezeFrame, forKey: .freezeFrame)
        try container.encodeIfPresent(timeRemap, forKey: .timeRemap)
        try container.encode(frameSampling, forKey: .frameSampling)
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
