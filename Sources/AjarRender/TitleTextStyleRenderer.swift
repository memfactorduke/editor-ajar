// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreGraphics
import CoreText
import Foundation

/// Draws FR-TXT-002 styling around Core Text's already-shaped frame.
///
/// CGContext text drawing modes stroke and clip the exact vector paths chosen by Core Text.
/// Color-glyph runs retain their native pixels; both paths preserve Core Text's fallback, emoji,
/// RTL, and combining-mark shaping instead of rebuilding glyphs from the requested font.
enum TitleTextStyleRenderer {
    static func draw(
        frame: CTFrame,
        frameRect: CGRect,
        box: TitleTextBox,
        context: CGContext
    ) {
        let textBounds = renderedTextBounds(frame: frame, frameRect: frameRect)
        if let background = box.backgroundBox, let textBounds {
            drawBackground(background, textBounds: textBounds, context: context)
        }

        context.saveGState()
        if let shadow = box.style.dropShadow, shadow.opacity.doubleValue > 0 {
            context.setShadow(
                offset: CGSize(
                    width: CGFloat(shadow.offsetX.doubleValue),
                    height: -CGFloat(shadow.offsetY.doubleValue)
                ),
                blur: CGFloat(shadow.blurRadius.doubleValue),
                color: color(shadow.color, alpha: shadow.opacity.doubleValue)
            )
        }

        // Applying the shadow outside this layer shadows the final stroke+fill once. Drawing a
        // shadow after glyph clipping would clip the blur back to the glyph interiors.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawStroke(
            box.style.stroke,
            frame: frame,
            frameRect: frameRect,
            context: context
        )
        drawFill(
            box.style,
            frame: frame,
            frameRect: frameRect,
            textBounds: textBounds,
            context: context
        )
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func renderedTextBounds(frame: CTFrame, frameRect: CGRect) -> CGRect? {
        let lines = CTFrameGetLines(frame)
        let lineCount = CFArrayGetCount(lines)
        guard lineCount > 0 else {
            return nil
        }

        var origins = [CGPoint](repeating: .zero, count: lineCount)
        origins.withUnsafeMutableBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                CTFrameGetLineOrigins(
                    frame,
                    CFRange(location: 0, length: 0),
                    baseAddress
                )
            }
        }

        var result: CGRect?
        for index in 0..<lineCount {
            guard let linePointer = CFArrayGetValueAtIndex(lines, index) else {
                continue
            }
            let line = Unmanaged<CTLine>.fromOpaque(linePointer).takeUnretainedValue()
            let localBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            guard !localBounds.isNull, !localBounds.isEmpty else {
                continue
            }
            let origin = origins[index]
            let canvasBounds = localBounds.offsetBy(
                dx: frameRect.minX + origin.x,
                dy: frameRect.minY + origin.y
            )
            result = result.map { $0.union(canvasBounds) } ?? canvasBounds
        }
        return result
    }

    private static func drawBackground(
        _ background: TitleBackgroundBoxStyle,
        textBounds: CGRect,
        context: CGContext
    ) {
        guard background.opacity.doubleValue > 0 else {
            return
        }
        let padding = CGFloat(background.padding.doubleValue)
        let backgroundRect = textBounds.insetBy(dx: -padding, dy: -padding)
        let requestedRadius = CGFloat(background.cornerRadius.doubleValue)
        let maximumRadius = min(backgroundRect.width, backgroundRect.height) / 2
        let radius = min(requestedRadius, maximumRadius)

        context.saveGState()
        context.setFillColor(
            color(background.fillColor, alpha: background.opacity.doubleValue)
        )
        context.addPath(
            CGPath(
                roundedRect: backgroundRect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
        )
        context.fillPath()
        context.restoreGState()
    }

    private static func drawStroke(
        _ stroke: TitleStrokeStyle?,
        frame: CTFrame,
        frameRect: CGRect,
        context: CGContext
    ) {
        guard let stroke, stroke.width.doubleValue > 0 else {
            return
        }
        context.saveGState()
        context.setTextDrawingMode(.stroke)
        context.setStrokeColor(color(stroke.color, alpha: 1))
        context.setLineWidth(CGFloat(stroke.width.doubleValue))
        context.setLineJoin(lineJoin(stroke.join))
        TitleTextFrameRuns.forEach(
            in: frame,
            frameRect: frameRect,
            colorGlyphs: false
        ) { run, lineOrigin in
            context.textPosition = lineOrigin
            CTRunDraw(run, context, CFRange(location: 0, length: 0))
        }
        context.restoreGState()
    }

    private static func drawFill(
        _ style: TitleTextStyle,
        frame: CTFrame,
        frameRect: CGRect,
        textBounds: CGRect?,
        context: CGContext
    ) {
        guard let gradient = style.gradientFill, let textBounds else {
            context.saveGState()
            context.setTextDrawingMode(.fill)
            CTFrameDraw(frame, context)
            context.restoreGState()
            return
        }

        TitleTextFrameRuns.forEach(
            in: frame,
            frameRect: frameRect,
            colorGlyphs: false
        ) { run, lineOrigin in
            context.saveGState()
            context.setTextDrawingMode(.clip)
            context.textPosition = lineOrigin
            CTRunDraw(run, context, CFRange(location: 0, length: 0))
            drawLinearGradient(gradient, bounds: textBounds, context: context)
            context.restoreGState()
        }

        context.saveGState()
        context.setTextDrawingMode(.fill)
        TitleTextFrameRuns.forEach(
            in: frame,
            frameRect: frameRect,
            colorGlyphs: true
        ) { run, lineOrigin in
            context.textPosition = lineOrigin
            CTRunDraw(run, context, CFRange(location: 0, length: 0))
        }
        context.restoreGState()
    }

    private static func drawLinearGradient(
        _ fill: TitleLinearGradientFill,
        bounds: CGRect,
        context: CGContext
    ) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [color(fill.startColor, alpha: 1), color(fill.endColor, alpha: 1)] as CFArray
        guard
            let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: colors,
                locations: [0, 1]
            )
        else {
            context.setFillColor(color(fill.startColor, alpha: 1))
            context.fill(bounds)
            return
        }

        let radians = CGFloat(fill.angleDegrees.doubleValue) * .pi / 180
        let deltaX = cos(radians)
        // Model/canvas Y grows down; Core Graphics bitmap Y grows up.
        let deltaY = -sin(radians)
        let halfSpan = (abs(bounds.width * deltaX) + abs(bounds.height * deltaY)) / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let start = CGPoint(
            x: center.x - deltaX * halfSpan,
            y: center.y - deltaY * halfSpan
        )
        let end = CGPoint(
            x: center.x + deltaX * halfSpan,
            y: center.y + deltaY * halfSpan
        )
        context.drawLinearGradient(
            gradient,
            start: start,
            end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    private static func color(_ value: ClipRGBColor, alpha: Double) -> CGColor {
        CGColor(
            red: CGFloat(value.red.doubleValue),
            green: CGFloat(value.green.doubleValue),
            blue: CGFloat(value.blue.doubleValue),
            alpha: CGFloat(alpha)
        )
    }

    private static func lineJoin(_ join: TitleStrokeJoin) -> CGLineJoin {
        switch join {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
    }
}
