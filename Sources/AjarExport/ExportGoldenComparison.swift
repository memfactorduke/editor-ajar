// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Tightly packed BGRA8 frame used by export golden / determinism compares (FR-EXP-007).
public struct ExportDecodedBGRAFrame: Equatable, Sendable {
    /// Pixel width.
    public let width: Int

    /// Pixel height.
    public let height: Int

    /// Tightly packed BGRA8 bytes (`width * height * 4`), no row padding.
    public let bgra8: Data

    /// Creates a packed BGRA8 frame.
    public init(width: Int, height: Int, bgra8: Data) {
        self.width = width
        self.height = height
        self.bgra8 = bgra8
    }

    /// Expected packed byte count for this raster.
    public var expectedByteCount: Int {
        width * height * 4
    }

    /// Premultiplied-over-opaque-black presentation: RGB unchanged, alpha forced to 255.
    ///
    /// Matches non-alpha codec decode (`AVAssetReader` → 32BGRA synthesizes `A=255`). Title
    /// generators leave transparent canvas (ADR-0017); golden expectations must flatten so
    /// channel-wise compare is not dominated by alpha `0` vs `255`.
    public func flattenedOverOpaqueBlack() -> ExportDecodedBGRAFrame {
        var bytes = bgra8
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            let pixelCount = width * height
            for pixel in 0..<pixelCount {
                base[pixel * 4 + 3] = 255
            }
        }
        return ExportDecodedBGRAFrame(width: width, height: height, bgra8: bytes)
    }
}

/// Codec-appropriate pixel tolerances for export golden round-trips (FR-EXP-007).
///
/// Comparison is against the **render-path delivery BGRA** expectation (same vImage packing as
/// H.264 encoder input / still PNG), not against container bitstream bytes. Encoded containers
/// are decoded back to 8-bit BGRA before comparison.
///
/// ## Tolerance bands (justification)
///
/// - **ProRes 422 (near-lossless):** Apple ProRes 422 is a visually lossless mezzanine codec.
///   Round-tripping through encode → decode into 8-bit BGRA still admits (a) 4:2:2 chroma
///   reconstruction error on high-frequency chroma edges and (b) ≤1–2 LSB of 8-bit rounding
///   after 10-bit internal paths. Solid / low-detail title fixtures stay well inside a **max
///   channel delta of 3** and a **mean absolute channel error of 1.0** on 8-bit samples. This
///   is intentionally tight — a wrong graph, wrong color tag, or proxy substitution blows past
///   it immediately.
/// - **H.264 / HEVC (lossy):** Hardware VideoToolbox encoders use irreversible quantization.
///   Even at high quality / moderate bit rate on a 64×64 title, block edges and chroma can
///   move by tens of 8-bit counts. The band is **max channel delta 48** and **mean absolute
///   error 12.0** — wide enough for codec noise, still failing on swapped colors or black
///   frames. These cases are **capability-gated** (see `ExportError.isHardwareEncoderUnavailable`)
///   so CI VMs without a free H.264/HEVC session skip rather than fail.
/// - **Still PNG (bit-exact):** FR-EXP-004 PNG stills are lossless containers of the delivery
///   BGRA buffer. After decode with the same delivery color space, every byte must match.
public struct ExportGoldenTolerance: Equatable, Sendable {
    /// Maximum allowed absolute per-channel byte difference at any pixel.
    public let maximumChannelDelta: UInt8

    /// Maximum allowed mean absolute channel error across all bytes (0...255 scale).
    public let maximumMeanAbsoluteError: Double

    /// When true, requires exact byte equality (still PNG).
    public let requireExactMatch: Bool

    /// Creates an explicit tolerance band.
    public init(
        maximumChannelDelta: UInt8,
        maximumMeanAbsoluteError: Double,
        requireExactMatch: Bool = false
    ) {
        self.maximumChannelDelta = maximumChannelDelta
        self.maximumMeanAbsoluteError = maximumMeanAbsoluteError
        self.requireExactMatch = requireExactMatch
    }

