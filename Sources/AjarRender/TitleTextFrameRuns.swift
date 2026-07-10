// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreText
import Foundation

/// Iterates Core Text's shaped runs without force-casting Core Foundation objects.
enum TitleTextFrameRuns {
    typealias RunBody = (_ run: CTRun, _ lineOrigin: CGPoint) -> Void

    @discardableResult
    static func forEach(
        in frame: CTFrame,
        frameRect: CGRect,
        colorGlyphs: Bool,
        body: RunBody
    ) -> Bool {
        let lines = CTFrameGetLines(frame)
        let lineCount = CFArrayGetCount(lines)
        guard lineCount > 0 else {
            return false
        }
        let origins = lineOrigins(frame: frame, count: lineCount)
        var visited = false

        for lineIndex in 0..<lineCount {
            guard let linePointer = CFArrayGetValueAtIndex(lines, lineIndex) else {
                continue
            }
            let line = Unmanaged<CTLine>.fromOpaque(linePointer).takeUnretainedValue()
            let runs = CTLineGetGlyphRuns(line)
            let runCount = CFArrayGetCount(runs)
            let localOrigin = origins[lineIndex]
            let canvasOrigin = CGPoint(
                x: frameRect.minX + localOrigin.x,
                y: frameRect.minY + localOrigin.y
            )

            for runIndex in 0..<runCount {
                guard let runPointer = CFArrayGetValueAtIndex(runs, runIndex) else {
                    continue
                }
                let run = Unmanaged<CTRun>.fromOpaque(runPointer).takeUnretainedValue()
                guard isColorGlyphRun(run) == colorGlyphs else {
                    continue
                }
                body(run, canvasOrigin)
                visited = true
            }
        }
        return visited
    }

    private static func lineOrigins(frame: CTFrame, count: Int) -> [CGPoint] {
        var origins = [CGPoint](repeating: .zero, count: count)
        origins.withUnsafeMutableBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                CTFrameGetLineOrigins(
                    frame,
                    CFRange(location: 0, length: 0),
                    baseAddress
                )
            }
        }
        return origins
    }

    private static func isColorGlyphRun(_ run: CTRun) -> Bool {
        let attributes = CTRunGetAttributes(run)
        let keyPointer = Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()
        guard let fontPointer = CFDictionaryGetValue(attributes, keyPointer) else {
            return false
        }
        let fontObject = Unmanaged<AnyObject>.fromOpaque(fontPointer).takeUnretainedValue()
        guard CFGetTypeID(fontObject) == CTFontGetTypeID() else {
            return false
        }
        let font = Unmanaged<CTFont>.fromOpaque(fontPointer).takeUnretainedValue()
        return CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
    }
}
