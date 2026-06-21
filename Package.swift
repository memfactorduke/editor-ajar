// swift-tools-version: 5.9
//
// Editor Ajar — an open, native, fast video editor for macOS.
// Copyright (C) 2026  Editor Ajar contributors. Licensed under GPL-3.0-or-later (see LICENSE).
//
// Module split is defined by ADR-0005 (headless core / thin UI). The dependency rule is:
//   EditorAjar(app) → {AjarRender, AjarMedia, AjarAudio} → AjarCore → (nothing in-project)
// AjarCore MUST NOT import AppKit/SwiftUI/Metal/AVFoundation — enforced in CI (ADR-0011).
//
// The macOS app (app/EditorAjar) is built with Xcode and consumes these libraries; it is not a
// SwiftPM product here so the package stays buildable/testable headlessly (incl. on CI without a
// full app build).

import PackageDescription

let package = Package(
    name: "EditorAjar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AjarCore", targets: ["AjarCore"]),
        .library(name: "AjarRender", targets: ["AjarRender"]),
        .library(name: "AjarMedia", targets: ["AjarMedia"]),
        .library(name: "AjarAudio", targets: ["AjarAudio"]),
        .executable(name: "ajar", targets: ["ajar-cli"]),
    ],
    targets: [
        // Pure-Swift, platform-agnostic source of truth. No UI, no GPU. Fully unit-testable.
        .target(
            name: "AjarCore",
            path: "Sources/AjarCore"
        ),

        // Metal compositor: executes the render graph from AjarCore (ADR-0006, ADR-0009).
        .target(
            name: "AjarRender",
            dependencies: ["AjarCore"],
            path: "Sources/AjarRender"
        ),

        // AVFoundation/VideoToolbox decode/encode + FFmpeg import boundary (ADR-0003).
        .target(
            name: "AjarMedia",
            dependencies: ["AjarCore"],
            path: "Sources/AjarMedia"
        ),

        // Core Audio / AVAudioEngine real-time audio graph (ADR-0012 §audio).
        .target(
            name: "AjarAudio",
            dependencies: ["AjarCore"],
            path: "Sources/AjarAudio"
        ),

        // Testable implementation for the `ajar` executable.
        .target(
            name: "AjarCLI",
            dependencies: ["AjarCore", "AjarRender", "AjarMedia"],
            path: "Sources/AjarCLI"
        ),

        // `ajar`: headless render / inspect / benchmark / golden-frame harness (TESTING, ADR-0011).
        .executableTarget(
            name: "ajar-cli",
            dependencies: ["AjarCLI"],
            path: "Sources/ajar-cli"
        ),

        // Tests. AjarCore tests are fast + headless; AjarRender tests are golden-frame (need GPU).
        .testTarget(
            name: "AjarCoreTests",
            dependencies: ["AjarCore"],
            path: "Tests/AjarCoreTests"
        ),
        .testTarget(
            name: "AjarMediaTests",
            dependencies: ["AjarMedia", "AjarCore"],
            path: "Tests/AjarMediaTests"
        ),
        .testTarget(
            name: "AjarRenderTests",
            dependencies: ["AjarRender", "AjarCore"],
            path: "Tests/AjarRenderTests"
        ),
        .testTarget(
            name: "AjarCLITests",
            dependencies: ["AjarCLI", "AjarCore"],
            path: "Tests/AjarCLITests"
        ),
    ]
)
