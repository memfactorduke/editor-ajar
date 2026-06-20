# EditorAjar (app)

The macOS application — a **thin SwiftUI/AppKit shell** over the engine modules (ADR-0005). It
holds windows, panels, the inspector, gestures, and drag-and-drop, but **no editing logic** (that
lives in `AjarCore`).

The Xcode app project is created here at **ROADMAP M2** (the walking-skeleton milestone). It links
the `AjarCore`, `AjarRender`, `AjarMedia`, and `AjarAudio` libraries defined in the root
`Package.swift`.

_Empty until M2 — this README marks the intended location._
