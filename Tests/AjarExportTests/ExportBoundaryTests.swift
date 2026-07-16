// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AVFoundation
import CoreVideo
import Foundation
import XCTest

@testable import AjarExport

final class ExportBoundaryTests: XCTestCase {
    func testFREXP001DeliveryTransformScalesTheProjectCanvasToTheOutputRaster() {
        let transform = RenderGraphExportFrameProvider.deliveryTransform(
            from: PixelDimensions(width: 1_920, height: 1_080),
            to: PixelDimensions(width: 3_840, height: 2_160)
        )

        XCTAssertEqual(transform.a, 2)
        XCTAssertEqual(transform.d, 2)
        XCTAssertEqual(transform.tx, 0)
        XCTAssertEqual(transform.ty, 0)
    }

    func testFREXP002RejectsUnmodeledSurroundChannelLayouts() {
        XCTAssertThrowsError(
            try ExportAudioSettings(
                codec: .linearPCM,
                sampleRate: 48_000,
                channelCount: 6
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportSettingsValidationError,
                .audioChannelCountOutOfRange(6)
            )
        }
    }

    func testNFRSTAB003RecognizesLateEncoderRefusal() {
        let unavailable = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.encoderTemporarilyUnavailable.rawValue
        )
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: unavailable]
        )

        XCTAssertTrue(AVAssetExportWriter.isEncoderRefusal(unavailable))
        XCTAssertTrue(AVAssetExportWriter.isEncoderRefusal(wrapped))
        XCTAssertFalse(
            AVAssetExportWriter.isEncoderRefusal(
                NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue)
            )
        )
    }

    func testFREXP002DisplayP3AndAlphaTagsPropagateFromEncoderBuffers() throws {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            2,
            2,
            kCVPixelFormatType_64ARGB,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        try ExportColorTagging.attach(
            to: buffer,
            colorSpace: .displayP3,
            codec: .proRes4444
        )

        var mode = CVAttachmentMode.shouldNotPropagate
        XCTAssertEqual(
            CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, &mode) as? String,
            kCVImageBufferColorPrimaries_P3_D65 as String
        )
        XCTAssertEqual(mode, .shouldPropagate)
        XCTAssertEqual(
            CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String,
            kCVImageBufferTransferFunction_sRGB as String
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(buffer, kCVImageBufferAlphaChannelModeKey, nil) as? String,
            kCVImageBufferAlphaChannelMode_PremultipliedAlpha as String
        )
    }

    func testFREXP006CodecFreeImageDeliveryTagsOddBGRARaster() throws {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            31,
            33,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        try ExportColorTagging.attach(to: buffer, colorSpace: .displayP3)

        XCTAssertEqual(
            CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String,
            kCVImageBufferColorPrimaries_P3_D65 as String
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String,
            kCVImageBufferTransferFunction_sRGB as String
        )
        XCTAssertNil(
            CVBufferCopyAttachment(buffer, kCVImageBufferAlphaChannelModeKey, nil),
            "codec-free image delivery must not pretend to be ProRes 4444"
        )
    }

    func testNFRSTAB002MapsNativeAVFoundationDiskFullToTheRequestedURL() {
        let destinationURL = URL(fileURLWithPath: "/tmp/user-selected.mov")
        let error = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.diskFull.rawValue
        )

        XCTAssertEqual(
            ExportErrorMapper.map(error, destinationURL: destinationURL),
            .diskFull(destinationURL)
        )
    }
}
