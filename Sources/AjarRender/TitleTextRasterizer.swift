// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreGraphics
import CoreText
import Foundation
import Metal

/// Typed failures while rasterizing a title generator (FR-TXT-001, FR-TXT-007, ADR-0017).
public enum TitleRenderError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Output dimensions are not positive.
    case invalidDimensions(width: Int, height: Int)

    /// A Metal texture could not be allocated for the rasterized title.
    case textureCreationFailed(width: Int, height: Int)

    /// Bitmap context creation failed.
    case bitmapContextCreationFailed(width: Int, height: Int)

    /// Requested font was unavailable; rasterization continued with the documented fallback.
    ///
    /// This is reported as a soft diagnostic on the rasterization result rather than aborting
    /// the render (NFR-STAB-003). Callers may log it; goldens pin to Helvetica so it does not
    /// fire on the happy path.
    case fontUnavailable(requested: String, fallback: String)

    /// A human-readable description of the title render failure.
    public var description: String {
        switch self {
        case .invalidDimensions(let width, let height):
            "title rasterization requires positive dimensions, got \(width)x\(height)"
        case .textureCreationFailed(let width, let height):
            "title texture creation failed for \(width)x\(height)"
        case .bitmapContextCreationFailed(let width, let height):
            "title bitmap context creation failed for \(width)x\(height)"
        case .fontUnavailable(let requested, let fallback):
            "title font '\(requested)' unavailable; using fallback '\(fallback)'"
        }
    }
}

/// Result of rasterizing a title source to a Metal texture.
public struct TitleRasterizationResult {
    /// Premultiplied BGRA8 texture at the requested dimensions.
    public let texture: MTLTexture

    /// Soft diagnostics (e.g. font fallbacks). Never empty-only when a fallback was used.
    public let diagnostics: [TitleRenderError]
}

/// CoreText rasterizer for title generator clips (ADR-0017).
///
/// Layout uses `CTFramesetter` per text box so emoji, RTL, and combining marks ride the system
/// text stack (FR-TXT-007). Rasterization is off the playback hot path: callers cache by the
/// title node content hash + dimensions (ADR-0009).
public enum TitleTextRasterizer {
    /// macOS-stable fallback and golden font (ADR-0017).
    public static let deterministicFontFamily = TitleSource.deterministicFontFamily

    /// Rasterizes `title` into premultiplied BGRA8 pixels (no Metal required).
    ///
    /// Used by texture upload and offline golden fixture generation so layout is identical.
    public static func rasterizePixels(
        title: TitleSource,
        width: Int,
        height: Int
    ) throws -> (pixels: [UInt8], diagnostics: [TitleRenderError]) {
        guard width > 0, height > 0 else {
            throw TitleRenderError.invalidDimensions(width: width, height: height)
        }

        var diagnostics: [TitleRenderError] = []
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo =
            CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        else {
            throw TitleRenderError.bitmapContextCreationFailed(width: width, height: height)
        }

        // CoreGraphics origin is bottom-left; title model origin is top-left (canvas space).
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.textMatrix = .identity

        for box in title.boxes {
            draw(
                box: box,
                canvasHeight: CGFloat(height),
                context: context,
                diagnostics: &diagnostics
            )
        }
        return (pixels, diagnostics)
    }

    /// Rasterizes `title` into a transparent BGRA8 texture of `width`×`height` pixels.
    public static func rasterize(
        title: TitleSource,
        width: Int,
        height: Int,
        device: MTLDevice
    ) throws -> TitleRasterizationResult {
        let (pixels, diagnostics) = try rasterizePixels(
            title: title,
            width: width,
            height: height
        )
        let texture = try makeTexture(
            device: device,
            width: width,
            height: height,
            pixels: pixels,
            bytesPerRow: width * 4
        )
        return TitleRasterizationResult(texture: texture, diagnostics: diagnostics)
    }

