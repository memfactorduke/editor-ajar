// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import simd

/// One field in an FR-FX-002 fragment uniform block (MSL + Swift pack share this).
public struct MetalEffectUniformField: Equatable, Sendable {
    /// MSL member name (and pack key).
    public let name: String
    /// MSL type / pack width.
    public let kind: MetalEffectUniformFieldKind

    /// Creates a field descriptor.
    public init(name: String, kind: MetalEffectUniformFieldKind) {
        self.name = name
        self.kind = kind
    }
}

/// MSL scalar/vector kinds used by FR-FX-002 uniform blocks.
public enum MetalEffectUniformFieldKind: Equatable, Sendable {
    /// `float` (4 bytes, 4-byte align).
    case float
    /// `float2` (8 bytes, 8-byte align).
    case float2

    fileprivate var mslTypeName: String {
        switch self {
        case .float:
            "float"
        case .float2:
            "float2"
        }
    }

    fileprivate var byteSize: Int {
        switch self {
        case .float:
            4
        case .float2:
            8
        }
    }

    fileprivate var alignment: Int {
        byteSize
    }
}

/// Canonical FR-FX-002 uniform layout: generates MSL struct text and drives CPU pack order.
///
/// Swift encoders must pack through `pack(valuesInOrder:)` (or the typed helpers). Hand-written
/// MSL struct bodies are forbidden — `MetalClipEffectStackShaders` interpolates
/// `allMSLStructDeclarations` so a field rename/reorder cannot silently desync.
public struct MetalEffectUniformLayout: Equatable, Sendable {
    /// MSL struct type name (e.g. `AjarSharpenUniforms`).
    public let mslTypeName: String
    /// Members in declaration / pack order.
    public let fields: [MetalEffectUniformField]

    /// Creates a layout.
    public init(mslTypeName: String, fields: [MetalEffectUniformField]) {
        self.mslTypeName = mslTypeName
        self.fields = fields
    }

    /// Member names in pack order (string-level lock for tests).
    public var fieldNamesInPackOrder: [String] {
        fields.map(\.name)
    }

    /// MSL `struct Name { ... };` block generated from `fields` (single source of truth).
    public var mslStructDeclaration: String {
        let body = fields.map { field in
            "            \(field.kind.mslTypeName) \(field.name);"
        }.joined(separator: "\n")
        return """
                struct \(mslTypeName) {
            \(body)
                };
            """
    }

    /// Byte offsets of each field under Metal/MSL natural alignment rules.
    public var fieldByteOffsets: [Int] {
        var offset = 0
        var offsets: [Int] = []
        for field in fields {
            let align = field.kind.alignment
            offset = (offset + align - 1) & ~(align - 1)
            offsets.append(offset)
            offset += field.kind.byteSize
        }
        return offsets
    }

    /// Total packed byte count (struct size rounded to max member alignment).
    public var byteCount: Int {
        guard let last = fields.last else {
            return 0
        }
        let lastOffset = fieldByteOffsets[fields.count - 1]
        let end = lastOffset + last.kind.byteSize
        let maxAlign = fields.map(\.kind.alignment).max() ?? 4
        return (end + maxAlign - 1) & ~(maxAlign - 1)
    }

    /// Packs raw values in **exact** field order (count and kinds must match).
    public func pack(valuesInOrder: [MetalEffectUniformValue]) -> [UInt8] {
        precondition(
            valuesInOrder.count == fields.count,
            "\(mslTypeName): expected \(fields.count) values, got \(valuesInOrder.count)"
        )
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let offsets = fieldByteOffsets
        for index in fields.indices {
            let field = fields[index]
            let value = valuesInOrder[index]
            precondition(
                value.kind == field.kind,
                "\(mslTypeName).\(field.name): kind mismatch"
            )
            let offset = offsets[index]
            switch value {
            case .float(let scalar):
                withUnsafeBytes(of: scalar) { raw in
                    for byteIndex in 0..<4 {
                        bytes[offset + byteIndex] = raw[byteIndex]
                    }
                }
            case .float2(let vector):
                withUnsafeBytes(of: vector) { raw in
                    for byteIndex in 0..<8 {
                        bytes[offset + byteIndex] = raw[byteIndex]
                    }
                }
            }
        }
        return bytes
    }
}

