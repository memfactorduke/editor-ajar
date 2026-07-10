// SPDX-License-Identifier: GPL-3.0-or-later

extension MetalEffectUniformLayout {
    /// Vignette strength and normalized falloff geometry.
    public static let vignette = MetalEffectUniformLayout(
        mslTypeName: "AjarVignetteUniforms",
        fields: [
            MetalEffectUniformField(name: "amount", kind: .float),
            MetalEffectUniformField(name: "radius", kind: .float),
            MetalEffectUniformField(name: "softness", kind: .float),
            MetalEffectUniformField(name: "padding0", kind: .float)
        ]
    )

    /// Mirror axis mode encoded explicitly as 0 (horizontal), 1 (vertical), or 2 (quad).
    public static let mirror = MetalEffectUniformLayout(
        mslTypeName: "AjarMirrorUniforms",
        fields: [
            MetalEffectUniformField(name: "axisMode", kind: .float),
            MetalEffectUniformField(name: "padding0", kind: .float),
            MetalEffectUniformField(name: "padding1", kind: .float),
            MetalEffectUniformField(name: "padding2", kind: .float)
        ]
    )

    /// Mosaic square-cell edge in source pixels.
    public static let mosaic = MetalEffectUniformLayout(
        mslTypeName: "AjarMosaicUniforms",
        fields: [
            MetalEffectUniformField(name: "cellSizePx", kind: .float),
            MetalEffectUniformField(name: "padding0", kind: .float),
            MetalEffectUniformField(name: "padding1", kind: .float),
            MetalEffectUniformField(name: "padding2", kind: .float)
        ]
    )

    /// Linear-working-space basic color adjustment.
    public static let colorAdjust = MetalEffectUniformLayout(
        mslTypeName: "AjarColorAdjustUniforms",
        fields: [
            MetalEffectUniformField(name: "brightness", kind: .float),
            MetalEffectUniformField(name: "contrast", kind: .float),
            MetalEffectUniformField(name: "saturation", kind: .float),
            MetalEffectUniformField(name: "tint", kind: .float)
        ]
    )

    /// Discrete RGB level count for posterization.
    public static let posterize = MetalEffectUniformLayout(
        mslTypeName: "AjarPosterizeUniforms",
        fields: [
            MetalEffectUniformField(name: "levels", kind: .float),
            MetalEffectUniformField(name: "padding0", kind: .float),
            MetalEffectUniformField(name: "padding1", kind: .float),
            MetalEffectUniformField(name: "padding2", kind: .float)
        ]
    )

    /// RGB inversion white point. Fixed at linear 1.0 for the built-in kind.
    public static let invert = MetalEffectUniformLayout(
        mslTypeName: "AjarInvertUniforms",
        fields: [
            MetalEffectUniformField(name: "whitePoint", kind: .float),
            MetalEffectUniformField(name: "padding0", kind: .float),
            MetalEffectUniformField(name: "padding1", kind: .float),
            MetalEffectUniformField(name: "padding2", kind: .float)
        ]
    )
}

extension MetalEffectUniformLayout {
    /// Packs vignette uniforms in generated layout order.
    public static func packVignette(
        amount: Float,
        radius: Float,
        softness: Float
    ) -> [UInt8] {
        vignette.pack(valuesInOrder: [
            .float(amount),
            .float(radius),
            .float(softness),
            .float(0)
        ])
    }

    /// Packs the explicit mirror-axis mode.
    public static func packMirror(axisMode: Float) -> [UInt8] {
        mirror.pack(valuesInOrder: [
            .float(axisMode),
            .float(0),
            .float(0),
            .float(0)
        ])
    }

    /// Packs a mosaic cell edge in source pixels.
    public static func packMosaic(cellSizePx: Float) -> [UInt8] {
        mosaic.pack(valuesInOrder: [
            .float(cellSizePx),
            .float(0),
            .float(0),
            .float(0)
        ])
    }

    /// Packs basic color-adjust uniforms.
    public static func packColorAdjust(
        brightness: Float,
        contrast: Float,
        saturation: Float,
        tint: Float
    ) -> [UInt8] {
        colorAdjust.pack(valuesInOrder: [
            .float(brightness),
            .float(contrast),
            .float(saturation),
            .float(tint)
        ])
    }

    /// Packs the posterize level count.
    public static func packPosterize(levels: Float) -> [UInt8] {
        posterize.pack(valuesInOrder: [
            .float(levels),
            .float(0),
            .float(0),
            .float(0)
        ])
    }

    /// Packs the fixed linear white point for RGB inversion.
    public static func packInvert() -> [UInt8] {
        invert.pack(valuesInOrder: [
            .float(1),
            .float(0),
            .float(0),
            .float(0)
        ])
    }
}
