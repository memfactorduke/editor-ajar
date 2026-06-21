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

Then select the `EditorAjar` scheme and run it. The shell opens a sample `AjarCore.Project` and
shows the M2 NLE skeleton: media/effects panel, program monitor, inspector, transport, and timeline.

To regenerate the project after editing `project.yml`:

```sh
xcodegen --spec app/EditorAjar/project.yml --project app/EditorAjar
```

Command-line verification:

```sh
xcodebuild -project app/EditorAjar/EditorAjar.xcodeproj -scheme EditorAjar -destination 'platform=macOS' build
xcodebuild -project app/EditorAjar/EditorAjar.xcodeproj -scheme EditorAjar -destination 'platform=macOS' test
```

## M2 controls

- Play/pause button: toggles the app shell playback state.
- Step backward / step forward buttons: move one frame and pause playback.
- Keyboard: space toggles play/pause; left/right arrows step by one frame.
- Accessibility: transport controls and panels are VoiceOver-labelled for NFR-A11Y-001.