/// One packed scalar/vector matching a layout field.
public enum MetalEffectUniformValue: Equatable, Sendable {
    case float(Float)
    case float2(SIMD2<Float>)

    fileprivate var kind: MetalEffectUniformFieldKind {
        switch self {
        case .float:
            .float
        case .float2:
            .float2
        }
    }
}

// MARK: - Canonical layouts (all FR-FX-002 fragment uniform blocks)

extension MetalEffectUniformLayout {
    /// Separable Gaussian / box blur (and glow pre-blur).
    public static let separableBlur = MetalEffectUniformLayout(
        mslTypeName: "AjarSeparableBlurUniforms",
        fields: [
            MetalEffectUniformField(name: "texelSize", kind: .float2),
            MetalEffectUniformField(name: "direction", kind: .float2),
            MetalEffectUniformField(name: "radius", kind: .float),
            MetalEffectUniformField(name: "padding0", kind: .float)
        ]
    )

    /// Zoom / radial blur.
    public static let zoomBlur = MetalEffectUniformLayout(
        mslTypeName: "AjarZoomBlurUniforms",
        fields: [
            MetalEffectUniformField(name: "center", kind: .float2),
            MetalEffectUniformField(name: "amount", kind: .float),
            MetalEffectUniformField(name: "padding0", kind: .float)
        ]
    )

    /// Unsharp-mask sharpen (`amount`, `radiusPx` — texel size from the texture).
    public static let sharpen = MetalEffectUniformLayout(
        mslTypeName: "AjarSharpenUniforms",
        fields: [
            MetalEffectUniformField(name: "amount", kind: .float),
            MetalEffectUniformField(name: "radiusPx", kind: .float),
            MetalEffectUniformField(name: "padding0", kind: .float),
            MetalEffectUniformField(name: "padding1", kind: .float)
        ]
    )

    /// Glow combine (post separable blur).
    public static let glowCombine = MetalEffectUniformLayout(
        mslTypeName: "AjarGlowCombineUniforms",
        fields: [
            MetalEffectUniformField(name: "amount", kind: .float),
            MetalEffectUniformField(name: "padding0", kind: .float),
            MetalEffectUniformField(name: "padding1", kind: .float),
            MetalEffectUniformField(name: "padding2", kind: .float)
        ]
    )

    /// Every distinct FR-FX-002 uniform block (covers all five library kinds).
    public static let all: [MetalEffectUniformLayout] = [
        .separableBlur,
        .zoomBlur,
        .sharpen,
        .glowCombine
    ]

    /// Concatenated MSL struct declarations for injection into the effect shader source.
    public static var allMSLStructDeclarations: String {
        all.map(\.mslStructDeclaration).joined(separator: "\n")
    }
}

// MARK: - Typed pack helpers (encoder use)

extension MetalEffectUniformLayout {
    /// Packs separable blur uniforms in layout order.
    public static func packSeparableBlur(
        texelSize: SIMD2<Float>,
        direction: SIMD2<Float>,
        radius: Float
    ) -> [UInt8] {
        separableBlur.pack(valuesInOrder: [
            .float2(texelSize),
            .float2(direction),
            .float(radius),
            .float(0)
        ])
    }

    /// Packs zoom blur uniforms in layout order.
    public static func packZoomBlur(
        centerX: Float,
        centerY: Float,
        amount: Float
    ) -> [UInt8] {
        zoomBlur.pack(valuesInOrder: [
            .float2(SIMD2<Float>(centerX, centerY)),
            .float(amount),
            .float(0)
        ])
    }

    /// Packs sharpen uniforms in layout order (`amount`, then `radiusPx`).
    public static func packSharpen(amount: Float, radiusPx: Float) -> [UInt8] {
        sharpen.pack(valuesInOrder: [
            .float(amount),
            .float(radiusPx),
            .float(0),
            .float(0)
        ])
    }

    /// Packs glow combine uniforms in layout order.
    public static func packGlowCombine(amount: Float) -> [UInt8] {
        glowCombine.pack(valuesInOrder: [
            .float(amount),
            .float(0),
            .float(0),
            .float(0)
        ])
    }
}
