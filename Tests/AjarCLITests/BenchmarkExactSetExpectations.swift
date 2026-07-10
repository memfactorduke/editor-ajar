// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Hand-maintained metric → requirement-ID map asserted by
/// `testBenchmarkAllEmitsReportOnlyPerformanceJSON`.
///
/// Intentionally a literal (not derived from `BenchmarkMetric.allCases`) so adding or renaming a
/// benchmark metric forces a deliberate, reviewed update here — the exact-set guard against
/// silently dropping or mis-tagging a gated performance metric.
let benchmarkExpectedRequirementIDs: [String: String] = [
    "single-frame-render-seek-latency": "NFR-PERF-005",
    "project-open-decode-load": "NFR-PERF-002",
    "cold-start-proxy": "NFR-PERF-001",
    "multi-layer-transform-playback": "NFR-PERF-003",
    "two-layer-chroma-key-choke-4k30-playback": "NFR-PERF-004",
    "scope-analyzer-compute": "FR-COL-003",
    "disk-cache-warm-start-playback": "FR-PLAY-005",
    "retimed-constant-2x-playback-fr-spd-005": "FR-SPD-005",
    "retimed-constant-half-speed-playback-fr-spd-005": "FR-SPD-005",
    "retimed-time-remap-ramp-playback-fr-spd-005": "FR-SPD-005",
    "retimed-reverse-playback-fr-spd-005": "FR-SPD-005",
    "retimed-freeze-frame-playback-fr-spd-005": "FR-SPD-005",
    "retimed-frame-blend-half-speed-playback-fr-spd-005": "FR-SPD-005",
    "retimed-nested-compound-playback-fr-spd-005": "FR-SPD-005",
    "rt-audio-plan-build-retimed-fr-spd-005": "FR-SPD-005",
    "rt-audio-plan-build-nested-compound-fr-aud-007": "FR-AUD-007",
    "rt-audio-plan-build-wide-timeline-fr-aud-007": "FR-AUD-007",
    "effect-node-gaussian-blur-1080p-fr-fx-002": "FR-FX-002",
    "effect-node-box-blur-1080p-fr-fx-002": "FR-FX-002",
    "effect-node-zoom-blur-1080p-fr-fx-002": "FR-FX-002",
    "effect-node-sharpen-1080p-fr-fx-002": "FR-FX-002",
    "effect-node-glow-1080p-fr-fx-002": "FR-FX-002",
    "effect-node-lut-gpu-fr-col-004": "FR-COL-004",
    "effect-node-vignette-1080p-fr-fx-002": "FR-FX-002",
    "effect-node-mirror-1080p-fr-fx-002": "FR-FX-002",
    "effect-node-mosaic-1080p-fr-fx-002": "FR-FX-002",
    "effect-node-color-adjust-1080p-fr-fx-002": "FR-FX-002",
    "effect-node-posterize-1080p-fr-fx-002": "FR-FX-002",
    "effect-node-invert-1080p-fr-fx-002": "FR-FX-002",
    "effect-node-curves-gpu-fr-col-002": "FR-COL-002",
    "transition-cross-dissolve-1080p-fr-fx-001": "FR-FX-001",
    "transition-dip-fade-1080p-fr-fx-001": "FR-FX-001",
    "transition-push-slide-1080p-fr-fx-001": "FR-FX-001",
    "transition-wipe-1080p-fr-fx-001": "FR-FX-001",
    "transition-zoom-1080p-fr-fx-001": "FR-FX-001",
    "typical-stack-1080p-playback-m8-exit": "NFR-PERF-003",
    "title-node-styled-1080p-fr-txt-001": "FR-TXT-001",
    "proxy-playback-heavy-original-fr-med-004": "FR-MED-004",
    "proxy-playback-heavy-proxy-fr-med-004": "FR-MED-004"
]
