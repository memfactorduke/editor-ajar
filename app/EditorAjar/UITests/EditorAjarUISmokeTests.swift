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
        XCTAssertTrue(
            app.descendants(matching: .any)["Timeline track lanes"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Zoom Timeline In"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Fit Timeline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Zoom to Selection"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Set Range In"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Set Range Out"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Disable Snapping"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Disable Video track 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Lock Video track 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Hide Video track 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Select all Video track 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Mute Audio track 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Solo Audio track 1"].waitForExistence(timeout: 5))

        app.buttons["Hide Video track 1"].click()
        XCTAssertTrue(app.buttons["Show Video track 1"].waitForExistence(timeout: 5))

        app.typeKey("z", modifierFlags: [.command])
        XCTAssertTrue(app.buttons["Hide Video track 1"].waitForExistence(timeout: 5))

        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["Show Video track 1"].waitForExistence(timeout: 5))

        let playheadReadout = app.staticTexts["Playhead readout"]
        XCTAssertTrue(playheadReadout.waitForExistence(timeout: 5))
        assertPlayheadValue("Frame 0", on: playheadReadout)

        app.typeKey(.rightArrow, modifierFlags: [])
        assertPlayheadValue("Frame 1", on: playheadReadout)

        app.typeKey(.leftArrow, modifierFlags: [])
        assertPlayheadValue("Frame 0", on: playheadReadout)

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

    private func assertPlayheadValue(
        _ expectedValue: String,
        on element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let timeout: TimeInterval = 5
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if playheadValue(on: element) == expectedValue {
                return
            }

            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }

        let actualValue = playheadValue(on: element)
        XCTFail(
            "Expected playhead value \(expectedValue), got \(actualValue)",
            file: file,
            line: line
        )
    }

    private func playheadValue(on element: XCUIElement) -> String {
        element.value as? String ?? "<nil>"
    }
}