    /// Near-lossless ProRes 422 decoded-BGRA band (see type docs).
    ///
    /// Validated on Apple Silicon hardware 2026-07-10 for the 64×64 title fixture after
    /// expectations are flattened over opaque black (title canvas is transparent; ProRes 422
    /// decode synthesizes `A=255`). RGB stays inside maxΔ=3 / mae 1.0. Do not loosen for
    /// video-range concerns — measured evidence did not require it.
    public static let proRes422NearLossless = ExportGoldenTolerance(
        maximumChannelDelta: 3,
        maximumMeanAbsoluteError: 1.0,
        requireExactMatch: false
    )

    /// Lossy H.264 decoded-BGRA band (see type docs).
    public static let h264Lossy = ExportGoldenTolerance(
        maximumChannelDelta: 48,
        maximumMeanAbsoluteError: 12.0,
        requireExactMatch: false
    )

    /// Lossy HEVC decoded-BGRA band (same quantizer class as H.264 for this fixture size).
    public static let hevcLossy = ExportGoldenTolerance(
        maximumChannelDelta: 48,
        maximumMeanAbsoluteError: 12.0,
        requireExactMatch: false
    )

    /// Bit-exact still PNG vs delivery BGRA (FR-EXP-004 / FR-EXP-007).
    public static let stillPNGBitExact = ExportGoldenTolerance(
        maximumChannelDelta: 0,
        maximumMeanAbsoluteError: 0,
        requireExactMatch: true
    )

    /// Default band for a video codec used by the golden-export harness.
    public static func forVideoCodec(_ codec: ExportVideoCodec) -> ExportGoldenTolerance {
        switch codec {
        case .proRes422, .proRes422HQ, .proRes4444:
            .proRes422NearLossless
        case .h264:
            .h264Lossy
        case .hevc8Bit, .hevc10Bit:
            .hevcLossy
        }
    }
}

/// Result of comparing one decoded export frame to a render-path expectation.
public struct ExportGoldenComparison: Equatable, Sendable {
    /// Whether all tolerance criteria passed.
    public let passed: Bool

    /// Maximum absolute per-channel delta observed.
    public let maximumChannelDelta: UInt8

    /// Mean absolute channel error across all bytes.
    public let meanAbsoluteError: Double

    /// Optional diagnostic when dimensions or lengths disagree.
    public let diagnostic: String?

    /// Creates a comparison result.
    public init(
        passed: Bool,
        maximumChannelDelta: UInt8,
        meanAbsoluteError: Double,
        diagnostic: String? = nil
    ) {
        self.passed = passed
        self.maximumChannelDelta = maximumChannelDelta
        self.meanAbsoluteError = meanAbsoluteError
        self.diagnostic = diagnostic
    }
}

/// Compares decoded export frames to render-path BGRA expectations (FR-EXP-007).
public enum ExportGoldenComparator {
    /// Compares two packed BGRA8 frames under `tolerance`.
    public static func compare(
        actual: ExportDecodedBGRAFrame,
        expected: ExportDecodedBGRAFrame,
        tolerance: ExportGoldenTolerance
    ) -> ExportGoldenComparison {
        guard actual.width == expected.width, actual.height == expected.height else {
            return ExportGoldenComparison(
                passed: false,
                maximumChannelDelta: 255,
                meanAbsoluteError: 255,
                diagnostic:
                    "dimensions differ: actual \(actual.width)x\(actual.height), "
                    + "expected \(expected.width)x\(expected.height)"
            )
        }
        guard actual.bgra8.count == expected.bgra8.count,
            actual.bgra8.count == actual.expectedByteCount
        else {
            return ExportGoldenComparison(
                passed: false,
                maximumChannelDelta: 255,
                meanAbsoluteError: 255,
                diagnostic:
                    "byte counts differ: actual \(actual.bgra8.count), "
                    + "expected \(expected.bgra8.count)"
            )
        }

        if tolerance.requireExactMatch {
            let equal = actual.bgra8 == expected.bgra8
            return ExportGoldenComparison(
                passed: equal,
                maximumChannelDelta: equal ? 0 : 255,
                meanAbsoluteError: equal ? 0 : 255,
                diagnostic: equal ? nil : "bit-exact still PNG mismatch"
            )
        }

        var maximumDelta: UInt8 = 0
        var absoluteSum: Double = 0
        let count = actual.bgra8.count
        for index in 0..<count {
            let delta = abs(Int(actual.bgra8[index]) - Int(expected.bgra8[index]))
            maximumDelta = max(maximumDelta, UInt8(min(255, delta)))
            absoluteSum += Double(delta)
        }
        let mean = count == 0 ? 0 : absoluteSum / Double(count)
        let passed = maximumDelta <= tolerance.maximumChannelDelta
            && mean <= tolerance.maximumMeanAbsoluteError
        return ExportGoldenComparison(
            passed: passed,
            maximumChannelDelta: maximumDelta,
            meanAbsoluteError: mean
        )
    }

