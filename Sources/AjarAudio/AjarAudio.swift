// SPDX-License-Identifier: GPL-3.0-or-later
//
// ============================================================================================
//  AjarAudio — real-time audio engine (macOS). Core Audio / AVAudioEngine graph.
// ============================================================================================
//
//  Responsibilities (see docs/ARCHITECTURE.md §7 and ADR-0012):
//    • Multitrack mixer mirroring the timeline: player → effects → track mixer → master
//    • Keyframable volume/pan, fades/crossfades, ducking, metering (SPEC §6.8 / area AUD)
//    • Audio effects: EQ / compressor / limiter / denoise
//    • A/V sync master clock for playback (ARCHITECTURE §5)
//
//  Hard constraint (ADR-0012): the audio render thread is real-time, lock-free, and
//  allocation-free. No Swift heap allocation, locks, or dynamic dispatch on the callback.
//
//  Depends on AjarCore; AjarCore never depends on this (ADR-0005).
//
//  STATUS: scaffold only. Implementation begins at ROADMAP M6. Intentional placeholder.