    private static func draw(
        box: TitleTextBox,
        canvasHeight: CGFloat,
        context: CGContext,
        diagnostics: inout [TitleRenderError]
    ) {
        // Empty text is allowed: skip layout entirely.
        guard !box.text.isEmpty else {
            return
        }

        let font = resolveFont(for: box.style, diagnostics: &diagnostics)
        let attributed = makeAttributedString(text: box.text, style: box.style, font: font)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        let boxWidth = max(CGFloat(box.width.doubleValue), 1)
        let boxHeight = max(CGFloat(box.height.doubleValue), 1)
        let originX = CGFloat(box.origin.x.doubleValue)
        // Convert top-left model origin to CG bottom-left frame origin.
        let originY = canvasHeight - CGFloat(box.origin.y.doubleValue) - boxHeight
        let frameRect = CGRect(x: originX, y: originY, width: boxWidth, height: boxHeight)
        let path = CGPath(rect: frameRect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )

        context.saveGState()
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func makeAttributedString(
        text: String,
        style: TitleTextStyle,
        font: CTFont
    ) -> CFAttributedString {
        let paragraphStyle = makeParagraphStyle(for: style)
        let color = CGColor(
            red: CGFloat(style.color.red.doubleValue),
            green: CGFloat(style.color.green.doubleValue),
            blue: CGFloat(style.color.blue.doubleValue),
            alpha: 1
        )

        let attributes = NSMutableDictionary()
        attributes[kCTFontAttributeName] = font
        attributes[kCTForegroundColorAttributeName] = color
        attributes[kCTParagraphStyleAttributeName] = paragraphStyle
        if style.tracking.doubleValue != 0 {
            attributes[kCTKernAttributeName] = CGFloat(style.tracking.doubleValue) as CFNumber
        }

        // Force-unwrap is intentionally avoided (NFR-STAB-003): fall back to a bare string.
        if let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault,
            text as CFString,
            attributes as CFDictionary
        ) {
            return attributed
        }
        return CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, nil)
            ?? NSAttributedString(string: text) as CFAttributedString
    }

    private static func makeParagraphStyle(for style: TitleTextStyle) -> CTParagraphStyle {
        var alignmentValue = ctAlignment(style.alignment)
        var lineSpacing = CGFloat(max(style.leading.doubleValue, 0))
        return withUnsafePointer(to: &alignmentValue) { alignmentPointer in
            withUnsafePointer(to: &lineSpacing) { spacingPointer in
                let settings = [
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.size,
                        value: alignmentPointer
                    ),
                    CTParagraphStyleSetting(
                        spec: .lineSpacingAdjustment,
                        valueSize: MemoryLayout<CGFloat>.size,
                        value: spacingPointer
                    )
                ]
                return settings.withUnsafeBufferPointer { buffer in
                    CTParagraphStyleCreate(buffer.baseAddress, buffer.count)
                }
            }
        }
    }

    private static func resolveFont(
        for style: TitleTextStyle,
        diagnostics: inout [TitleRenderError]
    ) -> CTFont {
        let size = CGFloat(max(style.fontSize.doubleValue, 1))
        let weight = cgFontWeight(style.fontWeight)
        let traits: [CFString: Any] = [
            kCTFontWeightTrait: weight
        ]
        let descriptorAttributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: style.fontFamily as CFString,
            kCTFontTraitsAttribute: traits
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(
            descriptorAttributes as CFDictionary
        )
        let primary = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        let resolvedFamily = CTFontCopyFamilyName(primary) as String
        let postScript = CTFontCopyPostScriptName(primary) as String
        let requested = style.fontFamily
        let familyMatches = resolvedFamily.caseInsensitiveCompare(requested) == .orderedSame
        let postScriptMatches = postScript.caseInsensitiveCompare(requested) == .orderedSame
        if familyMatches || postScriptMatches {
            return primary
        }

        // Deterministic fallback (ADR-0017).
        let fallbackName = deterministicFontFamily
        diagnostics.append(
            .fontUnavailable(requested: requested, fallback: fallbackName)
        )
        let fallbackDescriptor = CTFontDescriptorCreateWithAttributes(
            [
                kCTFontFamilyNameAttribute: fallbackName as CFString,
                kCTFontTraitsAttribute: traits
            ] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(fallbackDescriptor, size, nil)
    }

    private static func cgFontWeight(_ weight: TitleFontWeight) -> CGFloat {
        switch weight {
        case .ultraLight: return -0.8
        case .thin: return -0.6
        case .light: return -0.4
        case .regular: return 0.0
        case .medium: return 0.23
        case .semibold: return 0.3
        case .bold: return 0.4
        case .heavy: return 0.56
        case .black: return 0.62
        }
    }

    private static func ctAlignment(_ alignment: TitleTextAlignment) -> CTTextAlignment {
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        }
    }

    private static func makeTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixels: [UInt8],
        bytesPerRow: Int
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TitleRenderError.textureCreationFailed(width: width, height: height)
        }
        pixels.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }
}