    /// Compares ordered frame sequences; fails on first mismatch or length disagreement.
    public static func compareSequences(
        actual: [ExportDecodedBGRAFrame],
        expected: [ExportDecodedBGRAFrame],
        tolerance: ExportGoldenTolerance
    ) -> ExportGoldenComparison {
        guard actual.count == expected.count else {
            return ExportGoldenComparison(
                passed: false,
                maximumChannelDelta: 255,
                meanAbsoluteError: 255,
                diagnostic:
                    "frame counts differ: actual \(actual.count), expected \(expected.count)"
            )
        }
        var worst = ExportGoldenComparison(
            passed: true,
            maximumChannelDelta: 0,
            meanAbsoluteError: 0
        )
        for index in actual.indices {
            let comparison = compare(
                actual: actual[index],
                expected: expected[index],
                tolerance: tolerance
            )
            if comparison.maximumChannelDelta > worst.maximumChannelDelta
                || comparison.meanAbsoluteError > worst.meanAbsoluteError {
                worst = ExportGoldenComparison(
                    passed: comparison.passed && worst.passed,
                    maximumChannelDelta: max(
                        worst.maximumChannelDelta,
                        comparison.maximumChannelDelta
                    ),
                    meanAbsoluteError: max(worst.meanAbsoluteError, comparison.meanAbsoluteError),
                    diagnostic: comparison.diagnostic.map { "frame \(index): \($0)" }
                        ?? worst.diagnostic
                )
            } else if !comparison.passed {
                worst = ExportGoldenComparison(
                    passed: false,
                    maximumChannelDelta: worst.maximumChannelDelta,
                    meanAbsoluteError: worst.meanAbsoluteError,
                    diagnostic: comparison.diagnostic.map { "frame \(index): \($0)" }
                        ?? "frame \(index) failed tolerance"
                )
            }
        }
        return worst
    }
}

/// Hashes **decoded** pixel (and optional audio) buffers for export determinism (FR-EXP-007).
///
/// Container bytes are **not** hashed: AVAssetWriter timestamps / encoder metadata can differ
/// across runs even when pixels are identical. Hash the tightly packed BGRA of every decoded
/// frame (and optional Float32 interleaved PCM) instead.
public enum ExportDecodedPixelHasher {
    /// SHA-256 over one packed BGRA8 frame.
    public static func hashFrame(_ frame: ExportDecodedBGRAFrame) -> ContentHash {
        ContentHash.sha256(data: frame.bgra8)
    }

    /// SHA-256 over the concatenation of every packed BGRA8 frame in order.
    ///
    /// A 4-byte big-endian width/height header precedes each frame so dimension swaps cannot
    /// collide with a pure pixel concatenation.
    public static func hashFrames(_ frames: [ExportDecodedBGRAFrame]) -> ContentHash {
        var payload = Data()
        payload.reserveCapacity(frames.reduce(0) { $0 + 8 + $1.bgra8.count })
        for frame in frames {
            appendUInt32(UInt32(frame.width), to: &payload)
            appendUInt32(UInt32(frame.height), to: &payload)
            payload.append(frame.bgra8)
        }
        return ContentHash.sha256(data: payload)
    }

    /// SHA-256 over tightly packed little-endian Float32 interleaved PCM samples.
    public static func hashAudioPCM(_ samples: [Float]) -> ContentHash {
        var data = Data(count: samples.count * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else {
                return
            }
            for (index, sample) in samples.enumerated() {
                base[index] = sample
            }
        }
        return ContentHash.sha256(data: data)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
