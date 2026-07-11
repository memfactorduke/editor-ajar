// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// App-side defaults for still-image timeline media (FR-MED-002 / #246).
///
/// **Why not project-persisted:** still placement length is an import/timeline convenience, not a
/// creative project setting like resolution or frame rate. Keeping it process-wide avoids a
/// `schemaMinor` bump (ADR-0018) and matches FR-PROJ-003, which auto-detects resolution/fps/color/
/// audio from first media but does not own still duration. Callers that need a different length
/// trim after insert.
///
/// **Source extent vs placement:** the probe stamps ``sourceExtentDuration`` on
/// `MediaMetadata.duration` so trims can extend a still well past the default placement.
/// ``defaultDuration`` is only the initial timeline insert length (5 s).
public enum StillMediaDefaults: Sendable {
    /// Default still timeline placement length in whole seconds (wall-clock).
    public static let defaultDurationSeconds: Int64 = 5

    /// Effectively unbounded still source extent (24 h) stored as `MediaMetadata.duration`.
    ///
    /// Stills are time-invariant; a large declared extent lets editors extend clips past the
    /// 5 s default without inventing a separate max-trim field.
    public static let sourceExtentSeconds: Int64 = 24 * 60 * 60

    /// Codec IDs produced by ``AVFoundationMediaProbe`` for ImageIO stills.
    public static let stillCodecIDs: Set<String> = [
        "png", "jpeg", "heif", "tiff", "gif", "image"
    ]

    /// Filename extensions accepted as native stills at the AjarMedia boundary.
    public static let stillPathExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif"
    ]

    /// Default still timeline placement duration (`5/1` seconds).
    public static func defaultDuration() throws -> RationalTime {
        try RationalTime(value: defaultDurationSeconds, timescale: 1)
    }

    /// Declared still source extent (`86400/1` seconds) for media metadata / trim bounds.
    public static func sourceExtentDuration() throws -> RationalTime {
        try RationalTime(value: sourceExtentSeconds, timescale: 1)
    }

    /// Whether `codecID` is a known still-image codec from the native probe.
    public static func isStillCodec(_ codecID: String) -> Bool {
        stillCodecIDs.contains(codecID.lowercased())
    }

    /// Whether `url` looks like a native still by path extension (case-insensitive).
    public static func isStillImageFile(_ url: URL) -> Bool {
        stillPathExtensions.contains(url.pathExtension.lowercased())
    }
}
