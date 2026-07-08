// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-SPD-001 x FR-TL-009: constant-rate retimes propagate through linked A/V groups and
/// ripple later items on every affected track using the ripple-trim convention.
final class ClipSpeedLinkedRippleTests: XCTestCase {
    func testFRSPD001FRTL009SpeedPropagatesFromVideoToLinkedAudio() throws {
        let fixture = try makeLinkedEditFixture(seed: 4_310)

        let edited = try apply(
            .setClipSpeed(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.videoClipID,
                speed: RationalValue(2)
            ),
            to: fixture.project
        )

        let videoClip = try requiredClip(
            fixture.videoClipID,
            trackID: fixture.videoTrackID,
            in: edited
        )
        let audioClip = try requiredClip(
            fixture.audioClipID,
            trackID: fixture.audioTrackID,
            in: edited
        )
        XCTAssertEqual(videoClip.speed, RationalValue(2))
        XCTAssertEqual(audioClip.speed, RationalValue(2))
        XCTAssertEqual(videoClip.timelineRange, try editRange(startFrame: 0, durationFrames: 5))
        XCTAssertEqual(audioClip.timelineRange, videoClip.timelineRange)
        try assertLinkedSourceTimesStayInSync(videoClip: videoClip, audioClip: audioClip)
    }

    func testFRSPD001FRTL009SpeedPropagatesFromAudioToLinkedVideo() throws {
        let fixture = try makeLinkedEditFixture(seed: 4_320)
        let halfSpeed = try RationalValue(numerator: 1, denominator: 2)

        let edited = try apply(
            .setClipSpeed(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID,
                speed: halfSpeed
            ),
            to: fixture.project
        )

        let videoClip = try requiredClip(
            fixture.videoClipID,
            trackID: fixture.videoTrackID,
            in: edited
        )
        let audioClip = try requiredClip(
            fixture.audioClipID,
            trackID: fixture.audioTrackID,
            in: edited
        )
        XCTAssertEqual(videoClip.speed, halfSpeed)
        XCTAssertEqual(audioClip.speed, halfSpeed)
        XCTAssertEqual(audioClip.timelineRange, try editRange(startFrame: 0, durationFrames: 20))
        XCTAssertEqual(videoClip.timelineRange, audioClip.timelineRange)
        try assertLinkedSourceTimesStayInSync(videoClip: videoClip, audioClip: audioClip)
    }

    func testFRSPD001SpeedDoesNotPropagateToUnlinkedClips() throws {
        let fixture = try makeLinkedEditFixture(seed: 4_330, linked: false)

        let edited = try apply(
            .setClipSpeed(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.videoClipID,
                speed: RationalValue(2)
            ),
            to: fixture.project
        )

        let audioClip = try requiredClip(
            fixture.audioClipID,
            trackID: fixture.audioTrackID,
            in: edited
        )
        XCTAssertEqual(audioClip.speed, .one)
        XCTAssertEqual(audioClip.timelineRange, try editRange(startFrame: 0, durationFrames: 10))
    }

    func testFRSPD001FRTL009SpeedPropagatesCoherentlyWhenLinkedPartnerCarriesReverse() throws {
        let fixture = try makeLinkedSpeedFixture(seed: 4_340, audioReverse: true)

        let edited = try apply(
            .setClipSpeed(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.videoClipID,
                speed: RationalValue(2)
            ),
            to: fixture.project
        )

        let videoClip = try requiredClip(
            fixture.videoClipID,
            trackID: fixture.videoTrackID,
            in: edited
        )
        let audioClip = try requiredClip(
            fixture.audioClipID,
            trackID: fixture.audioTrackID,
            in: edited
        )
        XCTAssertEqual(videoClip.timelineRange, try editRange(startFrame: 0, durationFrames: 5))
        XCTAssertEqual(audioClip.timelineRange, videoClip.timelineRange)
        XCTAssertEqual(audioClip.speed, RationalValue(2))
        XCTAssertTrue(audioClip.reverse)
        // Reverse keeps composing with the propagated rate: the retimed reversed partner still
        // maps its timeline start onto the exclusive source end.
        XCTAssertEqual(try audioClip.sourceTime(at: try editTime(0)), try editTime(10))
        XCTAssertEqual(try audioClip.sourceTime(at: try editTime(2)), try editTime(6))
    }

