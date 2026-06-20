// SPDX-License-Identifier: GPL-3.0-or-later
//
// ============================================================================================
//  AjarMedia — media I/O (macOS). AVFoundation/VideoToolbox fast path + FFmpeg import boundary.
// ============================================================================================
//
//  Responsibilities (see docs/ARCHITECTURE.md §6 and ADR-0003):
//    • Hardware decode/encode of H.264 / HEVC / ProRes via VideoToolbox/AVFoundation
//    • Probe + conform sources (incl. variable frame rate — FR-MED-010)
//    • FFmpeg import boundary: transcode exotic formats to ProRes on ingest; NEVER on the
//      playback hot path (ADR-0003)
//    • Proxy / optimized media generation (FR-MED-004)
//    • Export muxing + correct color tagging (SPEC §6.13)
//
//  Depends on AjarCore; AjarCore never depends on this (ADR-0005). FFmpeg integration must stay
//  GPL-compatible (ADR-0004).
//
//  STATUS: scaffold only. Implementation begins at ROADMAP M2 (decode) / M9 (export, proxies).
//  Intentional placeholder.
