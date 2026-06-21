// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A timeline sequence containing video and audio tracks.
public struct Sequence: Codable, Equatable, Sendable {
    /// Stable sequence ID.
    public let id: UUID

    /// Human-readable sequence name.
    public let name: String

    /// Video tracks. Index `0` is the bottom of the composite stack; later tracks render above it.
    public let videoTracks: [Track]

    /// Audio tracks mixed by track order.
    public let audioTracks: [Track]

    /// Timeline markers.
    public let markers: [Marker]

    /// Sequence timebase.
    public let timebase: FrameRate

    /// Creates a timeline sequence.
    public init(
        id: UUID,
        name: String,
        videoTracks: [Track],
        audioTracks: [Track],
        markers: [Marker],
        timebase: FrameRate
    ) {
        self.id = id
        self.name = name
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.markers = markers
        self.timebase = timebase
    }
}

/// User-facing marker color token.
public enum MarkerColor: String, Codable, CaseIterable, Equatable, Sendable {
    /// Neutral gray marker.
    case gray

    /// Red marker.
    case red

    /// Orange marker.
    case orange

    /// Yellow marker.
    case yellow

    /// Green marker.
    case green

    /// Blue marker.
    case blue

    /// Purple marker.
    case purple
}

/// Where a marker is anchored.
public enum MarkerAnchor: Codable, Equatable, Sendable {
    /// Marker belongs directly to the sequence timeline.
    case timeline

    /// Marker is associated with a clip on a specific track.
    case clip(trackID: UUID, clipID: UUID)
}

/// A marker attached to a sequence timeline or clip.
public struct Marker: Codable, Equatable, Sendable {
    /// Stable marker ID.
    public let id: UUID

    /// Marker time in sequence coordinates.
    public let time: RationalTime

    /// Human-readable marker name.
    public let name: String

    /// User-facing marker color token.
    public let color: MarkerColor

    /// Free-form marker notes.
    public let note: String

    /// Timeline or clip anchor for this marker.
    public let anchor: MarkerAnchor

    /// Creates a marker.
    public init(
        id: UUID,
        time: RationalTime,
        name: String,
        color: MarkerColor = .blue,
        note: String = "",
        anchor: MarkerAnchor = .timeline
    ) {
        self.id = id
        self.time = time
        self.name = name
        self.color = color
        self.note = note
        self.anchor = anchor
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case time
        case name
        case color
        case note
        case anchor
    }

    /// Decodes a marker, defaulting fields added after the initial marker schema.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        time = try container.decode(RationalTime.self, forKey: .time)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decodeIfPresent(MarkerColor.self, forKey: .color) ?? .blue
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        anchor = try container.decodeIfPresent(MarkerAnchor.self, forKey: .anchor) ?? .timeline
    }

    /// Encodes the complete marker payload.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(time, forKey: .time)
        try container.encode(name, forKey: .name)
        try container.encode(color, forKey: .color)
        try container.encode(note, forKey: .note)
        try container.encode(anchor, forKey: .anchor)
    }
}
