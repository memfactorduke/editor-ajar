// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

final class EditorAjarUISmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = makeEditorAjarApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testROADMAPM2NFRA11Y001LaunchesAndExercisesTransportControls() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        XCTAssertTrue(
            app.otherElements["Program monitor showing Sample Playback Sequence"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["Transport controls"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Step Backward"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Step Forward"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["Scrub playhead"].waitForExistence(timeout: 5))

        let playheadReadout = app.staticTexts["Playhead readout"]
        XCTAssertTrue(playheadReadout.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel("Playhead Frame 0", on: playheadReadout))

        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitForLabel("Playhead Frame 1", on: playheadReadout))

        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(waitForLabel("Playhead Frame 0", on: playheadReadout))

        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))

        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func makeEditorAjarApplication() -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let builtProductsPath = environment["BUILT_PRODUCTS_DIR"] else {
            return XCUIApplication()
        }

        let appURL = URL(fileURLWithPath: builtProductsPath)
            .appendingPathComponent("EditorAjar.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            return XCUIApplication()
        }

        return XCUIApplication(url: appURL)
    }

    private func waitForLabel(
        _ expectedLabel: String,
        on element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expectedLabel)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
