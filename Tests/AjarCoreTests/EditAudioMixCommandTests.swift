// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class EditAudioMixCommandTests: XCTestCase {
    func testFRAUD001SetAndClearClipAudioMixRoutesThroughUndoableHistory() throws {
        let fixture = try makeLinkedEditFixture(seed: 440)
        let audioMix = try makeCommandAudioMix()
        var setHistory = EditHistory(project: fixture.project)
        let edited = try setHistory.apply(
            .setClipAudioMix(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID,
                audioMix: audioMix
            )
        )

        XCTAssertEqual(try commandAudioClip(fixture.audioClipID, in: edited).audioMix, audioMix)
        XCTAssertEqual(setHistory.undo(), fixture.project)
        XCTAssertEqual(try setHistory.redo(), edited)

        var clearHistory = EditHistory(project: edited)
        let cleared = try clearHistory.apply(
            .clearClipAudioMix(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID
            )
        )

        XCTAssertEqual(try commandAudioClip(fixture.audioClipID, in: cleared).audioMix, .identity)
        XCTAssertEqual(clearHistory.undo(), edited)
        XCTAssertEqual(try clearHistory.redo(), cleared)
    }

    func testFRAUD001SetAndClearTrackAudioMixRoutesThroughUndoableHistory() throws {
        let fixture = try makeEditFixture(seed: 441)
        let patch = TrackAudioMixPatch(
            gain: .constant(try RationalValue(numerator: 1, denominator: 2)),
            pan: .constant(try RationalValue(numerator: -1, denominator: 2))
        )
        var setHistory = EditHistory(project: fixture.project)
        let edited = try setHistory.apply(
            .setTrackAudioMix(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                audio: patch
            )
        )
        let editedTrack = try projectTrack(
            fixture.audioTrackID,
            in: edited,
            sequenceID: fixture.sequenceID
        )

        XCTAssertEqual(
            editedTrack.audioGain,
            .constant(try RationalValue(numerator: 1, denominator: 2))
        )
        XCTAssertEqual(
            editedTrack.audioPan,
            .constant(try RationalValue(numerator: -1, denominator: 2))
        )
        XCTAssertEqual(setHistory.undo(), fixture.project)
        XCTAssertEqual(try setHistory.redo(), edited)

        var clearHistory = EditHistory(project: edited)
        let cleared = try clearHistory.apply(
            .clearTrackAudioMix(sequenceID: fixture.sequenceID, trackID: fixture.audioTrackID)
        )
        let clearedTrack = try projectTrack(
            fixture.audioTrackID,
            in: cleared,
            sequenceID: fixture.sequenceID
        )

        XCTAssertEqual(clearedTrack.audioGain, .constant(.one))
        XCTAssertEqual(clearedTrack.audioPan, .constant(.zero))
        XCTAssertEqual(clearHistory.undo(), edited)
        XCTAssertEqual(try clearHistory.redo(), cleared)
    }

    func testNFRSTAB003InvalidClipAudioGainReturnsTypedError() throws {
        let fixture = try makeLinkedEditFixture(seed: 442)
        let invalidMix = ClipAudioMix(gain: .constant(RationalValue(-1)))

        XCTAssertThrowsError(
            try apply(
                .setClipAudioMix(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    clipID: fixture.audioClipID,
                    audioMix: invalidMix
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .invalidClipAudioMix(
                        clipID: fixture.audioClipID,
                        error: .gainOutOfRange(
                            value: RationalValue(-1),
                            minimum: .zero,
                            maximum: RationalValue(4)
                        )
                    )
                )
            )
        }
    }

    func testNFRSTAB003InvalidTrackAudioPanReturnsTypedValidationError() throws {
        let fixture = try makeEditFixture(seed: 443)
        let invalidPan = Animatable.constant(RationalValue(2))

        XCTAssertThrowsError(
            try apply(
                .setTrackAudioMix(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    audio: TrackAudioMixPatch(pan: invalidPan)
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .validationFailed([
                    .invalidTrackAudioMix(
                        sequenceID: fixture.sequenceID,
                        trackID: fixture.audioTrackID,
                        error: .panOutOfRange(
                            value: RationalValue(2),
                            minimum: RationalValue(-1),
                            maximum: .one
                        )
                    )
                ])
            )
        }
    }
}

private func makeCommandAudioMix() throws -> ClipAudioMix {
    ClipAudioMix(
        gain: try Animatable(
            base: .one,
            keyframes: [
                Keyframe(
                    time: try editTime(0),
                    value: .one,
                    interpolation: .linear
                ),
                Keyframe(
                    time: try editTime(8),
                    value: try RationalValue(numerator: 3, denominator: 2),
                    interpolation: .hold
                )
            ]
        ),
        pan: .constant(try RationalValue(numerator: -1, denominator: 4)),
        fadeIn: ClipAudioFade(duration: try editTime(2), curve: .easeIn),
        fadeOut: ClipAudioFade(duration: try editTime(3), curve: .easeOut)
    )
}

private func commandAudioClip(_ clipID: UUID, in project: Project) throws -> Clip {
    let sequence = try XCTUnwrap(project.sequences.first)
    let audioTrack = try XCTUnwrap(sequence.audioTracks.first)
    return try XCTUnwrap(clip(clipID, in: audioTrack))
}
