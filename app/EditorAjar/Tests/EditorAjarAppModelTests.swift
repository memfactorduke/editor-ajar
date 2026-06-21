// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarAppModelTests: XCTestCase {
    func testFRPLAY001SampleProjectLoadsFromAjarCoreModel() {
        let model = EditorAjarAppModel()

        XCTAssertNotNil(model.project)
        XCTAssertEqual(model.activeSequenceName, "Untitled Sequence")
        XCTAssertEqual(model.project?.validate(), .valid)
        XCTAssertEqual(model.frameRateDescription, "30 fps")
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
}
