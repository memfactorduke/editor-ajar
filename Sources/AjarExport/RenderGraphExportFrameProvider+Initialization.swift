// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Metal

public extension RenderGraphExportFrameProvider {
    /// Creates a movie-delivery provider with the default Metal device.
    convenience init(
        project: Project,
        sequence: Sequence,
        videoSettings: ExportVideoSettings,
        sourceProvider: any ExportRenderSourceProvider
    ) throws {
        try self.init(
            project: project,
            sequence: sequence,
            videoSettings: videoSettings,
            sourceProvider: sourceProvider,
            device: try Self.makeDefaultDevice()
        )
    }

    /// Creates a movie-delivery provider on an explicit Metal device.
    convenience init(
        project: Project,
        sequence: Sequence,
        videoSettings: ExportVideoSettings,
        sourceProvider: any ExportRenderSourceProvider,
        device: MTLDevice
    ) throws {
        try self.init(
            project: project,
            sequence: sequence,
            resolution: videoSettings.resolution,
            colorSpace: videoSettings.colorSpace,
            codec: videoSettings.codec,
            sourceProvider: sourceProvider,
            device: device
        )
    }

    /// Creates a codec-free BGRA image-delivery provider with the default Metal device.
    ///
    /// Image exports use this path because their raster and color space are independent of any
    /// movie codec. In particular, odd dimensions remain valid for PNG, JPEG, and GIF output.
    convenience init(
        project: Project,
        sequence: Sequence,
        resolution: PixelDimensions,
        colorSpace: ExportColorSpace,
        sourceProvider: any ExportRenderSourceProvider
    ) throws {
        try self.init(
            project: project,
            sequence: sequence,
            resolution: resolution,
            colorSpace: colorSpace,
            sourceProvider: sourceProvider,
            device: try Self.makeDefaultDevice()
        )
    }

    /// Creates a codec-free BGRA image-delivery provider on an explicit Metal device.
    convenience init(
        project: Project,
        sequence: Sequence,
        resolution: PixelDimensions,
        colorSpace: ExportColorSpace,
        sourceProvider: any ExportRenderSourceProvider,
        device: MTLDevice
    ) throws {
        try self.init(
            project: project,
            sequence: sequence,
            resolution: resolution,
            colorSpace: colorSpace,
            codec: nil,
            sourceProvider: sourceProvider,
            device: device
        )
    }

    private static func makeDefaultDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "Metal device unavailable"
            )
        }
        return device
    }
}
