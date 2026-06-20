// SPDX-License-Identifier: GPL-3.0-or-later
//
// ============================================================================================
//  AjarCore — the headless, platform-agnostic engine core.
// ============================================================================================
//
//  Responsibilities (see docs/SPEC.md §6 and docs/ARCHITECTURE.md §3–4):
//    • Data model: Project / Sequence / Track / Clip / TimelineItem (ADR-0008)
//    • Rational time math (exact, drift-free — ADR-0008)
//    • Keyframing & animation evaluation (SPEC §6.4 / area KEY)
//    • Render-graph *description* + content hashing (ADR-0009)
//    • Color math for the managed pipeline (ADR-0010)
//    • .ajar project (de)serialization + migration (ADR-0007)
//
//  Constraint (CI-enforced — ADR-0005 / ADR-0011):
//    AjarCore MUST NOT import AppKit, SwiftUI, Metal, or AVFoundation. It is pure Swift and
//    fully unit-testable on a headless machine.
//
//  STATUS: scaffold only. No types or logic yet — these are produced by the build, starting at
//  ROADMAP milestone M1. This file is an intentional placeholder so the module exists and the
//  package resolves.
