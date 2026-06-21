// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarAppModelTests: XCTestCase {
    func testFRPLAY001SampleProjectLoadsFromAjarCoreModel() {
        let model = EditorAjarAppModel()

        XCTAssertNotNil(model.project)
        XCTAssertEqual(model.activeSequenceName, "Sample Playback Sequence")
        XCTAssertEqual(model.project?.validate(), .valid)
        XCTAssertEqual(model.frameRateDescription, "30 fps")
        XCTAssertEqual(model.project?.mediaPool.count, 1)
        XCTAssertGreaterThan(model.durationFrames, 1)
    }

    func testFRPLAY001TransportTogglesPlaybackAndFrameStepPauses() {
        let model = EditorAjarAppModel()

        XCTAssertFalse(model.isPlaying)
        model.togglePlayback()
        XCTAssertTrue(model.isPlaying)

        model.stepForward()
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playheadFrame, 1)

        model.stepBackward()
        model.stepBackward()
        XCTAssertEqual(model.playheadFrame, 0)
    }

    func testFRPLAY001DisplayLinkAdvancesPlayheadAtSequenceFrameRate() throws {
        let frameRate = try FrameRate(frames: 30)
        var controller = EditorAjarPlaybackController(frameRate: frameRate, durationFrames: 4)

        XCTAssertFalse(controller.advance(by: 1.0 / 60.0))
        XCTAssertEqual(controller.playheadFrame, 0)
        XCTAssertTrue(controller.advance(by: 1.0 / 60.0))
        XCTAssertEqual(controller.playheadFrame, 1)

        XCTAssertTrue(controller.advance(by: 3.0 / 30.0))
        XCTAssertEqual(controller.playheadFrame, 0)
    }

    func testFRPLAY003ScrubClampsAndStepUpdatesFrame() throws {
        let frameRate = try FrameRate(frames: 30)
        var controller = EditorAjarPlaybackController(frameRate: frameRate, durationFrames: 10)

        controller.scrub(to: 7)
        XCTAssertEqual(controller.playheadFrame, 7)

        controller.stepForward()
        XCTAssertEqual(controller.playheadFrame, 8)

        controller.scrub(to: 20)
        XCTAssertEqual(controller.playheadFrame, 9)

        controller.scrub(to: -4)
        XCTAssertEqual(controller.playheadFrame, 0)
    }
}
