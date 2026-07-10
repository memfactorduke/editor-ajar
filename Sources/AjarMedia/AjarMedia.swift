// SPDX-License-Identifier: GPL-3.0-or-later
//
// ============================================================================================
//  AjarMedia — media I/O (macOS). AVFoundation/VideoToolbox fast path + FFmpeg import boundary.
// ============================================================================================
//
//  Responsibilities (see docs/ARCHITECTURE.md §6 and ADR-0003):
//    • Hardware decode of H.264 / HEVC / ProRes via VideoToolbox/AVFoundation
//    • Probe + conform sources (incl. variable frame rate — FR-MED-010)
//    • FFmpeg import boundary: transcode exotic formats to ProRes on ingest; NEVER on the
//      playback hot path (ADR-0003)
//    • Proxy / optimized media generation (FR-MED-004)
//    • Source decoding injected into AjarExport (ADR-0019); no export-session orchestration here
//
//  Depends on AjarCore; AjarCore never depends on this (ADR-0005). FFmpeg integration must stay
//  GPL-compatible (ADR-0004).
//
//  STATUS: native decode is implemented; probe/import/proxy work continues in ROADMAP M9.
