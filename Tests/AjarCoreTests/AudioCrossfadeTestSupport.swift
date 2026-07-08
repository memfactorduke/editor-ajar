// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// Shared fixture builders for the ADR-0015 crossfade validation and codec tests
/// (FR-AUD-002).
enum CrossfadeFixtureID {
    static func media() throws -> UUID { try editUUID(900_001) }
    static func sequence() throws -> UUID { try editUUID(900_002) }
    static func track() throws -> UUID { try editUUID(900_003) }
    static func outgoingClip() throws -> UUID { try editUUID(900_005) }
    static func incomingClip() throws -> UUID { try editUUID(900_006) }
    static func extraClip() throws -> UUID { try editUUID(900_007) }
    static func stalePartner() throws -> UUID { try editUUID(900_008) }
}

struct CrossfadeClipSpec {
    var sourceStartFrame: Int64 = 0
    var timelineStartFrame: Int64 = 0
    var sourceDurationFrames: Int64 = 10
    var audioMix: ClipAudioMix = .identity
    var speed: RationalValue = .one
    var reverse = false
    var freezeFrame = false
    var timeRemap: ClipTimeRemap?
}

func makeCrossfadeClip(id: UUID, spec: CrossfadeClipSpec) throws -> Clip {
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
        source: .media(id: try CrossfadeFixtureID.media()),
        sourceRange: try TimeRange(
            start: editTime(spec.sourceStartFrame),
            duration: sourceDuration
        ),
        timelineRange: try TimeRange(
            start: editTime(spec.timelineStartFrame),
            duration: timelineDuration
        ),
        kind: .audio,
        name: "Crossfade clip \(id.uuidString)",
        audioMix: spec.audioMix,
        speed: spec.speed,
        reverse: spec.reverse,
        freezeFrame: spec.freezeFrame,
        timeRemap: spec.timeRemap
    )
}

func makeCrossfadeProject(items: [TimelineItem]) throws -> Project {
    let media = try makeEditMediaRef(id: CrossfadeFixtureID.media())
    let track = Track(id: try CrossfadeFixtureID.track(), kind: .audio, items: items)
    let sequence = Sequence(
        id: try CrossfadeFixtureID.sequence(),
        name: "Crossfade sequence",
        videoTracks: [],
        audioTracks: [track],
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

func outgoingCrossfadeMix(
    partner: UUID,
    durationFrames: Int64 = 4,
    curve: ClipAudioFadeCurve = .linear,
    fadeOutFrames: Int64 = 0
) throws -> ClipAudioMix {
    ClipAudioMix(
        fadeOut: ClipAudioFade(duration: try editTime(fadeOutFrames)),
        trailingCrossfade: ClipAudioCrossfade(
            partnerClipID: partner,
            duration: try editTime(durationFrames),
            curve: curve
        )
    )
}

func incomingCrossfadeMix(
    partner: UUID,
    durationFrames: Int64 = 4,
    curve: ClipAudioFadeCurve = .linear,
    fadeInFrames: Int64 = 0
) throws -> ClipAudioMix {
    ClipAudioMix(
        fadeIn: ClipAudioFade(duration: try editTime(fadeInFrames)),
        leadingCrossfade: ClipAudioCrossfade(
            partnerClipID: partner,
            duration: try editTime(durationFrames),
            curve: curve
        )
    )
}

/// A valid abutting pair — outgoing clip on `[0, 10)`, incoming clip on `[10, 20)` — with
/// mirrored crossfade records of the given curve, per the ADR-0015 §5 taxonomy.
func makeCrossfadePairProject(curve: ClipAudioFadeCurve = .linear) throws -> Project {
    let outgoingID = try CrossfadeFixtureID.outgoingClip()
    let incomingID = try CrossfadeFixtureID.incomingClip()
    var outgoingSpec = CrossfadeClipSpec()
    outgoingSpec.audioMix = try outgoingCrossfadeMix(partner: incomingID, curve: curve)
    var incomingSpec = CrossfadeClipSpec()
    incomingSpec.timelineStartFrame = 10
    incomingSpec.audioMix = try incomingCrossfadeMix(partner: outgoingID, curve: curve)
    return try makeCrossfadeProject(items: [
        .clip(try makeCrossfadeClip(id: outgoingID, spec: outgoingSpec)),
        .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
    ])
}

func projectCrossfadeErrors(in project: Project) -> [AudioCrossfadeValidationError] {
    guard case .invalid(let errors) = project.validate() else {
        return []
    }
    return errors.compactMap { error in
        if case .invalidClipAudioCrossfade(_, _, _, let crossfadeError) = error {
            return crossfadeError
        }
        return nil
    }
}
