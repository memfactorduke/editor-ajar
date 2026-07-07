// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore

/// Shared golden-manifest spec for one FR-SPD-002 time-remap keyframe.
///
/// Times use the same rational string format as other golden manifest times
/// (`"1/2"` or whole seconds).
struct GoldenTimeRemapKeyframeSpec: Codable, Equatable, Sendable {
    let time: String
    let sourceTime: String
}

extension [GoldenTimeRemapKeyframeSpec] {
    /// Builds a validated `ClipTimeRemap` from manifest keyframe specs.
    func clipTimeRemap() throws -> ClipTimeRemap {
        do {
            return try ClipTimeRemap(
                keyframes: map { spec in
                    TimeRemapKeyframe(
                        time: try GoldenAudioManifest.rationalTime(spec.time),
                        sourceTime: try GoldenAudioManifest.rationalTime(spec.sourceTime)
                    )
                }
            )
        } catch let error as ClipTimeRemapValidationError {
            throw AjarCLIError.invalidGoldenManifest("invalid timeRemap keyframes: \(error)")
        }
    }
}
