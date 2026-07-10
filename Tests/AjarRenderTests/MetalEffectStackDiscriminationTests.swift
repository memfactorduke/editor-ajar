// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import XCTest

@testable import AjarRender

/// FR-FX-002 / NFR-QUAL-001: library effect kernels must change 96×96 checkerboard output in a
/// measurable way, and Gaussian vs box kernels must not collapse to the same field.
final class MetalEffectStackDiscriminationTests: XCTestCase {
    func testFRFX002NFRQUAL001EachLibraryKindChangesCheckerboardVsDisabled() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let size = 96
        let source = try makeCheckerboardTexture(device: device, size: size, cellSize: 8)
        let disabled = try renderEffectStack(
            device: device,
            source: source,
            size: size,
            stack: .empty
        )

        for (name, definition) in try discriminationEffectDefinitions() {
            let stack = ClipEffectStack(
                nodes: [ClipEffectNode(id: try effectStackUUID(6_200), definition: definition)]
            )
            let enabled = try renderEffectStack(
                device: device,
                source: source,
                size: size,
                stack: stack
            )
            let fraction = changedPixelFraction(
                left: disabled,
                right: enabled,
                channelDeltaThreshold: 2
            )
            XCTAssertGreaterThan(
                fraction,
                0.01,
                "\(name) should change >1% of pixels vs disabled (got \(fraction))"
            )
        }
    }

    func testFRFX002NFRQUAL001GaussianBlurDiffersFromBoxBlurAtSameRadius() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let size = 96
        let source = try makeCheckerboardTexture(device: device, size: size, cellSize: 8)
        let radius = RationalValue(4)

        let gaussian = try renderEffectStack(
            device: device,
            source: source,
            size: size,
            stack: singleNodeStack(
                id: try effectStackUUID(6_210),
                definition: .gaussianBlur(ClipGaussianBlurParameters(radius: radius))
            )
        )
        let box = try renderEffectStack(
            device: device,
            source: source,
            size: size,
            stack: singleNodeStack(
                id: try effectStackUUID(6_211),
                definition: .boxBlur(ClipBoxBlurParameters(radius: radius))
            )
        )

        let fraction = changedPixelFraction(
            left: gaussian,
            right: box,
            channelDeltaThreshold: 2
        )
        XCTAssertGreaterThan(
            fraction,
            0.01,
            "gaussian vs box at radius 4 should differ on >1% of pixels (got \(fraction))"
        )
    }

    /// Bypasses `RenderGraph` / composite: applies the stack on the executor's effect path only.
    ///
    /// Isolates shader/bind bugs from graph carry. If this passes for sharpen while the full
    /// graph discrimination fails, the bug is post-stack (composite/cache); if both fail, the
    /// kernel or uniform bind is still wrong (FR-FX-002 / NFR-QUAL-001).
    func testFRFX002NFRQUAL001DirectStackApplySharpenChangesCheckerboard() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let size = 96
        let source = try makeCheckerboardTexture(device: device, size: size, cellSize: 8)
        let executor = try MetalRenderExecutor(device: device)

        let identity = try executor.applyEffectStackForTests(.empty, to: source)
        let sharpened = try executor.applyEffectStackForTests(
            singleNodeStack(
                id: try effectStackUUID(6_220),
                definition: .sharpen(
                    ClipSharpenParameters(
                        amount: try RationalValue(numerator: 1, denominator: 2),
                        radius: RationalValue(1)
                    )
                )
            ),
            to: source
        )

        XCTAssertEqual(identity.count, size * size * 4)
        XCTAssertEqual(sharpened.count, identity.count)
        let fraction = changedPixelFraction(
            left: identity,
            right: sharpened,
            channelDeltaThreshold: 2
        )
        XCTAssertGreaterThan(
            fraction,
            0.01,
            "direct apply of sharpen must change >1% of checkerboard pixels (got \(fraction))"
        )
    }

    /// Direct apply for every library kind (same threshold as the full-graph test).
    func testFRFX002NFRQUAL001DirectStackApplyEachKindChangesCheckerboard() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let size = 96
        let source = try makeCheckerboardTexture(device: device, size: size, cellSize: 8)
        let executor = try MetalRenderExecutor(device: device)
        let identity = try executor.applyEffectStackForTests(.empty, to: source)

        for (name, definition) in try discriminationEffectDefinitions() {
            let applied = try executor.applyEffectStackForTests(
                singleNodeStack(id: try effectStackUUID(6_230), definition: definition),
                to: source
            )
            let fraction = changedPixelFraction(
                left: identity,
                right: applied,
                channelDeltaThreshold: 2
            )
            XCTAssertGreaterThan(
                fraction,
                0.01,
                "direct apply of \(name) must change >1% of pixels (got \(fraction))"
            )
        }
    }

    // MARK: Kernel-level (hardcoded floats — no ClipSharpenParameters / apply* wrappers)

    func testFRFX002NFRQUAL001KernelEncodeSharpenHardcodedChangesCheckerboard() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let source = try makeCheckerboardTexture(device: device, size: 96, cellSize: 8)
        let executor = try MetalRenderExecutor(device: device)
        let identity = try executor.applyEffectStackForTests(.empty, to: source)
        let sharpened = try executor.encodeSharpenKernelForTests(
            amount: 0.5,
            radius: 1.0,
            source: source
        )
        let fraction = changedPixelFraction(
            left: identity,
            right: sharpened,
            channelDeltaThreshold: 2
        )
        XCTAssertGreaterThan(
            fraction,
            0.01,
            "encodeSharpen(0.5, 1.0) must change >1% of pixels (got \(fraction))"
        )
    }

    func testFRFX002NFRQUAL001KernelEncodeZoomBlurHardcodedChangesCheckerboard() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let source = try makeCheckerboardTexture(device: device, size: 96, cellSize: 8)
        let executor = try MetalRenderExecutor(device: device)
        let identity = try executor.applyEffectStackForTests(.empty, to: source)
        let zoomed = try executor.encodeZoomBlurKernelForTests(
            amount: 0.5,
            centerX: 0.5,
            centerY: 0.5,
            source: source
        )
        let fraction = changedPixelFraction(
            left: identity,
            right: zoomed,
            channelDeltaThreshold: 2
        )
        XCTAssertGreaterThan(
            fraction,
            0.01,
            "encodeZoomBlur(0.5) must change >1% of pixels (got \(fraction))"
        )
    }

    func testFRFX002NFRQUAL001KernelEncodeGlowHardcodedChangesCheckerboard() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let source = try makeCheckerboardTexture(device: device, size: 96, cellSize: 8)
        let executor = try MetalRenderExecutor(device: device)
        let identity = try executor.applyEffectStackForTests(.empty, to: source)
        let glowed = try executor.encodeGlowKernelForTests(
            amount: 0.5,
            radius: 4.0,
            source: source
        )
        let fraction = changedPixelFraction(
            left: identity,
            right: glowed,
            channelDeltaThreshold: 2
        )
        XCTAssertGreaterThan(
            fraction,
            0.01,
            "encodeGlow(0.5, 4.0) must change >1% of pixels (got \(fraction))"
        )
    }

    /// ADR-0010: the same stack on ordinary media vs compound outer must present equal pixels
    /// (effects always run in linear working space).
    func testFRFX002ADR0010OrdinaryAndCompoundEffectPathsPixelEqual() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let size = 32
        let source = try makeCheckerboardTexture(device: device, size: size, cellSize: 4)
        let stack = ClipEffectStack(
            nodes: [
                ClipEffectNode(
                    id: try effectStackUUID(6_250),
                    definition: .gaussianBlur(ClipGaussianBlurParameters(radius: RationalValue(3)))
                )
            ]
        )
        let ordinary = try renderEffectStack(
            device: device,
            source: source,
            size: size,
            stack: stack
        )
        let compound = try renderCompoundOuterEffectStack(
            device: device,
            source: source,
            size: size,
            stack: stack
        )
        XCTAssertEqual(
            ordinary,
            compound,
            "ordinary vs compound effect path must pixel-match (ADR-0010 linear stage)"
        )
    }

    /// Permanent: fragment-stage reflection for sharpen vs zoom (control).
    ///
    /// encodeSharpen binds texture(0) + buffer(0); the pipeline must advertise the same.
    /// Failure messages dump the full reflected argument list.
    func testFRFX002SharpenPipelineReflectionBindsExpectedArguments() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let executor = try MetalRenderExecutor(device: device)
        let pixelFormat = MTLPixelFormat.bgra8Unorm

        let sharpen = try executor.effectPipelineReflectionForTests(
            fragmentFunctionName: "ajar_sharpen_fragment",
            pixelFormat: pixelFormat
        )
        let zoom = try executor.effectPipelineReflectionForTests(
            fragmentFunctionName: "ajar_zoom_blur_fragment",
            pixelFormat: pixelFormat
        )

        let sharpenDump = MetalClipEffectStackRegistry.describeFragmentArguments(
            sharpen.reflection
        )
        let zoomDump = MetalClipEffectStackRegistry.describeFragmentArguments(zoom.reflection)

        assertFragmentBindsTexture0AndBuffer0(
            reflection: sharpen.reflection,
            label: "ajar_sharpen_fragment",
            dump: sharpenDump
        )
        assertFragmentBindsTexture0AndBuffer0(
            reflection: zoom.reflection,
            label: "ajar_zoom_blur_fragment (control)",
            dump: zoomDump
        )
    }
}