    func testFRSPD001FRSPD002SpeedRejectsWhenLinkedPartnerHasTimeRemap() throws {
        let fixture = try makeLinkedSpeedFixture(seed: 4_350, audioTimeRemap: true)

        XCTAssertThrowsError(
            try apply(
                .setClipSpeed(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.videoClipID,
                    speed: RationalValue(2)
                ),
                to: fixture.project
            )
        ) { error in
            guard case .validationFailed(let errors)? = error as? EditReducerError else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertTrue(
                errors.contains { validationError in
                    if case .invalidClipTimeRemap(_, _, fixture.audioClipID, let remapError) =
                        validationError,
                        case .conflictingRetime = remapError {
                        return true
                    }
                    return false
                },
                "expected conflictingRetime for the remapped linked partner in \(errors)"
            )
        }
    }

    func testFRSPD001SlowDownRipplesFollowingItemsInsteadOfOverlapping() throws {
        let fixture = try makeEditFixture(seed: 4_360)
        let followingClipID = try editUUID(4_360_100)
        let followingClip = try makeEditClip(
            id: followingClipID,
            mediaID: fixture.mediaID,
            startFrame: 14
        )
        let baseClip = try requiredClip(fixture.clipID, in: fixture.project, fixture: fixture)
        let gapRange = try editRange(startFrame: 10, durationFrames: 4)
        let project = try replacingVideoItems(
            [.clip(baseClip), .gap(gapRange), .clip(followingClip)],
            in: fixture
        )

        let edited = try apply(
            .setClipSpeed(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                speed: try RationalValue(numerator: 1, denominator: 2)
            ),
            to: project
        )

        try assertClipRange(
            fixture.clipID,
            in: edited,
            fixture: fixture,
            startFrame: 0,
            durationFrames: 20
        )
        try assertClipRange(
            followingClipID,
            in: edited,
            fixture: fixture,
            startFrame: 24,
            durationFrames: 10
        )
        let track = try projectTrack(edited, fixture: fixture)
        XCTAssertTrue(
            track.items.contains(.gap(try editRange(startFrame: 20, durationFrames: 4))),
            "the downstream gap must ripple by the duration delta"
        )
    }

    func testFRSPD001SpeedUpPullsFollowingItemsLeftLikeRippleTrim() throws {
        let fixture = try makeEditFixture(seed: 4_370)
        let followingClipID = try editUUID(4_370_100)
        let followingClip = try makeEditClip(
            id: followingClipID,
            mediaID: fixture.mediaID,
            startFrame: 10
        )
        let baseClip = try requiredClip(fixture.clipID, in: fixture.project, fixture: fixture)
        let project = try replacingVideoItems(
            [.clip(baseClip), .clip(followingClip)],
            in: fixture
        )

        let edited = try apply(
            .setClipSpeed(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                speed: RationalValue(2)
            ),
            to: project
        )

        try assertClipRange(
            fixture.clipID,
            in: edited,
            fixture: fixture,
            startFrame: 0,
            durationFrames: 5
        )
        try assertClipRange(
            followingClipID,
            in: edited,
            fixture: fixture,
            startFrame: 5,
            durationFrames: 10
        )
    }

    func testFRSPD001FRTL009SlowDownRipplesLinkedPartnerTracksTogether() throws {
        let fixture = try makeLinkedSpeedFixture(seed: 4_380, withFollowingClips: true)

        let edited = try apply(
            .setClipSpeed(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.videoClipID,
                speed: try RationalValue(numerator: 1, denominator: 2)
            ),
            to: fixture.project
        )

        let videoClip = try requiredClip(
            fixture.videoClipID,
            trackID: fixture.videoTrackID,
            in: edited
        )
        let audioClip = try requiredClip(
            fixture.audioClipID,
            trackID: fixture.audioTrackID,
            in: edited
        )
        let followingVideoClip = try requiredClip(
            fixture.followingVideoClipID,
            trackID: fixture.videoTrackID,
            in: edited
        )
        let followingAudioClip = try requiredClip(
            fixture.followingAudioClipID,
            trackID: fixture.audioTrackID,
            in: edited
        )
        XCTAssertEqual(videoClip.timelineRange, try editRange(startFrame: 0, durationFrames: 20))
        XCTAssertEqual(audioClip.timelineRange, videoClip.timelineRange)
        XCTAssertEqual(
            followingVideoClip.timelineRange,
            try editRange(startFrame: 20, durationFrames: 10)
        )
        XCTAssertEqual(followingAudioClip.timelineRange, followingVideoClip.timelineRange)
    }

    func testFRSPD001FRTL009LinkedRetimeAndRippleAreUndoable() throws {
        let fixture = try makeLinkedSpeedFixture(seed: 4_390, withFollowingClips: true)
        var history = EditHistory(project: fixture.project)

        let edited = try history.apply(
            .setClipSpeed(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.videoClipID,
                speed: RationalValue(2)
            )
        )

        XCTAssertNotEqual(edited, fixture.project)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
    }

