// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-TXT-004 animated title presets: apply/undo, replace, eval, determinism.
final class TitleAnimationPresetTests: XCTestCase {
    func testFRTXT004ApplyPresetIsOneUndoableEdit() throws {
        let fixture = try makeTitleProjectFixture(seed: 9_186)
        var history = EditHistory(project: fixture.project)
        let preset = TitleAnimationPreset(kind: .fade, duration: try editTime(6))
        let applied = try history.apply(
            .applyTitleAnimationPreset(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                preset: preset
            )
        )
        let clip = try titleClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: applied,
            sequenceID: fixture.sequenceID
        )
        XCTAssertEqual(clip.transformAnimation.opacity.keyframes.count, 2)
        XCTAssertEqual(applied.validate(), .valid)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), applied)
    }

    func testFRTXT004ApplyTwiceReplacesCleanly() throws {
        let fixture = try makeTitleProjectFixture(seed: 9_187)
        let fade = TitleAnimationPreset(kind: .fade, duration: try editTime(6))
        let slide = TitleAnimationPreset(
            kind: .slide,
            duration: try editTime(8),
            direction: .right
        )
        let afterFade = try EditReducer.apply(
            .applyTitleAnimationPreset(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                preset: fade
            ),
            to: fixture.project
        )
        let afterSlide = try EditReducer.apply(
            .applyTitleAnimationPreset(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                preset: slide
            ),
            to: afterFade
        )
        let directSlide = try EditReducer.apply(
            .applyTitleAnimationPreset(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                preset: slide
            ),
            to: fixture.project
        )
        let via = try titleClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: afterSlide,
            sequenceID: fixture.sequenceID
        )
        let direct = try titleClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: directSlide,
            sequenceID: fixture.sequenceID
        )
        XCTAssertEqual(via.transformAnimation, direct.transformAnimation)
        XCTAssertEqual(
            try titleSource(from: via).revealFraction, try titleSource(from: direct).revealFraction)
        XCTAssertFalse(via.transformAnimation.opacity.keyframes.isEmpty)
        XCTAssertFalse(via.transformAnimation.position.keyframes.isEmpty)
    }

    func testFRTXT004PresetApplicationIsDeterministic() throws {
        let fixture = try makeTitleProjectFixture(seed: 9_188)
        let preset = TitleAnimationPreset(kind: .pop, duration: try editTime(6))
        let first = try EditReducer.apply(
            .applyTitleAnimationPreset(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                preset: preset
            ),
            to: fixture.project
        )
        let second = try EditReducer.apply(
            .applyTitleAnimationPreset(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                preset: preset
            ),
            to: fixture.project
        )
        XCTAssertEqual(first, second)
    }

    func testFRTXT004PerPresetEvaluationAtStartMidEnd() throws {
        let fixture = try makeTitleProjectFixture(seed: 9_189)
        let duration = try editTime(8)
        let start = try editTime(0)
        let mid = try editTime(4)
        let end = try editTime(8)

        let fadeClip = try applyTitlePreset(.fade, duration: duration, fixture: fixture)
        XCTAssertEqual(fadeClip.transformAnimation.opacity.value(at: start), .zero)
        XCTAssertEqual(
            fadeClip.transformAnimation.opacity.value(at: mid).doubleValue,
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(fadeClip.transformAnimation.opacity.value(at: end), .one)

        let slideClip = try applyTitlePreset(
            .slide,
            duration: duration,
            fixture: fixture,
            direction: .left
        )
        let slideStart = slideClip.transformAnimation.position.value(at: start)
        let slideEnd = slideClip.transformAnimation.position.value(at: end)
        XCTAssertLessThan(slideStart.x.doubleValue, slideEnd.x.doubleValue)
        XCTAssertEqual(slideClip.transformAnimation.opacity.value(at: start), .zero)
        XCTAssertEqual(slideClip.transformAnimation.opacity.value(at: end), .one)

        let typeClip = try applyTitlePreset(.typewriter, duration: duration, fixture: fixture)
        let typeTitle = try titleSource(from: typeClip)
        XCTAssertEqual(typeTitle.revealFraction.value(at: start), .zero)
        XCTAssertEqual(typeTitle.revealFraction.value(at: mid).doubleValue, 0.5, accuracy: 0.001)
        XCTAssertEqual(typeTitle.revealFraction.value(at: end), .one)
        XCTAssertTrue(typeClip.transformAnimation.opacity.keyframes.isEmpty)

        let popClip = try applyTitlePreset(.pop, duration: duration, fixture: fixture)
        XCTAssertEqual(popClip.transformAnimation.scale.value(at: start).x, .zero)
        XCTAssertEqual(popClip.transformAnimation.scale.value(at: end), .identity)
        XCTAssertEqual(popClip.transformAnimation.opacity.value(at: start), .zero)
        XCTAssertEqual(popClip.transformAnimation.opacity.value(at: end), .one)

        let ltClip = try applyTitlePreset(
            .lowerThird,
            duration: duration,
            fixture: fixture,
            direction: .down
        )
        let ltTitle = try titleSource(from: ltClip)
        XCTAssertNotNil(ltTitle.boxes.first?.backgroundBox)
        XCTAssertEqual(ltClip.transformAnimation.opacity.value(at: start), .zero)
        XCTAssertEqual(ltClip.transformAnimation.opacity.value(at: end), .one)
        let ltStart = ltClip.transformAnimation.position.value(at: start)
        let ltEnd = ltClip.transformAnimation.position.value(at: end)
        XCTAssertGreaterThan(ltStart.y.doubleValue, ltEnd.y.doubleValue)
    }

    func testFRTXT004SchemaMinorIsSeven() {
        XCTAssertEqual(AjarProjectCodec.currentSchemaMinor, 7)
    }

    /// Applying a preset resets the whole transform animation and reveal program (not a
    /// selective channel merge); undo restores the prior user-authored state exactly.
    func testFRTXT004ApplyPresetResetsWholeTransformAndRevealThenUndoRestores() throws {
        let fixture = try makeTitleProjectFixture(seed: 9_194)
        let authored = try projectWithUserAuthoredTitleAnimation(fixture: fixture)
        let originalClip = try titleClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: authored,
            sequenceID: fixture.sequenceID
        )
        let originalTransform = originalClip.transformAnimation
        let originalTitle = try titleSource(from: originalClip)
        XCTAssertFalse(originalTransform.position.keyframes.isEmpty)
        XCTAssertFalse(originalTransform.rotation.keyframes.isEmpty)
        XCTAssertFalse(originalTitle.revealFraction.keyframes.isEmpty)

        var history = EditHistory(project: authored)
        let applied = try history.apply(
            .applyTitleAnimationPreset(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                preset: TitleAnimationPreset(kind: .fade, duration: try editTime(6))
            )
        )
        try assertFadeReplacedUserAuthoredAnimation(
            clip: try titleClip(
                fixture.clipID,
                trackID: fixture.videoTrackID,
                in: applied,
                sequenceID: fixture.sequenceID
            ),
            originalTransform: originalTransform,
            originalTitle: originalTitle
        )

        let restored = try XCTUnwrap(history.undo())
        XCTAssertEqual(restored, authored)
        let restoredClip = try titleClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: restored,
            sequenceID: fixture.sequenceID
        )
        XCTAssertEqual(restoredClip.transformAnimation, originalTransform)
        XCTAssertEqual(try titleSource(from: restoredClip), originalTitle)
    }

    func testFRTXT004RejectsNonPositiveAndOverlongDuration() throws {
        let fixture = try makeTitleProjectFixture(seed: 9_193)
        XCTAssertThrowsError(
            try EditReducer.apply(
                .applyTitleAnimationPreset(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.clipID,
                    preset: TitleAnimationPreset(kind: .fade, duration: .zero)
                ),
                to: fixture.project
            )
        ) { error in
            guard case .invalidEdit(let validation) = error as? EditReducerError else {
                return XCTFail("expected invalidEdit, got \(error)")
            }
            guard case .titleAnimationPresetNonPositiveDuration = validation else {
                return XCTFail("expected non-positive duration, got \(validation)")
            }
        }
        XCTAssertThrowsError(
            try EditReducer.apply(
                .applyTitleAnimationPreset(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.clipID,
                    preset: TitleAnimationPreset(kind: .fade, duration: try editTime(100))
                ),
                to: fixture.project
            )
        ) { error in
            guard case .invalidEdit(let validation) = error as? EditReducerError else {
                return XCTFail("expected invalidEdit, got \(error)")
            }
            guard case .titleAnimationPresetDurationExceedsClip = validation else {
                return XCTFail("expected duration exceeds clip, got \(validation)")
            }
        }
    }

    private func assertFadeReplacedUserAuthoredAnimation(
        clip: Clip,
        originalTransform: AnimatableClipTransform,
        originalTitle: TitleSource
    ) throws {
        let afterTitle = try titleSource(from: clip)
        // Whole transform animation is the fade program: opacity keyframed, others constant.
        XCTAssertTrue(clip.transformAnimation.position.keyframes.isEmpty)
        XCTAssertTrue(clip.transformAnimation.rotation.keyframes.isEmpty)
        XCTAssertTrue(clip.transformAnimation.scale.keyframes.isEmpty)
        XCTAssertEqual(clip.transformAnimation.opacity.keyframes.count, 2)
        XCTAssertEqual(clip.transformAnimation.opacity.value(at: try editTime(0)), .zero)
        XCTAssertEqual(clip.transformAnimation.opacity.value(at: try editTime(6)), .one)
        // Prior reveal program is fully reset (not merged).
        XCTAssertEqual(afterTitle.revealFraction, .constant(.one))
        XCTAssertNotEqual(clip.transformAnimation, originalTransform)
        XCTAssertNotEqual(afterTitle.revealFraction, originalTitle.revealFraction)
    }
}
