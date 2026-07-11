// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import Foundation

/// Linear gain ↔ dB helpers and gesture phases for mixer / clip audio UI (FR-AUD-001/003).
enum AudioMixUISupport {
    /// Default monitoring master gain (unity). Session-only — not project schema.
    static let defaultMasterGainLinear = 1.0

    /// Fader range in decibels for track/clip/master controls.
    static let minimumGainDB = -60.0
    static let maximumGainDB = 12.0

    /// Converts a linear gain to dB. Silence maps to `minimumGainDB`.
    static func gainDB(fromLinear linear: Double) -> Double {
        guard linear.isFinite, linear > 0 else {
            return minimumGainDB
        }
        let db = 20.0 * log10(linear)
        return min(maximumGainDB, max(minimumGainDB, db))
    }

    /// Converts dB to linear gain, clamped to document limits.
    static func linearGain(fromDB db: Double) -> RationalValue {
        let clampedDB = min(maximumGainDB, max(minimumGainDB, db))
        if clampedDB <= minimumGainDB {
            return AudioMixLimits.minimumGain
        }
        let linear = pow(10.0, clampedDB / 20.0)
        let clampedLinear = min(
            AudioMixLimits.maximumGain.doubleValue,
            max(AudioMixLimits.minimumGain.doubleValue, linear)
        )
        return RationalValue.approximating(clampedLinear)
    }

    /// Formats a gain for inspector fields (`0.0 dB`, `-6.0 dB`).
    static func gainDBString(fromLinear linear: Double) -> String {
        let db = gainDB(fromLinear: linear)
        return String(format: "%.1f", db)
    }

    /// Parses an inspector dB string into linear gain.
    static func linearGain(fromDBString raw: String) -> RationalValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let db = Double(trimmed), db.isFinite else {
            return nil
        }
        return linearGain(fromDB: db)
    }

    /// Formats pan for inspector fields (`0.00`, `-1.00`…`1.00`).
    static func panString(from value: RationalValue) -> String {
        String(format: "%.2f", value.doubleValue)
    }

    /// Parses a pan field into a clamped rational.
    static func pan(fromString raw: String) -> RationalValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite else {
            return nil
        }
        let clamped = min(
            AudioMixLimits.maximumPan.doubleValue,
            max(AudioMixLimits.minimumPan.doubleValue, value)
        )
        return RationalValue.approximating(clamped)
    }

    /// Default crossfade duration when the menu command has no duration field (~0.5 s).
    static func defaultCrossfadeDuration(timebase: FrameRate) -> RationalTime {
        let frames = max(1, timebase.frames / (2 * max(1, timebase.seconds)))
        return (try? timebase.duration(ofFrames: frames)) ?? .zero
    }

    /// Default fade duration for menu commands (~0.25 s).
    static func defaultFadeDuration(timebase: FrameRate) -> RationalTime {
        let frames = max(1, timebase.frames / (4 * max(1, timebase.seconds)))
        return (try? timebase.duration(ofFrames: frames)) ?? .zero
    }

    /// Converts whole seconds into timeline time for the sequence timebase.
    static func duration(seconds: Double, timebase: FrameRate) -> RationalTime? {
        guard seconds.isFinite, seconds >= 0 else {
            return nil
        }
        let frames = Int64((seconds * Double(timebase.frames) / Double(timebase.seconds)).rounded())
        return try? timebase.duration(ofFrames: max(0, frames))
    }
}

/// Gesture phase for one undo step per continuous fader/pan/fade drag (coalescing discipline).
enum AudioMixGesturePhase: Equatable, Sendable {
    /// Single discrete edit (text field commit, button, menu).
    case discrete

    /// First sample of a continuous gesture.
    case began

    /// Intermediate sample during a continuous gesture.
    case changed

    /// Final sample when the gesture ends.
    case ended
}

/// Identity of the in-flight audio mix gesture for undo coalescing.
enum AudioMixGestureKey: Equatable, Sendable {
    case trackGain(UUID)
    case trackPan(UUID)
    case masterGain
    case clipGain(UUID)
    case clipPan(UUID)
    case clipFadeIn(UUID)
    case clipFadeOut(UUID)
}

/// Snapshot of off-RT meter levels for the mixer UI (FR-AUD-003).
///
/// Produced only on the meter analysis queue via `AudioMixerMeterAnalyzer` — never on the
/// real-time audio callback (ADR-0012 / FR-AUD-007).
struct MixerMeterSnapshot: Equatable, Sendable {
    /// Per-track peak / RMS levels keyed by track id.
    let trackLevels: [UUID: [AudioMeterChannelLevel]]

    /// Master bus peak / RMS levels (one entry per channel).
    let mixLevels: [AudioMeterChannelLevel]

    /// Master true-peak linear amplitude from offline BS.1770 analysis, when available.
    let masterTruePeak: Double?

    /// Whether any master channel is clipping (peak ≥ 1.0 or true-peak ≥ 1.0).
    var isMasterClipping: Bool {
        if let masterTruePeak, masterTruePeak >= 1.0 {
            return true
        }
        return mixLevels.contains { $0.peak >= 1.0 }
    }

    /// Whether a track channel is clipping.
    func isTrackClipping(_ trackID: UUID) -> Bool {
        (trackLevels[trackID] ?? []).contains { $0.peak >= 1.0 }
    }

    static let empty = MixerMeterSnapshot(
        trackLevels: [:],
        mixLevels: [],
        masterTruePeak: nil
    )
}