    private func assertLinkedSourceTimesStayInSync(
        videoClip: Clip,
        audioClip: Clip,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            videoClip.timelineRange,
            audioClip.timelineRange,
            "linked clips must keep identical timeline ranges",
            file: file,
            line: line
        )
        let duration = videoClip.timelineRange.duration
        for step in 0...4 {
            let offset = try duration.multiplied(by: Int64(step)).divided(by: 4)
            let time = try videoClip.timelineRange.start.adding(offset)
            XCTAssertEqual(
                try videoClip.sourceTime(at: time),
                try audioClip.sourceTime(at: time),
                "linked A/V source times must agree at \(time)",
                file: file,
                line: line
            )
        }
    }
}

private struct LinkedSpeedFixture {
    let project: Project
    let sequenceID: UUID
    let videoTrackID: UUID
    let audioTrackID: UUID
    let videoClipID: UUID
    let audioClipID: UUID
    let followingVideoClipID: UUID
    let followingAudioClipID: UUID
}

private func makeLinkedSpeedFixture(
    seed: Int,
    audioReverse: Bool = false,
    audioTimeRemap: Bool = false,
    withFollowingClips: Bool = false
) throws -> LinkedSpeedFixture {
    let base = seed * 1_000
    let mediaID = try editUUID(base + 1)
    let sequenceID = try editUUID(base + 2)
    let videoTrackID = try editUUID(base + 3)
    let audioTrackID = try editUUID(base + 4)
    let videoClipID = try editUUID(base + 5)
    let audioClipID = try editUUID(base + 6)
    let linkGroupID = try editUUID(base + 7)
    let followingVideoClipID = try editUUID(base + 8)
    let followingAudioClipID = try editUUID(base + 9)

    let videoClip = try makeEditClip(
        id: videoClipID,
        mediaID: mediaID,
        startFrame: 0,
        linkGroupID: linkGroupID
    )
    let audioClip = try makeLinkedAudioClip(
        id: audioClipID,
        mediaID: mediaID,
        linkGroupID: linkGroupID,
        reverse: audioReverse,
        timeRemap: audioTimeRemap
    )
    var videoItems: [TimelineItem] = [.clip(videoClip)]
    var audioItems: [TimelineItem] = [.clip(audioClip)]
    if withFollowingClips {
        videoItems.append(
            .clip(try makeEditClip(id: followingVideoClipID, mediaID: mediaID, startFrame: 10))
        )
        audioItems.append(
            .clip(
                try makeEditClip(
                    id: followingAudioClipID,
                    mediaID: mediaID,
                    startFrame: 10,
                    kind: .audio
                )
            )
        )
    }

    return LinkedSpeedFixture(
        project: try makeLinkedSpeedProject(
            seed: seed,
            sequenceID: sequenceID,
            mediaID: mediaID,
            videoTrack: Track(id: videoTrackID, kind: .video, items: videoItems),
            audioTrack: Track(id: audioTrackID, kind: .audio, items: audioItems)
        ),
        sequenceID: sequenceID,
        videoTrackID: videoTrackID,
        audioTrackID: audioTrackID,
        videoClipID: videoClipID,
        audioClipID: audioClipID,
        followingVideoClipID: followingVideoClipID,
        followingAudioClipID: followingAudioClipID
    )
}

private func makeLinkedSpeedProject(
    seed: Int,
    sequenceID: UUID,
    mediaID: UUID,
    videoTrack: Track,
    audioTrack: Track
) throws -> Project {
    Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 1_920, height: 1_080),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [try makeEditMediaRef(id: mediaID)],
        sequences: [
            Sequence(
                id: sequenceID,
                name: "Linked speed sequence \(seed)",
                videoTracks: [videoTrack],
                audioTracks: [audioTrack],
                markers: [],
                timebase: try FrameRate(frames: 24)
            )
        ]
    )
}

private func makeLinkedAudioClip(
    id: UUID,
    mediaID: UUID,
    linkGroupID: UUID,
    reverse: Bool,
    timeRemap: Bool
) throws -> Clip {
    let curve: ClipTimeRemap? = timeRemap
        ? try ClipTimeRemap(
            keyframes: [
                TimeRemapKeyframe(time: try editTime(0), sourceTime: try editTime(0)),
                TimeRemapKeyframe(time: try editTime(10), sourceTime: try editTime(10))
            ]
        )
        : nil
    return Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .audio,
        name: "Linked audio \(id.uuidString)",
        linkGroupID: linkGroupID,
        reverse: reverse,
        timeRemap: curve
    )
}
