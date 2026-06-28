// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Metal

struct BenchmarkScopeAnalyzerFixture {
    let texture: MTLTexture

    init(device: MTLDevice) throws {
        let dimensions = PixelDimensions(width: 1_920, height: 1_080)
        texture = try Self.makeDisplayEncodedTexture(device: device, dimensions: dimensions)
    }

    private static func makeDisplayEncodedTexture(
        device: MTLDevice,
        dimensions: PixelDimensions
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: dimensions.width,
            height: dimensions.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw AjarCLIError.benchmarkFailed("could not allocate scope benchmark texture")
        }

        let rowBytes = dimensions.width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * dimensions.height)
        for yPosition in 0..<dimensions.height {
            for xPosition in 0..<dimensions.width {
                writeDisplayEncodedGradientPixel(
                    to: &pixels,
                    offset: (yPosition * rowBytes) + (xPosition * 4),
                    xPosition: xPosition,
                    yPosition: yPosition,
                    dimensions: dimensions
                )
            }
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, dimensions.width, dimensions.height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: rowBytes
        )
        return texture
    }

    private static func writeDisplayEncodedGradientPixel(
        to pixels: inout [UInt8],
        offset: Int,
        xPosition: Int,
        yPosition: Int,
        dimensions: PixelDimensions
    ) {
        let red = UInt8((xPosition * 255) / max(dimensions.width - 1, 1))
        let green = UInt8((yPosition * 255) / max(dimensions.height - 1, 1))
        let blue = UInt8(
            ((xPosition + yPosition) * 255)
                / max(
                    dimensions.width + dimensions.height - 2,
                    1
                ))
        pixels[offset] = blue
        pixels[offset + 1] = green
        pixels[offset + 2] = red
        pixels[offset + 3] = 255
    }
}
