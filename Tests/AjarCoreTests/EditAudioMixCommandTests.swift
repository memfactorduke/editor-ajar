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

    func testFRAUD001SetClipAudioMixPreservesAnimationState() throws {
        let fixture = try makeLinkedEditFixture(seed: 444)
        let transformAnimation = try commandClipTransformAnimation()
        let effectsAnimation = try commandClipEffectsAnimation()
        let project = try commandProject(
            fixture: fixture,
            transformAnimation: transformAnimation,
            effectsAnimation: effectsAnimation
        )
        let audioMix = try makeCommandAudioMix()

        let edited = try apply(
            .setClipAudioMix(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID,
                audioMix: audioMix
            ),
            to: project
        )
        let editedClip = try commandAudioClip(fixture.audioClipID, in: edited)

        XCTAssertEqual(editedClip.audioMix, audioMix)
        XCTAssertEqual(editedClip.transformAnimation, transformAnimation)
        XCTAssertEqual(editedClip.effectsAnimation, effectsAnimation)
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
                .invalidEdit(
                    .invalidTrackAudioMix(
                        trackID: fixture.audioTrackID,
                        error: .panOutOfRange(
                            value: RationalValue(2),
                            minimum: RationalValue(-1),
                            maximum: .one
                        )
                    )
                )
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

private func commandProject(
    fixture: LinkedEditFixture,
    transformAnimation: AnimatableClipTransform,
    effectsAnimation: AnimatableClipEffects
) throws -> Project {
    let audioClip = try commandAudioClip(fixture.audioClipID, in: fixture.project)
    let animatedAudioClip = EditReducer.copying(
        audioClip,
        transformAnimation: transformAnimation,
        effectsAnimation: effectsAnimation
    )
    return try replacingAudioItems([.clip(animatedAudioClip)], in: fixture)
}

private func commandClipTransformAnimation() throws -> AnimatableClipTransform {
    AnimatableClipTransform(
        position: try Animatable(
            base: .zero,
            keyframes: [
                Keyframe(
                    time: try editTime(1),
                    value: CanvasPoint(x: RationalValue(4), y: RationalValue(5)),
                    interpolation: .linear
                ),
                Keyframe(
                    time: try editTime(6),
                    value: CanvasPoint(x: RationalValue(7), y: RationalValue(8)),
                    interpolation: .easeInOut
                )
            ]
        ),
        opacity: try Animatable(
            base: .one,
            keyframes: [
                Keyframe(
                    time: try editTime(2),
                    value: try RationalValue(numerator: 3, denominator: 4),
                    interpolation: .hold
                )
            ]
        )
    )
}

private func commandClipEffectsAnimation() throws -> AnimatableClipEffects {
    AnimatableClipEffects(
        colorCorrection: AnimatableClipColorCorrection(
            exposure: try Animatable(
                base: .zero,
                keyframes: [
                    Keyframe(
                        time: try editTime(3),
                        value: try RationalValue(numerator: 1, denominator: 2),
                        interpolation: .easeOut
                    )
                ]
            )
        )
    )
}

private func replacingAudioItems(
    _ items: [TimelineItem],
    in fixture: LinkedEditFixture
) throws -> Project {
    let project = fixture.project
    let sequence = try XCTUnwrap(project.sequences.first { $0.id == fixture.sequenceID })
    let audioTracks = sequence.audioTracks.map { track in
        if track.id == fixture.audioTrackID {
            return Track(
                id: track.id,
                kind: track.kind,
                items: items,
                enabled: track.enabled,
                locked: track.locked,
                muted: track.muted,
                solo: track.solo,
                hidden: track.hidden,
                opacity: track.opacity,
                blendMode: track.blendMode,
                audioGain: track.audioGain,
                audioPan: track.audioPan
            )
        }
        return track
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
