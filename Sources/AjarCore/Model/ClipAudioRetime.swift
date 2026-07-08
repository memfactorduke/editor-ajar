// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How retimed clip audio treats pitch (FR-SPD-001).
public enum ClipAudioRetimeMode: String, Codable, Equatable, Sendable {
    /// Varispeed: samples are resampled at the retimed rate, shifting pitch with speed.
    /// This is the historical behavior and the decode default for legacy projects.
    case pitchShifted

    /// Time-scale modification: the source stream is stretched by the clip's constant speed
    /// with a deterministic WSOLA stage, preserving the original pitch.
    case pitchCorrected
}

/// Typed validation errors for the FR-SPD-001 audio retime composition policy.
public enum ClipAudioRetimeValidationError: Error, Equatable, Sendable,
    CustomStringConvertible {
    /// Pitch-corrected audio cannot combine with a freeze frame: a freeze holds one source
    /// instant, so there is no source stream to time-stretch.
    case pitchCorrectedConflictsWithFreezeFrame

    /// Pitch-corrected audio cannot combine with an FR-SPD-002 time-remap curve: variable-rate
    /// stretching is out of scope for the v1 constant-speed WSOLA stage.
    case pitchCorrectedConflictsWithTimeRemap

    /// A human-readable description of the validation failure.
    public var description: String {
        switch self {
        case .pitchCorrectedConflictsWithFreezeFrame:
            "pitch-corrected audio cannot combine with freezeFrame; a freeze holds one "
                + "source instant"
        case .pitchCorrectedConflictsWithTimeRemap:
            "pitch-corrected audio cannot combine with a time-remap curve; variable-rate "
                + "stretching is not supported"
        }
    }
}

public extension Clip {
    /// Validates the FR-SPD-001 audio retime composition policy.
    ///
    /// Mirrors the FR-SPD-002 `conflictingRetime` policy: `pitchCorrected` is rejected with a
    /// typed error alongside `freezeFrame` or a `timeRemap` curve rather than silently playing
    /// pitch-shifted audio. `reverse` composes — the WSOLA stage stretches the reversed source
    /// stream — and unit speed is the exact identity.
    func validateAudioRetime() -> ClipAudioRetimeValidationError? {
        guard audioMix.retimeMode == .pitchCorrected else {
            return nil
        }
        if freezeFrame {
            return .pitchCorrectedConflictsWithFreezeFrame
        }
        if timeRemap != nil {
            return .pitchCorrectedConflictsWithTimeRemap
        }
        return nil
    }
}
