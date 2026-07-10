# EditorAjar (app)

The macOS application — a **thin SwiftUI/AppKit shell** over the engine modules (ADR-0005). It
holds windows, panels, the inspector, gestures, and drag-and-drop, but **no editing logic** (that
lives in `AjarCore`).

The Xcode app project is created here at **ROADMAP M2** (the walking-skeleton milestone). It links
the SwiftPM libraries defined in the root `Package.swift` without adding the app as a SwiftPM
product, so the package remains headless-testable.

## Build and run

Requirements:

- Xcode 26 or newer with macOS 14 SDK support.
- `xcodegen` 2.45 or newer if regenerating the project from `project.yml`.

The generated project is checked in:

```sh
open app/EditorAjar/EditorAjar.xcodeproj
```

Then select the `EditorAjar` scheme and run it. The shell opens a synthetic single-clip
`AjarCore.Project`, decodes it through `AjarMedia`, renders it through `AjarRender`, and presents
the resulting Metal texture in the program monitor.

To regenerate the project after editing `project.yml`:

```sh
xcodegen --spec app/EditorAjar/project.yml --project app/EditorAjar
```

Command-line verification:

```sh
xcodebuild -project app/EditorAjar/EditorAjar.xcodeproj -scheme EditorAjar -destination 'platform=macOS' build
# CI default plan (skips canvas edit/nudge smokes — #210; guides toggle still runs):
xcodebuild -project app/EditorAjar/EditorAjar.xcodeproj -scheme EditorAjar \
  -testPlan EditorAjarCI -destination 'platform=macOS' test
# Full local UI-smoke including canvas edit/nudge:
xcodebuild -project app/EditorAjar/EditorAjar.xcodeproj -scheme EditorAjar \
  -testPlan EditorAjarLocal -destination 'platform=macOS' test
```

The `EditorAjar` scheme includes the XCUITest smoke target. **EditorAjarCI** (scheme default /
CI) skips flaky canvas edit/nudge cases (#210) but keeps the safe-area guides toggle smoke.
**EditorAjarLocal** runs the full set. Root `swift test` does not run this app UI target.

## M2 controls

- Play/pause button: starts or stops the display-link playback loop (FR-PLAY-001).
- Step backward / step forward buttons: move one frame, render that frame, and pause playback.
- Scrub slider: moves the playhead to the selected frame and renders it (FR-PLAY-003).
- Keyboard: space toggles play/pause; left/right arrows step by one frame.
- Accessibility: transport controls and panels are VoiceOver-labelled for NFR-A11Y-001.

## Canvas title controls (FR-TXT-003)

- Click a visible title box to edit with the native macOS text system; Escape or Command-Return
  exits editing, and Tab/Shift-Tab moves between title boxes.
- Drag a box to reposition it. Boxes snap to the action-safe/title-safe edges and canvas center.
- With a title box keyboard-focused, arrows nudge by 1 canvas unit and Shift-arrows nudge by 10.
- The program-monitor guide button toggles 90% action-safe and 80% title-safe overlays. These
  guides are app overlays only and are never part of render/export output.
- Canvas title boxes and their editors have stable VoiceOver labels and identifiers.