private func assertFragmentBindsTexture0AndBuffer0(
    reflection: MTLRenderPipelineReflection,
    label: String,
    dump: String
) {
    let bound = MetalClipEffectStackRegistry.fragmentBindsTexture0AndBuffer0(reflection)
    XCTAssertTrue(
        bound.hasTexture0,
        """
        \(label): expected fragment texture at index 0 (encode* binds setFragmentTexture(_, 0)).
        Reflected bindings:
        \(dump)
        """
    )
    XCTAssertTrue(
        bound.hasBuffer0,
        """
        \(label): expected fragment buffer at index 0 (encode* binds setFragmentBytes(_, 0)).
        Reflected bindings:
        \(dump)
        """
    )
}

// MARK: - Helpers

private func discriminationEffectDefinitions() throws -> [(String, ClipEffectDefinition)] {
    try batch1DiscriminationDefinitions() + batch2DiscriminationDefinitions()
}

private func batch1DiscriminationDefinitions() throws -> [(String, ClipEffectDefinition)] {
    [
        (
            "gaussianBlur",
            .gaussianBlur(ClipGaussianBlurParameters(radius: RationalValue(4)))
        ),
        (
            "boxBlur",
            .boxBlur(ClipBoxBlurParameters(radius: RationalValue(4)))
        ),
        (
            "zoomBlur",
            .zoomBlur(
                ClipZoomBlurParameters(
                    amount: try RationalValue(numerator: 1, denominator: 2),
                    centerX: RationalValue.approximating(0.5),
                    centerY: RationalValue.approximating(0.5)
                )
            )
        ),
        (
            "sharpen",
            .sharpen(
                ClipSharpenParameters(
                    amount: try RationalValue(numerator: 1, denominator: 2),
                    radius: .one
                )
            )
        ),
        (
            "glow",
            .glow(
                ClipGlowParameters(
                    radius: RationalValue(4),
                    amount: try RationalValue(numerator: 1, denominator: 2)
                )
            )
        )
    ]
}

