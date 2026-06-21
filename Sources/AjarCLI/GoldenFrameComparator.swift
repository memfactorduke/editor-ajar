// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Explicit tolerances for one golden-frame comparison.
public struct GoldenFrameTolerance: Codable, Equatable, Sendable {
    /// Maximum CIE76 delta-E allowed for any pixel.
    public let maximumDeltaE: Double

    /// Minimum luminance SSIM score across the frame.
    public let minimumSSIM: Double

    /// Maximum alpha-channel byte delta.
    public let maximumAlphaDelta: UInt8

    /// Creates comparison tolerances.
    public init(
        maximumDeltaE: Double,
        minimumSSIM: Double,
        maximumAlphaDelta: UInt8 = 0
    ) {
        self.maximumDeltaE = maximumDeltaE
        self.minimumSSIM = minimumSSIM
        self.maximumAlphaDelta = maximumAlphaDelta
    }
}

/// Result of a perceptual golden-frame comparison.
public struct GoldenFrameComparison: Equatable, Sendable {
    /// Whether the frame passed all tolerances.
    public let passed: Bool

    /// Maximum CIE76 delta-E observed.
    public let maximumDeltaE: Double

    /// Luminance SSIM score.
    public let ssim: Double

    /// Maximum alpha-channel byte delta observed.
    public let maximumAlphaDelta: UInt8

    /// Heatmap image showing pixel differences.
    public let diffImage: PNGImage
}

/// Golden-frame comparator for TESTING Section 2 and ADR-0011.
public enum GoldenFrameComparator {
    /// Compares two BGRA8 images with explicit perceptual tolerances.
    public static func compare(
        actual: PNGImage,
        reference: PNGImage,
        tolerance: GoldenFrameTolerance
    ) throws -> GoldenFrameComparison {
        guard actual.width == reference.width, actual.height == reference.height else {
            throw AjarCLIError.pngFailed(
                "image dimensions differ: actual \(actual.width)x\(actual.height), "
                    + "reference \(reference.width)x\(reference.height)"
            )
        }
        guard actual.bgra8.count == reference.bgra8.count else {
            throw AjarCLIError.pngFailed("image byte counts differ")
        }

        let pixelCount = actual.width * actual.height
        var maximumDeltaE = 0.0
        var maximumAlphaDelta: UInt8 = 0
        var actualLuma = [Double]()
        var referenceLuma = [Double]()
        var diffBytes = [UInt8](repeating: 0, count: actual.bgra8.count)
        actualLuma.reserveCapacity(pixelCount)
        referenceLuma.reserveCapacity(pixelCount)

        for pixelIndex in 0..<pixelCount {
            let byteIndex = pixelIndex * 4
            let actualPixel = BGRAPixel(bytes: actual.bgra8, offset: byteIndex)
            let referencePixel = BGRAPixel(bytes: reference.bgra8, offset: byteIndex)
            let deltaE = cie76(actualPixel.lab, referencePixel.lab)
            maximumDeltaE = max(maximumDeltaE, deltaE)

            let alphaDelta = UInt8(
                abs(Int(actualPixel.alpha) - Int(referencePixel.alpha))
            )
            maximumAlphaDelta = max(maximumAlphaDelta, alphaDelta)
            actualLuma.append(actualPixel.luma)
            referenceLuma.append(referencePixel.luma)

            let heat = UInt8(min(255.0, (deltaE / max(tolerance.maximumDeltaE, 1.0)) * 255.0))
            diffBytes[byteIndex] = 0
            diffBytes[byteIndex + 1] = UInt8(max(0, 255 - Int(heat)))
            diffBytes[byteIndex + 2] = heat
            diffBytes[byteIndex + 3] = 255
        }

        let ssim = structuralSimilarity(actual: actualLuma, reference: referenceLuma)
        let passed = maximumDeltaE <= tolerance.maximumDeltaE
            && ssim >= tolerance.minimumSSIM
            && maximumAlphaDelta <= tolerance.maximumAlphaDelta

        return GoldenFrameComparison(
            passed: passed,
            maximumDeltaE: maximumDeltaE,
            ssim: ssim,
            maximumAlphaDelta: maximumAlphaDelta,
            diffImage: PNGImage(width: actual.width, height: actual.height, bgra8: diffBytes)
        )
    }
}

private struct BGRAPixel {
    let blue: UInt8
    let green: UInt8
    let red: UInt8
    let alpha: UInt8

    init(bytes: [UInt8], offset: Int) {
        blue = bytes[offset]
        green = bytes[offset + 1]
        red = bytes[offset + 2]
        alpha = bytes[offset + 3]
    }

    var lab: LabColor {
        LabColor(red: red, green: green, blue: blue)
    }

    var luma: Double {
        0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
    }
}

private struct LabColor {
    let lightness: Double
    let a: Double
    let b: Double

    init(red: UInt8, green: UInt8, blue: UInt8) {
        let linearRed = Self.linear(Double(red) / 255.0)
        let linearGreen = Self.linear(Double(green) / 255.0)
        let linearBlue = Self.linear(Double(blue) / 255.0)

        let x = (0.412_456_4 * linearRed) + (0.357_576_1 * linearGreen) + (0.180_437_5 * linearBlue)
        let y = (0.212_672_9 * linearRed) + (0.715_152_2 * linearGreen) + (0.072_175_0 * linearBlue)
        let z = (0.019_333_9 * linearRed) + (0.119_192_0 * linearGreen) + (0.950_304_1 * linearBlue)

        let fx = Self.labPivot(x / 0.950_47)
        let fy = Self.labPivot(y)
        let fz = Self.labPivot(z / 1.088_83)

        lightness = (116.0 * fy) - 16.0
        a = 500.0 * (fx - fy)
        b = 200.0 * (fy - fz)
    }

    private static func linear(_ value: Double) -> Double {
        if value <= 0.040_45 {
            return value / 12.92
        }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    private static func labPivot(_ value: Double) -> Double {
        if value > 0.008_856 {
            return pow(value, 1.0 / 3.0)
        }
        return (7.787 * value) + (16.0 / 116.0)
    }
}

private func cie76(_ left: LabColor, _ right: LabColor) -> Double {
    let lightness = left.lightness - right.lightness
    let a = left.a - right.a
    let b = left.b - right.b
    return sqrt((lightness * lightness) + (a * a) + (b * b))
}

private func structuralSimilarity(actual: [Double], reference: [Double]) -> Double {
    guard actual.count == reference.count, !actual.isEmpty else {
        return 0
    }

    let count = Double(actual.count)
    let actualMean = actual.reduce(0, +) / count
    let referenceMean = reference.reduce(0, +) / count
    var actualVariance = 0.0
    var referenceVariance = 0.0
    var covariance = 0.0

    for index in actual.indices {
        let actualDelta = actual[index] - actualMean
        let referenceDelta = reference[index] - referenceMean
        actualVariance += actualDelta * actualDelta
        referenceVariance += referenceDelta * referenceDelta
        covariance += actualDelta * referenceDelta
    }

    actualVariance /= count
    referenceVariance /= count
    covariance /= count

    let c1 = 6.5025
    let c2 = 58.5225
    let numerator = ((2 * actualMean * referenceMean) + c1) * ((2 * covariance) + c2)
    let denominator = ((actualMean * actualMean) + (referenceMean * referenceMean) + c1)
        * (actualVariance + referenceVariance + c2)
    guard denominator != 0 else {
        return 0
    }

    return numerator / denominator
}
