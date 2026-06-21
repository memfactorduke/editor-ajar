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

/// A marker attached to a sequence timeline.
public struct Marker: Codable, Equatable, Sendable {
    /// Stable marker ID.
    public let id: UUID

    /// Marker time in sequence coordinates.
    public let time: RationalTime

    /// Human-readable marker name.
    public let name: String

    /// Creates a timeline marker.
    public init(id: UUID, time: RationalTime, name: String) {
        self.id = id
        self.time = time
        self.name = name
    }
}
