// SPDX-License-Identifier: GPL-3.0-or-later
//
// ============================================================================================
//  ajar — headless CLI: render / inspect / benchmark / golden-frame harness.
// ============================================================================================
//
//  Purpose (see docs/TESTING.md and ADR-0011/ADR-0014):
//    The `ajar` tool drives the engine without a GUI so the autonomous loop can verify pixels
//    (golden-frame), audio, and performance benchmarks deterministically. Planned subcommands:
//      ajar version
//      ajar inspect <project.ajar>
//      ajar render  --frame <t> <project.ajar> -o <png>
//      ajar bench   <project.ajar> <metric>
//      ajar golden  <suite>
//
//  Links AjarCore + AjarRender + AjarMedia + AjarAudio.
//
//  STATUS: scaffold only. Implementation begins at ROADMAP M2 (when the render graph + compositor
//  land). Intentional placeholder — no command logic yet.