private func batch2DiscriminationDefinitions() throws -> [(String, ClipEffectDefinition)] {
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
        ("mirror", .mirror(ClipMirrorParameters(axis: .horizontal))),
        ("mosaic", .mosaic(ClipMosaicParameters(cellSize: RationalValue(12)))),
        (
            "colorAdjust",
            .colorAdjust(
                ClipColorAdjustParameters(
                    brightness: try RationalValue(numerator: 1, denominator: 10),
                    contrast: try RationalValue(numerator: 6, denominator: 5),
                    saturation: try RationalValue(numerator: 4, denominator: 5),
                    tint: try RationalValue(numerator: 1, denominator: 5)
                )
            )
        ),
        ("posterize", .posterize(ClipPosterizeParameters(levels: RationalValue(4)))),
        ("invert", .invert(ClipInvertParameters()))
    ]
}

private func singleNodeStack(id: UUID, definition: ClipEffectDefinition) -> ClipEffectStack {
    ClipEffectStack(nodes: [ClipEffectNode(id: id, definition: definition)])
}

private func renderEffectStack(
    device: MTLDevice,
    source: MTLTexture,
    size: Int,
    stack: ClipEffectStack
) throws -> [UInt8] {
    try renderEffectStackGraph(
        device: device,
        source: source,
        size: size,
        graph: try makeEffectStackGraph(size: size, stack: stack)
    )
}

private func renderCompoundOuterEffectStack(
    device: MTLDevice,
    source: MTLTexture,
    size: Int,
    stack: ClipEffectStack
) throws -> [UInt8] {
    try renderEffectStackGraph(
        device: device,
        source: source,
        size: size,
        graph: try makeCompoundOuterEffectStackGraph(size: size, stack: stack)
    )
}
