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
        XCTAssertTrue(app.otherElements["Transport controls"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Step Backward"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Step Forward"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["Scrub playhead"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Playhead Frame 0"].waitForExistence(timeout: 5))

        app.buttons["Step Forward"].click()
        XCTAssertTrue(app.staticTexts["Playhead Frame 1"].waitForExistence(timeout: 5))

        app.buttons["Step Backward"].click()
        XCTAssertTrue(app.staticTexts["Playhead Frame 0"].waitForExistence(timeout: 5))

        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Playhead Frame 1"].waitForExistence(timeout: 5))

        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Playhead Frame 0"].waitForExistence(timeout: 5))

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
}
