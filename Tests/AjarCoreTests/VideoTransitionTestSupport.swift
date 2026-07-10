// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// Shared fixture builders for ADR-0016 §5 video transition tests (FR-FX-001).
enum VideoTransitionFixtureID {
    static func media() throws -> UUID { try editUUID(910_001) }
    static func sequence() throws -> UUID { try editUUID(910_002) }
    static func track() throws -> UUID { try editUUID(910_003) }
    static func outgoingClip() throws -> UUID { try editUUID(910_005) }
    static func incomingClip() throws -> UUID { try editUUID(910_006) }
    static func extraClip() throws -> UUID { try editUUID(910_007) }
    static func stalePartner() throws -> UUID { try editUUID(910_008) }
}

struct VideoTransitionClipSpec {
    var sourceStartFrame: Int64 = 0
    var timelineStartFrame: Int64 = 0
    var sourceDurationFrames: Int64 = 10
    var leadingTransition: ClipVideoTransition?
    var trailingTransition: ClipVideoTransition?
    var speed: RationalValue = .one
    var reverse = false
    var freezeFrame = false
    var timeRemap: ClipTimeRemap?
}

func makeVideoTransitionClip(id: UUID, spec: VideoTransitionClipSpec) throws -> Clip {
    let sourceDuration = try editTime(spec.sourceDurationFrames)
    let timelineDuration: RationalTime
    if let timeRemap = spec.timeRemap {
        timelineDuration = timeRemap.duration
    } else {
        timelineDuration = try Clip.timelineDuration(
            forSourceDuration: sourceDuration,
            speed: spec.speed
        )
    }
    return Clip(
        id: id,
        source: .media(id: try VideoTransitionFixtureID.media()),
        sourceRange: try TimeRange(
            start: editTime(spec.sourceStartFrame),
            duration: sourceDuration
        ),
        timelineRange: try TimeRange(
            start: editTime(spec.timelineStartFrame),
            duration: timelineDuration
        ),
        kind: .video,
        name: "Transition clip \(id.uuidString)",
        leadingTransition: spec.leadingTransition,
        trailingTransition: spec.trailingTransition,
        speed: spec.speed,
        reverse: spec.reverse,
        freezeFrame: spec.freezeFrame,
        timeRemap: spec.timeRemap
    )
}

func makeVideoTransitionProject(items: [TimelineItem]) throws -> Project {
    let media = try makeEditMediaRef(id: VideoTransitionFixtureID.media())
    let track = Track(id: try VideoTransitionFixtureID.track(), kind: .video, items: items)
    let sequence = Sequence(
        id: try VideoTransitionFixtureID.sequence(),
        name: "Transition sequence",
        videoTracks: [track],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 1_920, height: 1_080),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [media],
        sequences: [sequence]
    )
}

func makeTrailingTransition(
    partner: UUID,
    durationFrames: Int64 = 4,
    kind: ClipVideoTransitionKind = .crossDissolve,
    color: ClipRGBColor = ClipRGBColor(red: .zero, green: .zero, blue: .zero),
    direction: ClipVideoTransitionDirection = .left
) throws -> ClipVideoTransition {
    ClipVideoTransition(
        partnerClipID: partner,
        duration: try editTime(durationFrames),
        kind: kind,
        color: color,
        direction: direction
    )
}

func makeLeadingTransition(
    partner: UUID,
    durationFrames: Int64 = 4,
    kind: ClipVideoTransitionKind = .crossDissolve,
    color: ClipRGBColor = ClipRGBColor(red: .zero, green: .zero, blue: .zero),
    direction: ClipVideoTransitionDirection = .left
) throws -> ClipVideoTransition {
    ClipVideoTransition(
        partnerClipID: partner,
        duration: try editTime(durationFrames),
        kind: kind,
        color: color,
        direction: direction
    )
}

/// A valid abutting pair — outgoing `[0, 10)`, incoming `[10, 20)` — with mirrored records.
func makeVideoTransitionPairProject(
    kind: ClipVideoTransitionKind = .crossDissolve,
    direction: ClipVideoTransitionDirection = .left,
    durationFrames: Int64 = 4
) throws -> Project {
    let outgoingID = try VideoTransitionFixtureID.outgoingClip()
    let incomingID = try VideoTransitionFixtureID.incomingClip()
    var outgoingSpec = VideoTransitionClipSpec()
    outgoingSpec.trailingTransition = try makeTrailingTransition(
        partner: incomingID,
        durationFrames: durationFrames,
        kind: kind,
        direction: direction
    )
    var incomingSpec = VideoTransitionClipSpec()
    incomingSpec.timelineStartFrame = 10
    incomingSpec.leadingTransition = try makeLeadingTransition(
        partner: outgoingID,
        durationFrames: durationFrames,
        kind: kind,
        direction: direction
    )
    return try makeVideoTransitionProject(items: [
        .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec)),
        .clip(try makeVideoTransitionClip(id: incomingID, spec: incomingSpec))
    ])
}

func projectVideoTransitionErrors(in project: Project) -> [VideoTransitionValidationError] {
    guard case .invalid(let errors) = project.validate() else {
        return []
    }
    return errors.compactMap { error in
        if case .invalidClipVideoTransition(_, _, _, let transitionError) = error {
            return transitionError
        }
        return nil
    }
}

func videoTransitionTrackClip(_ clipID: UUID, in project: Project) throws -> Clip {
    let sequence = try XCTUnwrap(project.sequences.first)
    let track = try XCTUnwrap(sequence.videoTracks.first)
    for item in track.items {
        if case .clip(let clip) = item, clip.id == clipID {
            return clip
        }
    }
    struct Missing: Error {}
    throw Missing()
}
