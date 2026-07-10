// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation

/// Adapts a closure-based original-media frame source to ``ProxySourceFrameProvider``.
///
/// Production app/CLI code typically wraps `AjarMedia.MediaTranscodeFrameProvider` with this
/// adapter so `AjarExport` stays free of an `AjarMedia` dependency (ADR-0019).
public final class ClosureProxySourceFrameProvider: ProxySourceFrameProvider, @unchecked Sendable {
    private let handler: @Sendable (Int64, CVPixelBuffer) async throws -> Void

    /// Creates a provider that forwards to `handler`.
    public init(
        _ handler: @escaping @Sendable (Int64, CVPixelBuffer) async throws -> Void
    ) {
        self.handler = handler
    }

    /// Forwards to the injected handler.
    public func provideFrame(index: Int64, into pixelBuffer: CVPixelBuffer) async throws {
        try await handler(index, pixelBuffer)
    }
}

/// Fails every frame — used when session factory setup cannot build a real provider.
public final class FailingProxySourceFrameProvider: ProxySourceFrameProvider, @unchecked Sendable {
    private let reason: String

    /// Creates a provider that always throws.
    public init(reason: String) {
        self.reason = reason
    }

    /// Always throws ``ExportError/frameRenderFailed``.
    public func provideFrame(index: Int64, into pixelBuffer: CVPixelBuffer) async throws {
        _ = pixelBuffer
        throw ExportError.frameRenderFailed(frameIndex: index, reason: reason)
    }
}

/// Solid-color stub frame provider for CI / unit tests (no source media required).
///
/// Fills either `32BGRA` or big-endian `64ARGB` (ProRes writer pools) with a constant color.
public final class SolidColorProxySourceFrameProvider: ProxySourceFrameProvider,
@unchecked Sendable {
    private let red: UInt8
    private let green: UInt8
    private let blue: UInt8

    /// Creates a solid-fill provider.
    public init(red: UInt8 = 32, green: UInt8 = 64, blue: UInt8 = 128) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Fills `pixelBuffer` with a constant color matching its pixel format.
    public func provideFrame(index: Int64, into pixelBuffer: CVPixelBuffer) async throws {
        _ = index
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ExportError.writerFailed("solid proxy provider missing pixel base address")
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let row = UnsafeMutableRawPointer(base)
        switch format {
        case kCVPixelFormatType_32BGRA:
            for y in 0..<height {
                let rowPtr = row.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let offset = x * 4
                    rowPtr[offset + 0] = blue
                    rowPtr[offset + 1] = green
                    rowPtr[offset + 2] = red
                    rowPtr[offset + 3] = 255
                }
            }
        case kCVPixelFormatType_64ARGB:
            // Big-endian 16-bit samples (AVAssetWriter ProRes contract).
            let r16 = UInt16(red) &* 257
            let g16 = UInt16(green) &* 257
            let b16 = UInt16(blue) &* 257
            let a16: UInt16 = 65_535
            for y in 0..<height {
                let rowPtr = row.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    let offset = x * 4
                    rowPtr[offset + 0] = a16.bigEndian
                    rowPtr[offset + 1] = r16.bigEndian
                    rowPtr[offset + 2] = g16.bigEndian
                    rowPtr[offset + 3] = b16.bigEndian
                }
            }
        default:
            throw ExportError.writerFailed(
                "solid proxy provider unsupported pixel format \(format)"
            )
        }
    }
}
