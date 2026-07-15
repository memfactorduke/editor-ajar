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
            launchedApp.state == .runningForeground || launchedApp.state == .runningBackground
        {
            // Leave canvas title edit mode so a failed/local FR-TXT test cannot steal
            // keyboard focus from later smoke cases (e.g. transport arrows).
            restoreCanvasTitleUIState(in: launchedApp)
            launchedApp.terminate()
        }

        launchedApp = nil
    }

    func testROADMAPM2NFRA11Y001LaunchesAndExercisesTransportControls() throws {
        let app = try XCTUnwrap(launchedApp)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any)["Welcome View"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.buttons["Welcome New Project"].exists)
        XCTAssertTrue(app.buttons["Welcome Open Project"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)["Program monitor showing Sample Playback Sequence"]
                .exists
        )
        openSampleProjectFromHelp(in: app)

        assertInitialProjectChrome(in: app)
        exerciseSequenceTabs(in: app)
        assertTransportAndTimelineControls(in: app)
        exerciseInspectorKeyframing(in: app)
        exerciseTrackVisibilityHistory(in: app)
        exercisePlayheadKeyboardNavigation(in: app)

        XCTAssertTrue(window.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testFRPROJ003NewProjectSheetExposesSettingsAndCancelPath() throws {
        let app = try XCTUnwrap(launchedApp)
        let newProjectButton = app.buttons["Welcome New Project"]
        XCTAssertTrue(newProjectButton.waitForExistence(timeout: 10))
        newProjectButton.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["New Project Settings"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.descendants(matching: .any)["Project Resolution"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Project Frame Rate"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Project Color Space"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Project Audio Sample Rate"].exists)
        XCTAssertTrue(app.buttons["Create New Project"].exists)

        let cancelButton = app.buttons["Cancel New Project"]
        XCTAssertTrue(cancelButton.exists)
        cancelButton.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["Welcome View"].waitForExistence(timeout: 10)
        )
    }

    func testFRMED008FileMenuExposesAccessibleConsolidateAction() throws {
        let app = try XCTUnwrap(launchedApp)
        openSampleProjectFromHelp(in: app)

        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
        fileMenu.click()
        let consolidate = app.menuItems["Consolidate Media…"]
        XCTAssertTrue(consolidate.waitForExistence(timeout: 5))
        XCTAssertTrue(consolidate.isEnabled)
        // Xcode 15.4 can leave XCUIElement.label empty for NSMenuItem even though
        // the human-readable title above resolves through the accessibility query.
        app.typeKey(.escape, modifierFlags: [])
    }

    // #210 / NFR-A11Y-001 canvas edit smoke — **local-only**.
    //
    // Why not un-gated for CI (honest verdict): this path depends on NSTextView first-responder
    // handoff, FocusState, and typeKey delivery into a canvas-hosted editor. Even with the
    // accumulated #187/#210 lessons (role-agnostic descendants(.any), Title menu Cmd-Opt-E,
    // coordinate-click for non-hittable AX nodes, multi-Esc teardown, explicit -skip-testing
    // composition in ci.yml), edit/commit still flakes on headless macos-14 runners
    // (focus never lands, typed text never commits, or later transport tests lose key events).
    // The durable CI net for labels is `EditorAjarAccessibilityTreeTests` (read-only AX walk).
    // Guides toggle stays on CI because it is a single coordinate-click + existence check.
    //
    // Skip mechanism: EditorAjarCI.xctestplan skippedTests + ci.yml -skip-testing flags
    // (-only-testing overrides plan skips, so both are required). Run fully with:
    //   xcodebuild … -testPlan EditorAjarLocal -only-testing:EditorAjarUITests
    func testFRTXT003EditsCanvasTitleWithKeyboardAndUndoRestoresText() throws {
        let app = try XCTUnwrap(launchedApp)
        openSampleProjectFromHelp(in: app)
        defer { restoreCanvasTitleUIState(in: app) }
        let firstBoxID = "00000000-0000-0000-0000-000000000129"

        // Match older smoke tests: wait for program-monitor chrome before canvas work.
        XCTAssertTrue(
            app.descendants(matching: .any)["Program monitor showing Sample Playback Sequence"]
                .waitForExistence(timeout: 15)
        )

        var firstTitle = canvasTitleBox(firstBoxID, in: app)
        XCTAssertTrue(firstTitle.waitForExistence(timeout: 15))
        waitForElementValue(firstTitle, containing: "Edit me", timeout: 10)
        XCTAssertEqual(firstTitle.label, "Title text box 1, Sample Canvas Title")

        // Prefer Title menu shortcut / AX (see enterCanvasTitleEditMode).
        enterCanvasTitleEditMode(boxID: firstBoxID, in: app)
        var firstEditor = canvasTitleEditor(firstBoxID, in: app)
        XCTAssertTrue(firstEditor.waitForExistence(timeout: 15))

        // Exit + re-enter via Cmd-Opt-E (menu path, no FocusState dependency).
        app.typeKey(.escape, modifierFlags: [])
        firstTitle = canvasTitleBox(firstBoxID, in: app)
        XCTAssertTrue(firstTitle.waitForExistence(timeout: 10))
        app.typeKey("e", modifierFlags: [.command, .option])
        firstEditor = canvasTitleEditor(firstBoxID, in: app)
        if !firstEditor.waitForExistence(timeout: 8) {
            enterCanvasTitleEditMode(boxID: firstBoxID, in: app)
            firstEditor = canvasTitleEditor(firstBoxID, in: app)
            XCTAssertTrue(firstEditor.waitForExistence(timeout: 15))
        }

        // Mirror inspector typing: focus field, select-all, type.
        activateElement(firstEditor)
        firstEditor.typeKey("a", modifierFlags: [.command])
        firstEditor.typeText("Canvas edited")

        // Escape commits; live model already holds typed text. (Tab is flaky headless.)
        app.typeKey(.escape, modifierFlags: [])

        let editedTitle = canvasTitleBox(firstBoxID, in: app)
        XCTAssertTrue(editedTitle.waitForExistence(timeout: 10))
        waitForElementValue(editedTitle, containing: "Canvas edited", timeout: 12)
        app.typeKey("z", modifierFlags: [.command])
        waitForElementValue(editedTitle, containing: "Edit me", timeout: 12)
    }

    // #210 / NFR-A11Y-001 canvas drag+nudge smoke — **local-only**.
    //
    // Why not un-gated for CI (honest verdict): genuine drag from an overlay title box and
    // Cmd-Opt-arrow menu nudges both require the canvas box AX node to remain hittable and for
    // menu key equivalents to reach the app while XCUITest owns the session. On CI the box often
    // exists but is not reliably hittable; press-then-drag is ignored; value changes time out.
    // Menu nudges are more stable locally than drag but still race against launch/texture
    // present. Lessons applied (coordinate paths, role-agnostic queries, teardown hygiene)
    // improve local yield; they do not make the case merge-gate safe. Label coverage for the
    // title box is asserted by the read-only AX tree walk instead.
    //
    // Skip mechanism: EditorAjarCI.xctestplan + ci.yml -skip-testing (see edit smoke above).
    func testFRTXT003DragsAndKeyboardNudgesCanvasTitleBox() throws {
        let app = try XCTUnwrap(launchedApp)
        openSampleProjectFromHelp(in: app)
        defer { restoreCanvasTitleUIState(in: app) }
        let boxID = "00000000-0000-0000-0000-000000000129"

        XCTAssertTrue(
            app.descendants(matching: .any)["Program monitor showing Sample Playback Sequence"]
                .waitForExistence(timeout: 15)
        )

        var title = canvasTitleBox(boxID, in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        waitForElementValue(title, containing: "Edit me", timeout: 10)
        let originalValue = elementValue(title)

        // Cmd-Opt-Right → nudgePrimaryCanvasTitleBox (menu, headless-safe like Cmd-Z).
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        waitForElementValueToChange(title, from: originalValue, timeout: 12)
        let afterFirstNudge = elementValue(title)
        XCTAssertTrue(
            afterFirstNudge.contains("X "),
            "Expected origin readout after nudge, got \(afterFirstNudge)"
        )

        // Best-effort genuine drag from element center; if ignored, Cmd-Opt-Down fallback.
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: -40, dy: -24))
        start.press(forDuration: 0.2, thenDragTo: end)

        title = canvasTitleBox(boxID, in: app)
        let dragChanged = waitForElementValueToChangeOptionally(
            title,
            from: afterFirstNudge,
            timeout: 3
        )
        if !dragChanged {
            app.typeKey(.downArrow, modifierFlags: [.command, .option])
            waitForElementValueToChange(title, from: afterFirstNudge, timeout: 12)
        }

        let repositionedValue = elementValue(title)
        XCTAssertNotEqual(repositionedValue, originalValue)

        // Each nudge/drag is its own undo step — walk history back to the sample origin.
        undoCanvasTitleUntilValue(
            title,
            containsAllOf: ["Edit me", "X 70", "Y 50"],
            in: app
        )
    }

    func testFRTXT003TogglesActionAndTitleSafeGuides() throws {
        let app = try XCTUnwrap(launchedApp)
        openSampleProjectFromHelp(in: app)
        let toggle = app.buttons["Canvas Safe Area Guides Toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "Off")

        // Coordinate click bypasses XCUITest's isHittable gate (small toolbar-style control
        // often reports not hittable on CI runners even when the AX node exists).
        let toggleCenter = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        toggleCenter.click()

        let guides = app.descendants(matching: .any)["Canvas Safe Area Guides"]
        XCTAssertTrue(guides.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "On")
        XCTAssertEqual(toggle.label, "Hide Action and Title Safe Guides")
    }

    private func assertInitialProjectChrome(in app: XCUIApplication) {
        // Role-agnostic (Image vs Other/Group); same pattern as Sequence tab bar below.
        XCTAssertTrue(
            app.descendants(matching: .any)["Program monitor showing Sample Playback Sequence"]
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

    private func openSampleProjectFromHelp(in app: XCUIApplication) {
        let monitor = app.descendants(matching: .any)[
            "Program monitor showing Sample Playback Sequence"
        ]
        if monitor.exists {
            return
        }
        let helpMenu = app.menuBars.menuBarItems["Help"]
        XCTAssertTrue(helpMenu.waitForExistence(timeout: 5))
        helpMenu.click()
        let sampleItem = app.menuItems["Open Sample Project"]
        XCTAssertTrue(sampleItem.waitForExistence(timeout: 5))
        sampleItem.click()
        XCTAssertTrue(monitor.waitForExistence(timeout: 15))
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

    /// Exit any open canvas title editor and clear keyboard capture before later tests run.
    private func restoreCanvasTitleUIState(in app: XCUIApplication) {
        guard app.state == .runningForeground || app.state == .runningBackground else {
            return
        }
        // Multiple Escapes: end NSTextView editing, then drop any residual first-responder.
        for _ in 0..<3 {
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        // Click program chrome so playhead/transport typeKey paths receive events again.
        let monitor = app.descendants(matching: .any)[
            "Program monitor showing Sample Playback Sequence"
        ]
        if monitor.exists {
            monitor.click()
        }
    }

    private func canvasTitleBox(_ boxID: String, in app: XCUIApplication) -> XCUIElement {
        let identifier = "Canvas Title Text Box \(boxID.uppercased())"
        // Prefer the button query: boxes advertise .isButton + default accessibilityAction.
        let asButton = app.buttons[identifier]
        if asButton.exists {
            return asButton
        }
        return app.descendants(matching: .any)[identifier]
    }

    private func canvasTitleEditor(_ boxID: String, in app: XCUIApplication) -> XCUIElement {
        let identifier = "Canvas Title Editor \(boxID.uppercased())"
        let asTextView = app.textViews[identifier]
        if asTextView.exists {
            return asTextView
        }
        return app.descendants(matching: .any)[identifier]
    }

    /// Enters edit via Title menu shortcut, then AX button activation, then Return.
    private func enterCanvasTitleEditMode(boxID: String, in app: XCUIApplication) {
        let title = canvasTitleBox(boxID, in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 15))

        // Cmd-Opt-E → editPrimaryCanvasTitleBox (first/selected visible box).
        app.typeKey("e", modifierFlags: [.command, .option])
        if canvasTitleEditor(boxID, in: app).waitForExistence(timeout: 6) {
            return
        }

        // AX default action on the box button.
        activateElement(title)
        if canvasTitleEditor(boxID, in: app).waitForExistence(timeout: 6) {
            return
        }

        // Last resort: focus + Return (onKeyPress → beginEditing).
        activateElement(title)
        app.typeKey(.return, modifierFlags: [])
    }

    private func activateElement(_ element: XCUIElement) {
        if element.isHittable {
            element.click()
            return
        }
        // Non-hittable AX nodes still respond to a center coordinate click on many runners.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private func elementValue(_ element: XCUIElement) -> String {
        element.value as? String ?? "<nil>"
    }

    private func waitForElementValue(
        _ element: XCUIElement,
        containing expectedText: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elementValue(element).contains(expectedText) {
                return
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        XCTFail(
            "Expected \(element.identifier) value to contain \(expectedText), got \(elementValue(element))",
            file: file,
            line: line
        )
    }

    private func waitForElementValueToChange(
        _ element: XCUIElement,
        from originalValue: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let changed = waitForElementValueToChangeOptionally(
            element,
            from: originalValue,
            timeout: timeout
        )
        if !changed {
            XCTFail(
                "Expected \(element.identifier) value to change from \(originalValue)",
                file: file,
                line: line
            )
        }
    }

    @discardableResult
    private func waitForElementValueToChangeOptionally(
        _ element: XCUIElement,
        from originalValue: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elementValue(element) != originalValue {
                return true
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return false
    }

    private func undoCanvasTitleUntilValue(
        _ element: XCUIElement,
        containsAllOf fragments: [String],
        in app: XCUIApplication,
        maxUndos: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<maxUndos {
            let value = elementValue(element)
            if fragments.allSatisfy({ value.contains($0) }) {
                return
            }
            app.typeKey("z", modifierFlags: [.command])
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        }
        let value = elementValue(element)
        if fragments.allSatisfy({ value.contains($0) }) {
            return
        }
        XCTFail(
            "Expected value containing \(fragments) after undo, got \(value)",
            file: file,
            line: line
        )
    }

    private func launchAppWithRetry(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> XCUIApplication {
        var launchFailures: [String] = []

        for attempt in 1...Self.launchAttemptLimit {
            let candidate = XCUIApplication()
            candidate.launchEnvironment["EDITOR_AJAR_UI_TESTING"] = "1"
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
