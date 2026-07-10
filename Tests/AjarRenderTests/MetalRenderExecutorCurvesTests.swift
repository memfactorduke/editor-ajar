// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import XCTest

@testable import AjarRender

/// FR-COL-002 GPU color-curves coverage (device-or-skip).
final class MetalRenderExecutorCurvesTests: XCTestCase {
    func testFRCOL002IdentityCurvesAreBitIdenticalPassthrough() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let size = 16
        let source = try makeCheckerboardTexture(device: device, size: size, cellSize: 4)
        let executor = try MetalRenderExecutor(device: device)

        let without = try executor.applyEffectStackForTests(.empty, to: source)
        let identityStrengthOne = try executor.applyEffectStackForTests(
            ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: try effectStackUUID(6_500),
                        definition: .curves(
                            ClipCurvesEffectParameters(strength: .one)
                        )
                    )
                ]
            ),
            to: source
        )
        let strengthZero = try executor.applyEffectStackForTests(
            ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: try effectStackUUID(6_501),
                        definition: .curves(
                            ClipCurvesEffectParameters(
                                rgb: .rgbSCurve,
                                strength: .zero
                            )
                        )
                    )
                ]
            ),
            to: source
        )

        XCTAssertEqual(without, identityStrengthOne)
        XCTAssertEqual(without, strengthZero)
        XCTAssertEqual(
            ContentHash.sha256(data: Data(without)),
            ContentHash.sha256(data: Data(identityStrengthOne))
        )
    }

    /// Master-only S-curve remaps every channel; means of R, G, and B must all move.
    func testFRCOL002KernelRGBSCurveChangesCheckerboard() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let source = try makeCheckerboardTexture(device: device, size: 96, cellSize: 8)
        let executor = try MetalRenderExecutor(device: device)
        let identity = try executor.applyEffectStackForTests(.empty, to: source)
        let curved = try executor.encodeCurvesKernelForTests(
            parameters: ClipCurvesEffectParameters(rgb: .rgbSCurve, strength: .one),
            strength: 1,
            source: source
        )
        let fraction = changedPixelFraction(
            left: identity,
            right: curved,
            channelDeltaThreshold: 2
        )
        XCTAssertGreaterThan(
            fraction,
            0.01,
            "RGB S-curve kernel must change >1% of pixels (got \(fraction))"
        )

        // Channel-mapping guard: master applies to R, G, and B — all three means must change
        // (a swapped ramp packing would leave some channels frozen).
        let disabledMeans = bgraChannelMeans(identity)
        let curvedMeans = bgraChannelMeans(curved)
        let minMeanDelta: Double = 1.0 / 255.0
        XCTAssertGreaterThan(
            abs(curvedMeans.red - disabledMeans.red),
            minMeanDelta,
            "master S-curve must change red mean (got Δ\(abs(curvedMeans.red - disabledMeans.red)))"
        )
        XCTAssertGreaterThan(
            abs(curvedMeans.green - disabledMeans.green),
            minMeanDelta,
            """
            master S-curve must change green mean \
            (got Δ\(abs(curvedMeans.green - disabledMeans.green)))
            """
        )
        XCTAssertGreaterThan(
            abs(curvedMeans.blue - disabledMeans.blue),
            minMeanDelta,
            """
            master S-curve must change blue mean \
            (got Δ\(abs(curvedMeans.blue - disabledMeans.blue)))
            """
        )
    }

    /// Red-lift must move only red; green/blue means stay within 1/255 of the disabled frame.
    func testFRCOL002KernelRedLiftChangesCheckerboard() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let source = try makeCheckerboardTexture(device: device, size: 96, cellSize: 8)
        let executor = try MetalRenderExecutor(device: device)
        let identity = try executor.applyEffectStackForTests(.empty, to: source)
        let curved = try executor.encodeCurvesKernelForTests(
            parameters: ClipCurvesEffectParameters(red: .redLift, strength: .one),
            strength: 1,
            source: source
        )
        let fraction = changedPixelFraction(
            left: identity,
            right: curved,
            channelDeltaThreshold: 2
        )
        XCTAssertGreaterThan(
            fraction,
            0.01,
            "red-lift kernel must change >1% of pixels (got \(fraction))"
        )

        // Channel-mapping guard: red ramp is texture R; mis-binding G/B would leak into them.
        let disabledMeans = bgraChannelMeans(identity)
        let curvedMeans = bgraChannelMeans(curved)
        let maxUnchangedDelta: Double = 1.0 / 255.0
        XCTAssertGreaterThan(
            abs(curvedMeans.red - disabledMeans.red),
            maxUnchangedDelta,
            "red-lift must change red mean (got Δ\(abs(curvedMeans.red - disabledMeans.red)))"
        )
        XCTAssertLessThanOrEqual(
            abs(curvedMeans.green - disabledMeans.green),
            maxUnchangedDelta,
            """
            red-lift must leave green mean within 1/255 of disabled \
            (got Δ\(abs(curvedMeans.green - disabledMeans.green)))
            """
        )
        XCTAssertLessThanOrEqual(
            abs(curvedMeans.blue - disabledMeans.blue),
            maxUnchangedDelta,
            """
            red-lift must leave blue mean within 1/255 of disabled \
            (got Δ\(abs(curvedMeans.blue - disabledMeans.blue)))
            """
        )
    }

    func testFRCOL002PremultiplyAwareAlphaPreserved() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let size = 24
        let colorA: [UInt8] = [32, 48, 80, 128]
        let colorB: [UInt8] = [80, 48, 32, 128]
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for pixel in 0..<(size * size) {
            let color = pixel.isMultiple(of: 2) ? colorA : colorB
            let offset = pixel * 4
            pixels.replaceSubrange(offset..<(offset + 4), with: color)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let source = device.makeTexture(descriptor: descriptor) else {
            throw EffectStackDiscriminationError.textureUnavailable
        }
        pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                return
            }
            source.replace(
                region: MTLRegionMake2D(0, 0, size, size),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: size * 4
            )
        }
        let executor = try MetalRenderExecutor(device: device)
        let identity = try executor.applyEffectStackForTests(.empty, to: source)
        let curved = try executor.applyEffectStackForTests(
            ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: try effectStackUUID(6_510),
                        definition: .curves(
                            ClipCurvesEffectParameters(
                                rgb: .rgbSCurve,
                                red: .redLift,
                                strength: .one
                            )
                        )
                    )
                ]
            ),
            to: source
        )
        XCTAssertEqual(curved.count, identity.count)
        var index = 0
        while index < curved.count {
            XCTAssertEqual(curved[index + 3], identity[index + 3], "curves changed alpha")
            XCTAssertLessThanOrEqual(curved[index], curved[index + 3])
            XCTAssertLessThanOrEqual(curved[index + 1], curved[index + 3])
            XCTAssertLessThanOrEqual(curved[index + 2], curved[index + 3])
            index += 4
        }
    }
}

// MARK: - Channel statistics (BGRA8 readback)

/// Per-channel means over a BGRA8 buffer (R = offset+2, G = +1, B = +0).
private struct BGRAChannelMeans {
    let red: Double
    let green: Double
    let blue: Double
}

private func bgraChannelMeans(_ bgra: [UInt8]) -> BGRAChannelMeans {
    precondition(bgra.count % 4 == 0, "BGRA buffer length must be a multiple of 4")
    let pixelCount = bgra.count / 4
    guard pixelCount > 0 else {
        return BGRAChannelMeans(red: 0, green: 0, blue: 0)
    }
    var sumRed = 0.0
    var sumGreen = 0.0
    var sumBlue = 0.0
    var index = 0
    while index < bgra.count {
        sumBlue += Double(bgra[index])
        sumGreen += Double(bgra[index + 1])
        sumRed += Double(bgra[index + 2])
        index += 4
    }
    let count = Double(pixelCount)
    return BGRAChannelMeans(red: sumRed / count, green: sumGreen / count, blue: sumBlue / count)
}
