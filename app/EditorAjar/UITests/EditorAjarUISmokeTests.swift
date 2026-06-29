// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

final class EditorAjarUISmokeTests: XCTestCase {
    private static let launchAttemptLimit = 3
    private static let launchRetryDelay: TimeInterval = 1
    private static let launchWindowTimeout: TimeInterval = 10

    private var launchedApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        launchedApp = try launchAppWithRetry()
    }

    override func tearDownWithError() throws {
        if let launchedApp = launchedApp,
           launchedApp.state == .runningForeground || launchedApp.state == .runningBackground {
            launchedApp.terminate()
        }

        launchedApp = nil
    }

    func testROADMAPM2NFRA11Y001LaunchesAndExercisesTransportControls() throws {
        let app = try XCTUnwrap(launchedApp)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        assertInitialProjectChrome(in: app)
        exerciseSequenceTabs(in: app)
        assertTransportAndTimelineControls(in: app)
        exerciseInspectorKeyframing(in: app)
        exerciseTrackVisibilityHistory(in: app)
        exercisePlayheadKeyboardNavigation(in: app)

        XCTAssertTrue(window.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func assertInitialProjectChrome(in app: XCUIApplication) {
        XCTAssertTrue(
            app.otherElements["Program monitor showing Sample Playback Sequence"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["Sequence tab bar"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["Sequence tab Sample Playback Sequence"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["New Sequence"].waitForExistence(timeout: 5))
    }

    private func exerciseSequenceTabs(in app: XCUIApplication) {
        app.buttons["New Sequence"].click()
        XCTAssertTrue(app.buttons["Sequence tab Sequence 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close Sequence"].isEnabled)

        app.buttons["Sequence tab Sample Playback Sequence"].click()
        XCTAssertTrue(app.buttons["Sequence tab Sequence 2"].waitForExistence(timeout: 5))

        app.buttons["Sequence tab Sequence 2"].click()
        app.buttons["Close Sequence"].click()
        XCTAssertFalse(app.buttons["Sequence tab Sequence 2"].exists)
    }

    private func assertTransportAndTimelineControls(in app: XCUIApplication) {
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
        XCTAssertTrue(app.buttons["Clip Sample Playback Clip"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Mute Audio track 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Solo Audio track 1"].waitForExistence(timeout: 5))
    }

    private func exerciseInspectorKeyframing(in app: XCUIApplication) {
        app.buttons["Select all Video track 1"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["Transform Inspector"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["Track Compositing Inspector"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["Track Opacity Percent"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["Track Blend Mode"]
                .waitForExistence(timeout: 5)
        )
        let positionXField = app.descendants(matching: .any)["Transform Position X"]
        XCTAssertTrue(positionXField.waitForExistence(timeout: 5))
        positionXField.click()
        positionXField.typeKey("a", modifierFlags: [.command])
        positionXField.typeText("8")
        app.typeKey(.return, modifierFlags: [])
        let positionKeyframeToggle = app.descendants(matching: .any)[
            "Transform Position Keyframe Toggle"
        ]
        XCTAssertTrue(positionKeyframeToggle.waitForExistence(timeout: 5))
        positionKeyframeToggle.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["Transform keyframe lanes"]
                .waitForExistence(timeout: 5)
        )
    }

    private func exerciseTrackVisibilityHistory(in app: XCUIApplication) {
        app.buttons["Hide Video track 1"].click()
        XCTAssertTrue(app.buttons["Show Video track 1"].waitForExistence(timeout: 5))

        app.typeKey("z", modifierFlags: [.command])
        XCTAssertTrue(app.buttons["Hide Video track 1"].waitForExistence(timeout: 5))

        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["Show Video track 1"].waitForExistence(timeout: 5))
    }

    private func exercisePlayheadKeyboardNavigation(in app: XCUIApplication) {
        let playheadReadout = app.staticTexts["Playhead readout"]
        XCTAssertTrue(playheadReadout.waitForExistence(timeout: 5))
        assertPlayheadValue("Frame 0", on: playheadReadout)

        app.typeKey(.rightArrow, modifierFlags: [])
        assertPlayheadValue("Frame 1", on: playheadReadout)

        app.typeKey(.leftArrow, modifierFlags: [])
        assertPlayheadValue("Frame 0", on: playheadReadout)
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

    private func launchAppWithRetry(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> XCUIApplication {
        var launchFailures: [String] = []

        for attempt in 1...Self.launchAttemptLimit {
            let candidate = XCUIApplication()
            candidate.launchEnvironment["EDITOR_AJAR_UI_SMOKE_LAUNCH_ATTEMPT"] = "\(attempt)"
            candidate.launch()

            let windowAppeared = candidate.windows.firstMatch.waitForExistence(
                timeout: Self.launchWindowTimeout
            )
            let state = candidate.state

            if windowAppeared && state == .runningForeground {
                return candidate
            }

            let failure = "Attempt \(attempt): state=\(state), windowAppeared=\(windowAppeared)"
            launchFailures.append(failure)
            recordLaunchRetry(failure)

            candidate.terminate()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: Self.launchRetryDelay))
        }

        XCTFail(
            "Editor Ajar did not launch after \(Self.launchAttemptLimit) attempts:\n"
                + launchFailures.joined(separator: "\n"),
            file: file,
            line: line
        )
        throw EditorAjarUISmokeLaunchError.failed(launchFailures)
    }

    private func recordLaunchRetry(_ message: String) {
        XCTContext.runActivity(named: "UI smoke launch retry") { activity in
            activity.add(XCTAttachment(string: message))
        }
    }
}

private enum EditorAjarUISmokeLaunchError: Error {
    case failed([String])
}
