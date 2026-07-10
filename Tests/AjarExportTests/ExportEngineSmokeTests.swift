// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
import AVFoundation
import AjarAudio
import AjarCore
import AjarRender
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox
import XCTest

@testable import AjarExport

// swiftlint:enable sorted_imports

final class ExportEngineSmokeTests: XCTestCase {
    func testFREXP001002ExportsTenFramesToH264MP4WithColorTags() async throws {
        let fixture = try ExportSmokeFixture(
            container: .mp4,
            codec: .h264,
            audioCodec: .aac,
            colorSpace: .rec709
        )

        try await runSkippingUnavailableHardwareEncoder(
            fixture,
            codec: .h264,
            name: "H.264"
        )

        try await fixture.assertAsset(
            expectedVideoSubtype: kCMVideoCodecType_H264,
            expectedPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String
        )
    }

    func testFREXP001002ExportsTenFramesToProResMOVWithColorTags() async throws {
        let fixture = try ExportSmokeFixture(
            container: .mov,
            codec: .proRes422,
            audioCodec: .linearPCM,
            colorSpace: .rec709
        )

        try await fixture.run()
        try await fixture.assertAsset(
            expectedVideoSubtype: kCMVideoCodecType_AppleProRes422,
            expectedPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String
        )
    }

    func testFREXP001002ExportsTenFramesToHEVC10Main10WithColorTags() async throws {
        let fixture = try ExportSmokeFixture(
            container: .mp4,
            codec: .hevc10Bit,
            audioCodec: .aac,
            colorSpace: .rec709
        )

        try await runSkippingUnavailableHardwareEncoder(
            fixture,
            codec: .hevc10Bit,
            name: "HEVC 10-bit"
        )

        try await fixture.assertAsset(
            expectedVideoSubtype: kCMVideoCodecType_HEVC,
            expectedPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
            requireHEVCMain10: true
        )
    }

    func testFREXP002ExportsDisplayP3WithPrimariesTags() async throws {
        let fixture = try ExportSmokeFixture(
            container: .mp4,
            codec: .h264,
            audioCodec: .aac,
            colorSpace: .displayP3
        )

        try await runSkippingUnavailableHardwareEncoder(
            fixture,
            codec: .h264,
            name: "H.264"
        )

        try await fixture.assertAsset(
            expectedVideoSubtype: kCMVideoCodecType_H264,
            expectedPrimaries: kCMFormatDescriptionColorPrimaries_P3_D65 as String
        )
    }

    func testFREXP001002ProRes4444PreservesPremultipliedAlpha() async throws {
        let fixture = try ExportSmokeFixture(
            container: .mov,
            codec: .proRes4444,
            audioCodec: .linearPCM,
            colorSpace: .rec709,
            includeAudio: false
        )

        try await fixture.run()

        try await fixture.assertAsset(
            expectedVideoSubtype: kCMVideoCodecType_AppleProRes4444,
            expectedPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
            requireAlphaChannel: true
        )
        try await fixture.assertDecodedCornerIsTransparentPremultiplied()
    }

    func testNFRSTAB003RecognizesVideoToolboxEncoderUnavailableAppendFailures() {
        for status in -12_906 ... -12_902 {
            let error = ExportError.appendRefused(
                .video,
                reason: "encoder unavailable",
                underlyingError: makeVideoToolboxAppendError(status: status)
            )

            XCTAssertTrue(error.isHardwareEncoderUnavailable(for: .h264))
            XCTAssertTrue(error.isHardwareEncoderUnavailable(for: .hevc10Bit))
            XCTAssertFalse(error.isHardwareEncoderUnavailable(for: .proRes422))
        }
    }

    func testNFRSTAB003RejectsOtherAppendFailuresAsEncoderUnavailable() {
        let outsideStatusRange = ExportError.appendRefused(
            .video,
            reason: "different VideoToolbox failure",
            underlyingError: makeVideoToolboxAppendError(status: -12_901)
        )
        let belowStatusRange = ExportError.appendRefused(
            .video,
            reason: "different VideoToolbox failure",
            underlyingError: makeVideoToolboxAppendError(status: -12_907)
        )
        let wrongOuterCode = ExportError.appendRefused(
            .video,
            reason: "different AVFoundation failure",
            underlyingError: makeVideoToolboxAppendError(
                status: -12_903,
                outerCode: AVError.Code.decodeFailed.rawValue
            )
        )
        let wrongOuterDomain = ExportError.appendRefused(
            .video,
            reason: "different outer domain",
            underlyingError: makeVideoToolboxAppendError(
                status: -12_903,
                outerDomain: NSCocoaErrorDomain
            )
        )
        let wrongUnderlyingDomain = ExportError.appendRefused(
            .video,
            reason: "different underlying domain",
            underlyingError: makeVideoToolboxAppendError(
                status: -12_903,
                underlyingDomain: NSPOSIXErrorDomain
            )
        )
        let audioAppend = ExportError.appendRefused(
            .audio,
            reason: "audio append failed",
            underlyingError: makeVideoToolboxAppendError(status: -12_903)
        )

        XCTAssertFalse(outsideStatusRange.isHardwareEncoderUnavailable(for: .h264))
        XCTAssertFalse(belowStatusRange.isHardwareEncoderUnavailable(for: .h264))
        XCTAssertFalse(wrongOuterCode.isHardwareEncoderUnavailable(for: .h264))
        XCTAssertFalse(wrongOuterDomain.isHardwareEncoderUnavailable(for: .h264))
        XCTAssertFalse(wrongUnderlyingDomain.isHardwareEncoderUnavailable(for: .h264))
        XCTAssertFalse(audioAppend.isHardwareEncoderUnavailable(for: .h264))
        XCTAssertFalse(
            ExportError.writerFailed("unrelated").isHardwareEncoderUnavailable(for: .h264)
        )
    }

    func testNFRSTAB003RecognizesOnlyMatchingTypedEncoderRefusals() {
        let h264Refusal = ExportError.encoderRefused(codec: .h264, reason: "settings rejected")

        XCTAssertTrue(h264Refusal.isHardwareEncoderUnavailable(for: .h264))
        XCTAssertFalse(h264Refusal.isHardwareEncoderUnavailable(for: .hevc10Bit))
        XCTAssertFalse(h264Refusal.isHardwareEncoderUnavailable(for: .proRes422))
    }
}

private func runSkippingUnavailableHardwareEncoder(
    _ fixture: ExportSmokeFixture,
    codec: ExportVideoCodec,
    name: String
) async throws {
    do {
        try await fixture.run()
    } catch let error as ExportError {
        guard error.isHardwareEncoderUnavailable(for: codec) else {
            throw error
        }
        throw XCTSkip("\(name) hardware encoder unavailable on this runner: \(error)")
    }
}

private func makeVideoToolboxAppendError(
    status: Int,
    outerCode: Int = AVError.Code.unknown.rawValue,
    outerDomain: String = AVFoundationErrorDomain,
    underlyingDomain: String = NSOSStatusErrorDomain
) -> NSError {
    let videoToolboxError = NSError(domain: underlyingDomain, code: status)
    return NSError(
        domain: outerDomain,
        code: outerCode,
        userInfo: [NSUnderlyingErrorKey: videoToolboxError]
    )
}
