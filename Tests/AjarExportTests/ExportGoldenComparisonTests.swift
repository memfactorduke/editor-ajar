// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
import AVFoundation
import AjarCore
import Foundation
import XCTest

@testable import AjarExport

// swiftlint:enable sorted_imports

final class ExportGoldenComparisonTests: XCTestCase {
    func testFREXP007ToleranceBandsMatchDocumentedCodecClasses() {
        XCTAssertEqual(ExportGoldenTolerance.proRes422NearLossless.maximumChannelDelta, 3)
        XCTAssertEqual(ExportGoldenTolerance.proRes422NearLossless.maximumMeanAbsoluteError, 1.0)
        XCTAssertFalse(ExportGoldenTolerance.proRes422NearLossless.requireExactMatch)

        XCTAssertEqual(ExportGoldenTolerance.h264Lossy.maximumChannelDelta, 48)
        XCTAssertEqual(ExportGoldenTolerance.hevcLossy.maximumChannelDelta, 48)
        XCTAssertTrue(ExportGoldenTolerance.stillPNGBitExact.requireExactMatch)
        XCTAssertEqual(ExportGoldenTolerance.stillPNGBitExact.maximumChannelDelta, 0)

        XCTAssertEqual(ExportGoldenTolerance.forVideoCodec(.proRes422), .proRes422NearLossless)
        XCTAssertEqual(ExportGoldenTolerance.forVideoCodec(.h264), .h264Lossy)
        XCTAssertEqual(ExportGoldenTolerance.forVideoCodec(.hevc8Bit), .hevcLossy)
    }

    func testFREXP007ComparatorAcceptsWithinBandAndRejectsOutside() {
        let expected = ExportDecodedBGRAFrame(
            width: 2,
            height: 1,
            bgra8: Data([10, 20, 30, 255, 40, 50, 60, 255])
        )
        let within = ExportDecodedBGRAFrame(
            width: 2,
            height: 1,
            bgra8: Data([12, 20, 30, 255, 40, 50, 60, 255])
        )
        let outside = ExportDecodedBGRAFrame(
            width: 2,
            height: 1,
            bgra8: Data([20, 20, 30, 255, 40, 50, 60, 255])
        )

        let pass = ExportGoldenComparator.compare(
            actual: within,
            expected: expected,
            tolerance: .proRes422NearLossless
        )
        let fail = ExportGoldenComparator.compare(
            actual: outside,
            expected: expected,
            tolerance: .proRes422NearLossless
        )
        XCTAssertTrue(pass.passed)
        XCTAssertEqual(pass.maximumChannelDelta, 2)
        XCTAssertFalse(fail.passed)
        XCTAssertEqual(fail.maximumChannelDelta, 10)
    }

    func testFREXP007FlattenOverOpaqueBlackIsPremultipliedSafe() {
        let frame = ExportDecodedBGRAFrame(
            width: 1,
            height: 2,
            bgra8: Data([0, 0, 0, 0, 100, 150, 200, 64])
        )
        let flat = frame.flattenedOverOpaqueBlack()
        XCTAssertEqual(flat.bgra8[0], 0)
        XCTAssertEqual(flat.bgra8[1], 0)
        XCTAssertEqual(flat.bgra8[2], 0)
        XCTAssertEqual(flat.bgra8[3], 255)
        XCTAssertEqual(flat.bgra8[4], 100)
        XCTAssertEqual(flat.bgra8[5], 150)
        XCTAssertEqual(flat.bgra8[6], 200)
        XCTAssertEqual(flat.bgra8[7], 255)
    }

    func testFREXP007StillPNGRequiresBitExact() {
        let expected = ExportDecodedBGRAFrame(
            width: 1,
            height: 1,
            bgra8: Data([1, 2, 3, 255])
        )
        let actual = ExportDecodedBGRAFrame(
            width: 1,
            height: 1,
            bgra8: Data([1, 2, 4, 255])
        )
        let comparison = ExportGoldenComparator.compare(
            actual: actual,
            expected: expected,
            tolerance: .stillPNGBitExact
        )
        XCTAssertFalse(comparison.passed)
    }

    func testFREXP007DecodedPixelHasherIsStableAndOrderSensitive() {
        let frameA = ExportDecodedBGRAFrame(
            width: 1,
            height: 1,
            bgra8: Data([0, 0, 255, 255])
        )
        let frameB = ExportDecodedBGRAFrame(
            width: 1,
            height: 1,
            bgra8: Data([0, 255, 0, 255])
        )

        let hashA1 = ExportDecodedPixelHasher.hashFrame(frameA)
        let hashA2 = ExportDecodedPixelHasher.hashFrame(frameA)
        XCTAssertEqual(hashA1, hashA2)
        XCTAssertNotEqual(
            ExportDecodedPixelHasher.hashFrame(frameA),
            ExportDecodedPixelHasher.hashFrame(frameB)
        )

        let seqAB = ExportDecodedPixelHasher.hashFrames([frameA, frameB])
        let seqBA = ExportDecodedPixelHasher.hashFrames([frameB, frameA])
        let seqABAgain = ExportDecodedPixelHasher.hashFrames([frameA, frameB])
        XCTAssertEqual(seqAB, seqABAgain)
        XCTAssertNotEqual(seqAB, seqBA)
    }

    func testFREXP007AudioPCMHasherIsDeterministic() {
        let samples: [Float] = [0, 0.25, -0.5, 1]
        XCTAssertEqual(
            ExportDecodedPixelHasher.hashAudioPCM(samples),
            ExportDecodedPixelHasher.hashAudioPCM(samples)
        )
        XCTAssertNotEqual(
            ExportDecodedPixelHasher.hashAudioPCM(samples),
            ExportDecodedPixelHasher.hashAudioPCM([0, 0.25, -0.5, 0.99])
        )
    }

    func testFREXP007HardwareEncoderUnavailableMatcherMatchesSmokePattern() {
        for status in -12_906 ... -12_902 {
            let error = ExportError.appendRefused(
                .video,
                reason: "encoder unavailable",
                underlyingError: makeVideoToolboxAppendError(status: status)
            )
            XCTAssertTrue(error.isHardwareEncoderUnavailable(for: .h264))
            XCTAssertTrue(error.isHardwareEncoderUnavailable(for: .hevc8Bit))
            XCTAssertFalse(error.isHardwareEncoderUnavailable(for: .proRes422))
        }
        XCTAssertTrue(
            ExportError.encoderRefused(codec: .h264, reason: "busy")
                .isHardwareEncoderUnavailable(for: .h264)
        )
        XCTAssertFalse(
            ExportError.writerFailed("nope").isHardwareEncoderUnavailable(for: .h264)
        )
    }
}

private func makeVideoToolboxAppendError(status: Int) -> NSError {
    let videoToolboxError = NSError(domain: NSOSStatusErrorDomain, code: status)
    return NSError(
        domain: AVFoundationErrorDomain,
        code: AVError.Code.unknown.rawValue,
        userInfo: [NSUnderlyingErrorKey: videoToolboxError]
    )
}
