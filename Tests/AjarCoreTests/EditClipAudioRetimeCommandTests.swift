// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-SPD-001 edit-command coverage for `setClipAudioRetimeMode`: typed validation of the
/// composition policy and exact undo through `EditHistory`.
final class EditClipAudioRetimeCommandTests: XCTestCase {
    func testFRSPD001SetClipAudioRetimeModeRoutesThroughUndoableHistory() throws {
        let fixture = try makeLinkedEditFixture(seed: 450)
        var history = EditHistory(project: fixture.project)
        let edited = try history.apply(
            .setClipAudioRetimeMode(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID,
                mode: .pitchCorrected
            )
        )
        let editedClip = try requiredClip(
            fixture.audioClipID,
            trackID: fixture.audioTrackID,
            in: edited,
            sequenceID: fixture.sequenceID
        )

        XCTAssertEqual(editedClip.audioMix.retimeMode, .pitchCorrected)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
    }

    func testFRSPD001SetClipAudioRetimeModePreservesOtherAudioMixFields() throws {
        let fixture = try makeLinkedEditFixture(seed: 451)
        let mix = ClipAudioMix(
            gain: .constant(try RationalValue(numerator: 1, denominator: 2)),
            pan: .constant(try RationalValue(numerator: -1, denominator: 4)),
            fadeIn: ClipAudioFade(duration: try editTime(1), curve: .easeIn)
        )
        let seeded = try apply(
            .setClipAudioMix(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID,
                audioMix: mix
            ),
            to: fixture.project
        )

        let edited = try apply(
            .setClipAudioRetimeMode(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID,
                mode: .pitchCorrected
            ),
            to: seeded
        )
        let editedClip = try requiredClip(
            fixture.audioClipID,
            trackID: fixture.audioTrackID,
            in: edited,
            sequenceID: fixture.sequenceID
        )

        XCTAssertEqual(editedClip.audioMix.retimeMode, .pitchCorrected)
        XCTAssertEqual(editedClip.audioMix.gain, mix.gain)
        XCTAssertEqual(editedClip.audioMix.pan, mix.pan)
        XCTAssertEqual(editedClip.audioMix.fadeIn, mix.fadeIn)
        XCTAssertEqual(editedClip.audioMix.fadeOut, mix.fadeOut)
    }

    func testFRSPD001PitchCorrectedRejectsFreezeFrameClipWithTypedError() throws {
        let fixture = try makeFreezeFrameFixture(seed: 452)

        XCTAssertThrowsError(
            try apply(
                .setClipAudioRetimeMode(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    clipID: fixture.audioClipID,
                    mode: .pitchCorrected
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .invalidClipAudioRetime(
                        clipID: fixture.audioClipID,
                        error: .pitchCorrectedConflictsWithFreezeFrame
                    )
                )
            )
        }
    }

    func testFRSPD001PitchCorrectedRejectsTimeRemappedClipWithTypedError() throws {
        let fixture = try makeLinkedEditFixture(seed: 453)
        let curve = try ClipTimeRemap(keyframes: [
            TimeRemapKeyframe(time: try editTime(0), sourceTime: try editTime(0)),
            TimeRemapKeyframe(time: try editTime(10), sourceTime: try editTime(10))
        ])
        let remapProject = try replacingAudioClip(in: fixture) { clip in
            Clip(
                id: clip.id,
                source: clip.source,
                sourceRange: clip.sourceRange,
                timelineRange: clip.timelineRange,
                kind: clip.kind,
                name: clip.name,
                linkGroupID: clip.linkGroupID,
                audioMix: clip.audioMix,
                timeRemap: curve
            )
        }

        XCTAssertThrowsError(
            try apply(
                .setClipAudioRetimeMode(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    clipID: fixture.audioClipID,
                    mode: .pitchCorrected
                ),
                to: remapProject
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .invalidClipAudioRetime(
                        clipID: fixture.audioClipID,
                        error: .pitchCorrectedConflictsWithTimeRemap
                    )
                )
            )
        }
    }

    func testFRSPD001PitchCorrectedComposesWithReverseAndConstantSpeed() throws {
        let fixture = try makeLinkedEditFixture(seed: 454)
        let reverseProject = try replacingAudioClip(in: fixture) { clip in
            Clip(
                id: clip.id,
                source: clip.source,
                sourceRange: clip.sourceRange,
                timelineRange: clip.timelineRange,
                kind: clip.kind,
                name: clip.name,
                linkGroupID: clip.linkGroupID,
                audioMix: clip.audioMix,
                reverse: true
            )
        }

        let edited = try apply(
            .setClipAudioRetimeMode(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID,
                mode: .pitchCorrected
            ),
            to: reverseProject
        )
        let editedClip = try requiredClip(
            fixture.audioClipID,
            trackID: fixture.audioTrackID,
            in: edited,
            sequenceID: fixture.sequenceID
        )

        XCTAssertEqual(editedClip.audioMix.retimeMode, .pitchCorrected)
        XCTAssertTrue(editedClip.reverse)
    }

    func testFRSPD001SetClipAudioRetimeModeActionName() {
        XCTAssertEqual(
            EditCommand.setClipAudioRetimeMode(
                sequenceID: UUID(),
                trackID: UUID(),
                clipID: UUID(),
                mode: .pitchCorrected
            ).actionName,
            "Set Audio Retime Mode"
        )
    }
}

private func makeFreezeFrameFixture(seed: Int) throws -> LinkedEditFixture {
    let fixture = try makeLinkedEditFixture(seed: seed)
    let project = try replacingAudioClip(in: fixture) { clip in
        Clip(
            id: clip.id,
            source: clip.source,
            sourceRange: clip.sourceRange,
            timelineRange: clip.timelineRange,
            kind: clip.kind,
            name: clip.name,
            linkGroupID: clip.linkGroupID,
            audioMix: clip.audioMix,
            freezeFrame: true
        )
    }
    return LinkedEditFixture(
        project: project,
        sequenceID: fixture.sequenceID,
        videoTrackID: fixture.videoTrackID,
        audioTrackID: fixture.audioTrackID,
        videoClipID: fixture.videoClipID,
        audioClipID: fixture.audioClipID,
        mediaID: fixture.mediaID,
        linkGroupID: fixture.linkGroupID
    )
}

private func replacingAudioClip(
    in fixture: LinkedEditFixture,
    transform: (Clip) throws -> Clip
) throws -> Project {
    let project = fixture.project
    let sequence = try XCTUnwrap(project.sequences.first { $0.id == fixture.sequenceID })
    let audioTracks = try sequence.audioTracks.map { track -> Track in
        guard track.id == fixture.audioTrackID else {
            return track
        }
        let items = try track.items.map { item -> TimelineItem in
            guard case .clip(let clip) = item, clip.id == fixture.audioClipID else {
                return item
            }
            return .clip(try transform(clip))
        }
        return Track(id: track.id, kind: track.kind, items: items)
    }
    let replacementSequence = Sequence(
        id: sequence.id,
        name: sequence.name,
        videoTracks: sequence.videoTracks,
        audioTracks: audioTracks,
        markers: sequence.markers,
        timebase: sequence.timebase
    )
    return Project(
        schemaVersion: project.schemaVersion,
        settings: project.settings,
        mediaPool: project.mediaPool,
        sequences: project.sequences.map { $0.id == sequence.id ? replacementSequence : $0 }
    )
}
