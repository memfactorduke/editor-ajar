// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import simd

extension MetalClipEffectStackRegistry {
    /// GPU-resident packed curves ramp (R/G/B/A = red/green/blue/rgb-master), cached by digest.
    ///
    /// Bake is CPU-only and runs on first use for a digest — never per frame.
    /// M9 hardening: bound this cache (and the LUT digest cache) by entry/byte budget —
    /// unbounded growth matches current LUT precedent.
    func curvesRampTexture(for parameters: ClipCurvesEffectParameters) throws -> MTLTexture {
        let key = parameters.rampContentDigest.digest
        lock.lock()
        if let cached = curvesRampTextureCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let texture = try Self.makeCurvesRampTexture(parameters: parameters, device: device)
        lock.lock()
        curvesRampTextureCache[key] = texture
        lock.unlock()
        return texture
    }

    private static func makeCurvesRampTexture(
        parameters: ClipCurvesEffectParameters,
        device: MTLDevice
    ) throws -> MTLTexture {
        let size = ColorCurveLimits.rampSampleCount
        let packed = parameters.bakePackedRamp()
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = size
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRenderError.outputTextureCreationFailed(width: size, height: 1)
        }
        var pixels = [SIMD4<Float16>](repeating: SIMD4<Float16>(0, 0, 0, 0), count: size)
        for index in 0..<size {
            pixels[index] = SIMD4<Float16>(
                Float16(packed.red[index]),
                Float16(packed.green[index]),
                Float16(packed.blue[index]),
                Float16(packed.rgb[index])
            )
        }
        texture.replace(
            region: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: size, height: 1, depth: 1)
            ),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: size * MemoryLayout<SIMD4<Float16>>.stride
        )
        return texture
    }
}
