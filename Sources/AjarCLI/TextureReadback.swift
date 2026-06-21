// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal

enum TextureReadback {
    static func readBGRA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
        let rowBytes = texture.width * 4
        let byteCount = rowBytes * texture.height
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw AjarCLIError.textureReadbackFailed("could not allocate shared buffer")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw AjarCLIError.textureReadbackFailed("could not create command queue")
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw AjarCLIError.textureReadbackFailed("could not create command buffer")
        }
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw AjarCLIError.textureReadbackFailed("could not create blit encoder")
        }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: byteCount
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw AjarCLIError.textureReadbackFailed(String(describing: error))
        }

        let pointer = buffer.contents().bindMemory(to: UInt8.self, capacity: byteCount)
        return Array(UnsafeBufferPointer(start: pointer, count: byteCount))
    }
}
