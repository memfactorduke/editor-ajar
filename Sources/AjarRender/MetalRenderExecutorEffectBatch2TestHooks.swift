// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Metal

extension MetalRenderExecutor {
    /// Kernel-level vignette hook with hardcoded floats (tests only).
    func encodeVignetteKernelForTests(
        amount: Float,
        radius: Float,
        softness: Float,
        source: MTLTexture
    ) throws -> [UInt8] {
        try runEffectKernelForTests(source: source) { context in
            try MetalClipEffectStackEncoder.encodeVignette(
                amount: amount,
                radius: radius,
                softness: softness,
                to: source,
                context: context
            ).texture
        }
    }

    /// Kernel-level mirror hook with an explicit numeric axis mode (tests only).
    func encodeMirrorKernelForTests(
        axisMode: Float,
        source: MTLTexture
    ) throws -> [UInt8] {
        try runEffectKernelForTests(source: source) { context in
            try MetalClipEffectStackEncoder.encodeMirror(
                axisMode: axisMode,
                to: source,
                context: context
            ).texture
        }
    }

    /// Kernel-level mosaic hook with a hardcoded cell size (tests only).
    func encodeMosaicKernelForTests(
        cellSize: Float,
        source: MTLTexture
    ) throws -> [UInt8] {
        try runEffectKernelForTests(source: source) { context in
            try MetalClipEffectStackEncoder.encodeMosaic(
                cellSize: cellSize,
                to: source,
                context: context
            ).texture
        }
    }

    /// Kernel-level basic color-adjust hook with hardcoded floats (tests only).
    func encodeColorAdjustKernelForTests(
        brightness: Float,
        contrast: Float,
        saturation: Float,
        tint: Float,
        source: MTLTexture
    ) throws -> [UInt8] {
        try runEffectKernelForTests(source: source) { context in
            try MetalClipEffectStackEncoder.encodeColorAdjust(
                controls: SIMD4<Float>(brightness, contrast, saturation, tint),
                to: source,
                context: context
            ).texture
        }
    }

    /// Kernel-level posterize hook with a hardcoded level count (tests only).
    func encodePosterizeKernelForTests(
        levels: Float,
        source: MTLTexture
    ) throws -> [UInt8] {
        try runEffectKernelForTests(source: source) { context in
            try MetalClipEffectStackEncoder.encodePosterize(
                levels: levels,
                to: source,
                context: context
            ).texture
        }
    }

    /// Kernel-level invert hook (tests only).
    func encodeInvertKernelForTests(source: MTLTexture) throws -> [UInt8] {
        try runEffectKernelForTests(source: source) { context in
            try MetalClipEffectStackEncoder.encodeInvert(
                to: source,
                context: context
            ).texture
        }
    }

    /// Kernel-level FR-COL-002 curves hook with a prebuilt parameter payload (tests only).
    func encodeCurvesKernelForTests(
        parameters: ClipCurvesEffectParameters,
        strength: Float,
        source: MTLTexture
    ) throws -> [UInt8] {
        try runEffectKernelForTests(source: source) { context in
            try MetalClipEffectStackEncoder.encodeCurves(
                parameters: parameters,
                strength: strength,
                to: source,
                context: context
            ).texture
        }
    }
}
