// SPDX-License-Identifier: GPL-3.0-or-later
//
// ============================================================================================
//  AjarRender — GPU compositor (macOS). Executes the render graph on Metal.
// ============================================================================================
//
//  Responsibilities (see docs/ARCHITECTURE.md §4 and ADR-0006 / ADR-0009):
//    • Execute AjarCore's RenderGraph as Metal texture operations
//    • Effect / transition / chroma-key / mask shaders (SPEC §6.5, §6.10)
//    • Content-hash render cache (RAM + disk), adaptive preview quality (FR-PLAY-004/005)
//    • Scopes (waveform / vectorscope / parade / histogram — FR-COL-003)
//    • Zero-copy interop with VideoToolbox decode output (ADR-0003); no CPU readback on the
//      playback path (PERFORMANCE §6)
//
//  Depends on AjarCore; AjarCore never depends on this (ADR-0005).
//
//  STATUS: M2 single-source render execution and app presentation are implemented.
