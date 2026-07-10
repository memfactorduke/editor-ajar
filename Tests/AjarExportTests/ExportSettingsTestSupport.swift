// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

@testable import AjarExport

enum ExportSettingsTestSupport {
    static func videoSettings(
        codec: ExportVideoCodec,
        width: Int = 1_920,
        averageBitRate: Int? = nil,
        quality: Double? = nil,
        colorSpace: ExportColorSpace = .rec709
    ) throws -> ExportVideoSettings {
        try ExportVideoSettings(
            codec: codec,
            resolution: PixelDimensions(width: width, height: 1_080),
            frameRate: FrameRate(frames: 30),
            averageBitRate: averageBitRate,
            quality: quality,
            colorSpace: colorSpace
        )
    }
}
