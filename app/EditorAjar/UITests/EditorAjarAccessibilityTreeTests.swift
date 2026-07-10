// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

/// Durable NFR-A11Y-001 regression net: launch the app and walk the accessibility tree.
///
/// **Read-only** — no clicks, typing, or sheet presentation. That keeps the case runner-robust
/// compared with interaction-heavy canvas smokes (#210). Every element with an interactive AX
/// role must carry a non-empty accessibility label. Failures list identifier + role + frame.
///
/// Covered at launch: workspace chrome, sequence tabs, program monitor, transport, timeline,
/// track headers/clips, and any canvas title boxes in the sample project. Conditional surfaces
/// (export dialog, export queue jobs, marker/transform inspector, read-only banner) are
/// documented in `docs/ACCESSIBILITY.md` and rely on the same labelling conventions.
final class EditorAjarAccessibilityTreeTests: XCTestCase {
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
        if let launchedApp,
            launchedApp.state == .runningForeground || launchedApp.state == .runningBackground
        {
            launchedApp.terminate()
        }
        launchedApp = nil
    }

    func testNFRA11Y001InteractiveAXElementsHaveNonEmptyLabels() throws {
        let app = try XCTUnwrap(launchedApp)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Role-agnostic wait for stable sample-project chrome (#187 lesson).
        XCTAssertTrue(
            app.descendants(matching: .any)["Program monitor showing Sample Playback Sequence"]
                .waitForExistence(timeout: 15)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["Transport controls"]
                .waitForExistence(timeout: 10)
        )

        let offenders = unlabeledInteractiveElements(in: app)
        if !offenders.isEmpty {
            let report = offenders.map(\.description).joined(separator: "\n")
            XCTFail(
                "NFR-A11Y-001: \(offenders.count) interactive AX element(s) missing a non-empty label:\n\(report)"
            )
        }
    }

    // MARK: - AX tree walk (read-only)

    private struct AXOffender: CustomStringConvertible {
        let identifier: String
        let role: String
        let frame: CGRect
        let labelPreview: String

        var description: String {
            let idPart = identifier.isEmpty ? "<no-identifier>" : identifier
            let framePart =
                "frame=(\(Int(frame.origin.x)),\(Int(frame.origin.y)) "
                + "\(Int(frame.size.width))×\(Int(frame.size.height)))"
            let labelPart = labelPreview.isEmpty ? "<empty>" : "\"\(labelPreview)\""
            return "  • id=\(idPart) role=\(role) \(framePart) label=\(labelPart)"
        }
    }

    /// Interactive roles that must always expose a VoiceOver label (NFR-A11Y-001).
    ///
    /// **Not listed (deliberately):**
    /// - `.valueIndicator` — read-only system sub-elements (NSScroller thumbs, slider
    ///   value indicators). CI #219 on macos-14 reported 4 unlabeled valueIndicators, all
    ///   AppKit chrome (edge geometry matching scroller thumbs, plus a 12×28 slider
    ///   indicator). They are never user-labelled app controls.
    /// - `.scrollBar` itself — not an interactive control we label; its button children
    ///   are filtered out via `scrollBarFrames` containment (see below).
    private static let interactiveElementTypes: [XCUIElement.ElementType] = [
        .button,
        .checkBox,
        .switch,
        .toggle,
        .slider,
        .popUpButton,
        .comboBox,
        .textField,
        .secureTextField,
        .textView,
        .searchField,
        .radioButton,
        .segmentedControl,
        .stepper,
        .menuButton,
        .menuItem,
        .tab,
        .link,
        .incrementArrow,
        .decrementArrow,
        .handle,
    ]

    private func unlabeledInteractiveElements(in app: XCUIApplication) -> [AXOffender] {
        var offenders: [AXOffender] = []
        var seenKeys = Set<String>()

        // Scope: `app.descendants` is the app under test only — system menu-bar items
        // (Apple menu, status items, etc.) live in other processes and are not walked.
        // Editor Ajar's own menu items (`.menuItem`) remain in scope and must be labelled.
        //
        // Exclusions (AppKit-generated chrome only — real unlabelled app controls still fail):
        // 1. Zero-size / off-tree nodes (width or height < 1).
        // 2. System window traffic lights (close / minimize / zoom / full screen).
        // 3. Any element whose frame is contained in an `.scrollBar` frame — NSScroller
        //    track segments and thumb buttons surface as role=button with no labels.
        //    CI #219 macos-14: 6 unlabeled buttons at right edge (x≈1481, w=15) and
        //    bottom edge (y≈832, h=15). Descendant-of checks are awkward on a flat
        //    per-type walk, so we collect scrollbar frames first and use containment.
        // We do NOT exclude by missing identifier or by size alone beyond zero-area.
        let scrollBarFrames = collectScrollBarFrames(in: app)

        for elementType in Self.interactiveElementTypes {
            let query = app.descendants(matching: elementType)
            let count = query.count
            for index in 0..<count {
                let element = query.element(boundBy: index)
                guard element.exists else {
                    continue
                }

                // Skip zero-size / off-tree noise nodes.
                let frame = element.frame
                if frame.width < 1 || frame.height < 1 {
                    continue
                }

                // System window chrome (traffic lights) is outside app control.
                if isSystemWindowChrome(element) {
                    continue
                }

                // NSScroller track/thumb chrome (see scrollBarFrames comment above).
                if isFrameContainedInAnyScrollBar(frame, scrollBarFrames: scrollBarFrames) {
                    continue
                }

                let label = normalizedAccessibilityLabel(element)
                if !label.isEmpty {
                    continue
                }

                let identifier = element.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                let role = roleName(elementType)
                let key = "\(identifier)|\(role)|\(Int(frame.origin.x)),\(Int(frame.origin.y))"
                if seenKeys.contains(key) {
                    continue
                }
                seenKeys.insert(key)

                offenders.append(
                    AXOffender(
                        identifier: identifier,
                        role: role,
                        frame: frame,
                        labelPreview: label
                    )
                )
            }
        }

        return offenders.sorted { lhs, rhs in
            if lhs.identifier != rhs.identifier {
                return lhs.identifier < rhs.identifier
            }
            return lhs.role < rhs.role
        }
    }

    /// Frames of every `.scrollBar` in the app tree (used to exclude scroller chrome).
    private func collectScrollBarFrames(in app: XCUIApplication) -> [CGRect] {
        let query = app.descendants(matching: .scrollBar)
        let count = query.count
        var frames: [CGRect] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let element = query.element(boundBy: index)
            guard element.exists else {
                continue
            }
            let frame = element.frame
            if frame.width < 1 || frame.height < 1 {
                continue
            }
            frames.append(frame)
        }
        return frames
    }

    /// True when `frame` is fully inside any collected scrollbar frame (descendant chrome).
    private func isFrameContainedInAnyScrollBar(
        _ frame: CGRect,
        scrollBarFrames: [CGRect]
    ) -> Bool {
        for scrollBarFrame in scrollBarFrames {
            if scrollBarFrame.contains(frame) {
                return true
            }
        }
        return false
    }

    private func normalizedAccessibilityLabel(_ element: XCUIElement) -> String {
        // Prefer the AX label; fall back to title (some macOS controls only populate title).
        let candidates = [element.label, element.title]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    private func isSystemWindowChrome(_ element: XCUIElement) -> Bool {
        let identifier = element.identifier.lowercased()
        let label = element.label.lowercased()
        let systemIdentifiers = [
            "_xcui",
            "closebutton",
            "miniaturizebutton",
            "zoombutton",
            "fullscreenbutton",
        ]
        if systemIdentifiers.contains(where: { identifier.contains($0) }) {
            return true
        }
        let systemLabels = ["close", "minimize", "zoom", "full screen"]
        if systemLabels.contains(label) {
            return true
        }
        return false
    }

    private func roleName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: return "button"
        case .checkBox: return "checkBox"
        case .switch: return "switch"
        case .toggle: return "toggle"
        case .slider: return "slider"
        case .popUpButton: return "popUpButton"
        case .comboBox: return "comboBox"
        case .textField: return "textField"
        case .secureTextField: return "secureTextField"
        case .textView: return "textView"
        case .searchField: return "searchField"
        case .radioButton: return "radioButton"
        case .segmentedControl: return "segmentedControl"
        case .stepper: return "stepper"
        case .menuButton: return "menuButton"
        case .menuItem: return "menuItem"
        case .tab: return "tab"
        case .link: return "link"
        case .incrementArrow: return "incrementArrow"
        case .decrementArrow: return "decrementArrow"
        case .handle: return "handle"
        default: return "elementType(\(type.rawValue))"
        }
    }

    // MARK: - Launch (shared pattern with UI smoke)

    private func launchAppWithRetry(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> XCUIApplication {
        var launchFailures: [String] = []

        for attempt in 1...Self.launchAttemptLimit {
            let candidate = XCUIApplication()
            candidate.launchEnvironment["EDITOR_AJAR_UI_TESTING"] = "1"
            candidate.launchEnvironment["EDITOR_AJAR_UI_SMOKE_LAUNCH_ATTEMPT"] = "\(attempt)"
            candidate.launchEnvironment["EDITOR_AJAR_AX_TREE_WALK"] = "1"
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
            XCTContext.runActivity(named: "AX tree walk launch retry") { activity in
                activity.add(XCTAttachment(string: failure))
            }

            candidate.terminate()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: Self.launchRetryDelay))
        }

        XCTFail(
            "Editor Ajar did not launch after \(Self.launchAttemptLimit) attempts:\n"
                + launchFailures.joined(separator: "\n"),
            file: file,
            line: line
        )
        throw EditorAjarAXTreeLaunchError.failed(launchFailures)
    }
}

private enum EditorAjarAXTreeLaunchError: Error {
    case failed([String])
}
