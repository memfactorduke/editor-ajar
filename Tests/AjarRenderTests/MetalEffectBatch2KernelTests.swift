// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Metal
import XCTest

@testable import AjarRender

/// FR-FX-002 batch-2 kernel seams: hardcoded uniforms bypass model and render-graph carry.
final class MetalEffectBatch2KernelTests: XCTestCase {
    func testFRFX002KernelVignetteChangesMidToneCheckerboard() throws {
        try assertBatch2KernelChanges(name: "vignette") { executor, source in
            try executor.encodeVignetteKernelForTests(
                amount: 0.75,
                radius: 0.5,
                softness: 0.25,
                source: source
            )
        }
    }

    func testFRFX002KernelMirrorAllAxesChangeAsymmetricMidToneCheckerboard() throws {
        for axisMode in [Float(0), Float(1), Float(2)] {
            try assertBatch2KernelChanges(name: "mirror axis \(axisMode)") { executor, source in
                try executor.encodeMirrorKernelForTests(axisMode: axisMode, source: source)
            }
        }
    }

    func testFRFX002KernelMosaicChangesMidToneCheckerboard() throws {
        try assertBatch2KernelChanges(name: "mosaic") { executor, source in
            try executor.encodeMosaicKernelForTests(cellSize: 12, source: source)
        }
    }

    func testFRFX002KernelColorAdjustChangesMidToneCheckerboard() throws {
        try assertBatch2KernelChanges(name: "colorAdjust") { executor, source in
            try executor.encodeColorAdjustKernelForTests(
                brightness: 0.1,
                contrast: 1.2,
                saturation: 0.8,
                tint: 0.2,
                source: source
            )
        }
    }

    func testFRFX002KernelPosterizeChangesMidToneCheckerboard() throws {
        try assertBatch2KernelChanges(name: "posterize") { executor, source in
            try executor.encodePosterizeKernelForTests(levels: 4, source: source)
        }
    }

    func testFRFX002KernelInvertChangesMidToneCheckerboard() throws {
        try assertBatch2KernelChanges(name: "invert") { executor, source in
            try executor.encodeInvertKernelForTests(source: source)
        }
    }

    func testFRFX002Batch2RGBMathPreservesPremultipliedAlphaContract() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let source = try makeBatch2TranslucentCheckerboard(device: device, size: 24)
        let executor = try MetalRenderExecutor(device: device)
        let identity = try executor.applyEffectStackForTests(.empty, to: source)
        let definitions = try premultiplyAwareBatch2Definitions()

        for (name, definition) in definitions {
            let stack = ClipEffectStack(
                nodes: [
                    ClipEffectNode(id: try effectStackUUID(6_410), definition: definition)
                ]
            )
            let output = try executor.applyEffectStackForTests(stack, to: source)
            assertPremultipliedAlpha(output, matches: identity, effectName: name)
        }
    }
}

private func assertBatch2KernelChanges(
    name: String,
    encode: (MetalRenderExecutor, MTLTexture) throws -> [UInt8]
) throws {
    let device = try effectStackMetalDeviceOrSkip()
    let source = try makeCheckerboardTexture(device: device, size: 96, cellSize: 7)
    let executor = try MetalRenderExecutor(device: device)
    let identity = try executor.applyEffectStackForTests(.empty, to: source)
    let output = try encode(executor, source)
    let fraction = changedPixelFraction(
        left: identity,
        right: output,
        channelDeltaThreshold: 2
    )
    XCTAssertGreaterThan(
        fraction,
        0.01,
        "\(name) kernel must change >1% of mid-tone checkerboard pixels (got \(fraction))"
    )
}

private func premultiplyAwareBatch2Definitions() throws -> [(String, ClipEffectDefinition)] {
    [
        (
            "vignette",
            .vignette(
                ClipVignetteParameters(
                    amount: try RationalValue(numerator: 3, denominator: 4),
                    radius: try RationalValue(numerator: 1, denominator: 2),
                    softness: try RationalValue(numerator: 1, denominator: 4)
                )
            )
        ),
        (
            "colorAdjust",
            .colorAdjust(
                ClipColorAdjustParameters(
                    brightness: .zero,
                    contrast: try RationalValue(numerator: 4, denominator: 5),
                    saturation: try RationalValue(numerator: 4, denominator: 5),
                    tint: try RationalValue(numerator: 1, denominator: 10)
                )
            )
        ),
        ("posterize", .posterize(ClipPosterizeParameters(levels: RationalValue(4)))),
        ("invert", .invert(ClipInvertParameters()))
    ]
}

private func makeBatch2TranslucentCheckerboard(
    device: MTLDevice,
    size: Int
) throws -> MTLTexture {
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
    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw EffectStackDiscriminationError.textureUnavailable
    }
    pixels.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else {
            return
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: base,
            bytesPerRow: size * 4
        )
    }
    return texture
}

private func assertPremultipliedAlpha(
    _ output: [UInt8],
    matches identity: [UInt8],
    effectName: String
) {
    XCTAssertEqual(output.count, identity.count)
    var index = 0
    while index < output.count {
        let alpha = output[index + 3]
        XCTAssertEqual(alpha, identity[index + 3], "\(effectName) changed alpha")
        XCTAssertLessThanOrEqual(output[index], alpha, "\(effectName) blue exceeds alpha")
        XCTAssertLessThanOrEqual(output[index + 1], alpha, "\(effectName) green exceeds alpha")
        XCTAssertLessThanOrEqual(output[index + 2], alpha, "\(effectName) red exceeds alpha")
        index += 4
    }
}
