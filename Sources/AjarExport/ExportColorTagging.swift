// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

enum ExportColorTagging {
    static func videoProperties(for colorSpace: ExportColorSpace) -> [String: Any] {
        switch colorSpace {
        case .rec709:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        case .displayP3:
            // AVVideoTransferFunction_IEC_sRGB is only declared in the macOS 15+ SDK headers
            // (API_AVAILABLE macos(15.0)); older CI SDKs fail to compile the symbol even under
            // #available. The constant's value is the stable string key "IEC_sRGB".
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: "IEC_sRGB",
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        }
    }

    static func cgColorSpace(for colorSpace: ExportColorSpace) throws -> CGColorSpace {
        let name: CFString
        switch colorSpace {
        case .rec709:
            name = CGColorSpace.itur_709
        case .displayP3:
            name = CGColorSpace.displayP3
        }
        guard let space = CGColorSpace(name: name) else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "Core Graphics color space \(colorSpace.rawValue) is unavailable"
            )
        }
        return space
    }

    static func attach(
        to pixelBuffer: CVPixelBuffer,
        colorSpace: ExportColorSpace
    ) throws {
        let primaries: CFString
        let transfer: CFString
        let matrix: CFString
        switch colorSpace {
        case .rec709:
            primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
            transfer = kCVImageBufferTransferFunction_ITU_R_709_2
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .displayP3:
            primaries = kCVImageBufferColorPrimaries_P3_D65
            transfer = kCVImageBufferTransferFunction_sRGB
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }

        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            primaries,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            transfer,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            matrix,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferCGColorSpaceKey,
            try cgColorSpace(for: colorSpace),
            .shouldPropagate
        )
    }

    static func attach(
        to pixelBuffer: CVPixelBuffer,
        colorSpace: ExportColorSpace,
        codec: ExportVideoCodec
    ) throws {
        try attach(to: pixelBuffer, colorSpace: colorSpace)
        if codec == .proRes4444 {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferAlphaChannelModeKey,
                kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                .shouldPropagate
            )
        }
    }
}
