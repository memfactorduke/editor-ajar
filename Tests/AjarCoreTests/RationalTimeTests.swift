// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class RationalTimeTests: XCTestCase {
    func testADR0008NormalizesEquivalentTimes() throws {
        XCTAssertEqual(
            try RationalTime(value: 30, timescale: 60),
            try RationalTime(value: 1, timescale: 2)
        )
        XCTAssertEqual(
            try RationalTime(value: -30, timescale: 60),
            try RationalTime(value: -1, timescale: 2)
        )
        XCTAssertEqual(try RationalTime(value: 0, timescale: 48_000), .zero)
    }

    func testNFRSTAB003RejectsInvalidTimescaleWithoutCrashing() {
        XCTAssertThrowsError(try RationalTime(value: 1, timescale: 0)) { error in
            XCTAssertEqual(error as? RationalTimeError, .invalidTimescale(0))
        }
    }

    func testADR0008ComparesAcrossTimescalesExactly() throws {
        let oneThird = try RationalTime(value: 1, timescale: 3)
        let twoSixths = try RationalTime(value: 2, timescale: 6)
        let half = try RationalTime(value: 1, timescale: 2)
        let negativeQuarter = try RationalTime(value: -1, timescale: 4)

        XCTAssertEqual(oneThird, twoSixths)
        XCTAssertLessThan(oneThird, half)
        XCTAssertLessThan(negativeQuarter, .zero)
        XCTAssertLessThan(negativeQuarter, oneThird)
    }

    func testADR0008AddsAndSubtractsWithCommonTimelineRates() throws {
        let oneFrameAt24 = try RationalTime(value: 1, timescale: 24)
        let oneFrameAt30 = try RationalTime(value: 1, timescale: 30)

        XCTAssertEqual(
            try oneFrameAt24.adding(oneFrameAt30),
            try RationalTime(value: 3, timescale: 40)
        )
        XCTAssertEqual(
            try oneFrameAt24.subtracting(oneFrameAt30),
            try RationalTime(value: 1, timescale: 120)
        )
        XCTAssertEqual(try oneFrameAt24 + oneFrameAt30, try RationalTime(value: 3, timescale: 40))
        XCTAssertEqual(try oneFrameAt24 - oneFrameAt30, try RationalTime(value: 1, timescale: 120))
    }

    func testADR0008SupportsNegativeArithmetic() throws {
        let start = try RationalTime(value: -3, timescale: 2)
        let offset = try RationalTime(value: 5, timescale: 4)

        XCTAssertEqual(try start.adding(offset), try RationalTime(value: -1, timescale: 4))
        XCTAssertEqual(try start.negated(), try RationalTime(value: 3, timescale: 2))
        XCTAssertEqual(try -start, try RationalTime(value: 3, timescale: 2))
        XCTAssertEqual(try offset.multiplied(by: -2), try RationalTime(value: -5, timescale: 2))
        XCTAssertEqual(try offset * -2, try RationalTime(value: -5, timescale: 2))
        XCTAssertEqual(try -2 * offset, try RationalTime(value: -5, timescale: 2))
        XCTAssertEqual(try offset / 5, try RationalTime(value: 1, timescale: 4))
    }

    func testADR0008AdditionAndSubtractionRoundTripProperty() throws {
        for leftValue in -6...6 {
            for rightValue in -6...6 {
                let left = try RationalTime(value: Int64(leftValue), timescale: 24)
                let right = try RationalTime(value: Int64(rightValue), timescale: 30)

                XCTAssertEqual(try left.adding(right).subtracting(right), left)
                XCTAssertEqual(try left.subtracting(right).adding(right), left)
            }
        }
    }

    func testADR0008AdditionIsAssociativeAndCommutativeProperty() throws {
        for leftValue in -3...3 {
            for middleValue in -3...3 {
                for rightValue in -3...3 {
                    let left = try RationalTime(value: Int64(leftValue), timescale: 24)
                    let middle = try RationalTime(value: Int64(middleValue), timescale: 30)
                    let right = try RationalTime(value: Int64(rightValue), timescale: 48)
                    let leftGrouped = try left.adding(middle).adding(right)
                    let rightGrouped = try left.adding(middle.adding(right))

                    XCTAssertEqual(try left.adding(middle), try middle.adding(left))
                    XCTAssertEqual(leftGrouped, rightGrouped)
                }
            }
        }
    }

    func testADR0008OrderingIsTotalProperty() throws {
        var times: [RationalTime] = []
        times.append(try RationalTime(value: -2, timescale: 3))
        times.append(try RationalTime(value: -1, timescale: 4))
        times.append(.zero)
        times.append(try RationalTime(value: 1, timescale: 5))
        times.append(try RationalTime(value: 2, timescale: 7))

        for left in times {
            for right in times {
                XCTAssertTrue(left < right || left == right || left > right)
                if left < right {
                    XCTAssertFalse(right < left)
                }
            }
        }
    }

    func testADR0008ComparisonDoesNotOverflowForLargeValues() throws {
        let almostOne = try RationalTime(value: Int64.max - 1, timescale: Int64.max)
        let justOverOne = try RationalTime(value: Int64.max, timescale: Int64.max - 1)

        XCTAssertLessThan(almostOne, justOverOne)
    }

    func testNFRSTAB003ReportsArithmeticOverflowWithoutCrashing() throws {
        let maxSeconds = try RationalTime(value: Int64.max, timescale: 1)

        XCTAssertThrowsError(try maxSeconds.adding(maxSeconds)) { error in
            XCTAssertEqual(error as? RationalTimeError, .arithmeticOverflow)
        }
        XCTAssertThrowsError(try maxSeconds.multiplied(by: 2)) { error in
            XCTAssertEqual(error as? RationalTimeError, .arithmeticOverflow)
        }
    }

    func testADR0008RescalesExactlyAndPreservesValue() throws {
        let time = try RationalTime(value: 3, timescale: 24)
        let rescaled = try time.rescaled(toTimescale: 8)
        let common = try time.valuesAtCommonTimescale(with: RationalTime(value: 1, timescale: 6))

        XCTAssertEqual(try time.value(atTimescale: 8), 1)
        XCTAssertEqual(rescaled, time)
        XCTAssertEqual(common.left, 3)
        XCTAssertEqual(common.right, 4)
        XCTAssertEqual(common.timescale, 24)
    }

    func testNFRSTAB003RejectsInexactRescaleWithoutCrashing() throws {
        let oneThird = try RationalTime(value: 1, timescale: 3)

        XCTAssertThrowsError(try oneThird.value(atTimescale: 10)) { error in
            XCTAssertEqual(
                error as? RationalTimeError,
                .inexactRescale(value: oneThird, timescale: 10)
            )
        }
    }

    func testADR0008ConvertsFramesAtIntegerFrameRate() throws {
        let frameRate = try FrameRate(frames: 24)
        let time = try RationalTime.atFrame(12, frameRate: frameRate)

        XCTAssertEqual(time, try RationalTime(value: 1, timescale: 2))
        XCTAssertEqual(try time.frameIndex(at: frameRate), 12)
    }

    func testADR0008ConvertsCommonIntegerFrameRatesExactly() throws {
        for framesPerSecond in [24, 25, 30, 48, 60] {
            let frameRate = try FrameRate(frames: Int64(framesPerSecond))
            let twoSeconds = try RationalTime.atFrame(
                Int64(framesPerSecond * 2),
                frameRate: frameRate
            )

            XCTAssertEqual(twoSeconds, try RationalTime(value: 2, timescale: 1))
            XCTAssertEqual(try twoSeconds.frameIndex(at: frameRate), Int64(framesPerSecond * 2))
        }
    }

    func testADR0008ConvertsFramesAtNTSCRateExactly() throws {
        let frameRate = try FrameRate(frames: 30_000, per: 1_001)
        let time = try RationalTime.atFrame(30_000, frameRate: frameRate)

        XCTAssertEqual(time, try RationalTime(value: 1_001, timescale: 1))
        XCTAssertEqual(try time.frameIndex(at: frameRate), 30_000)
    }

    func testADR0008SecondsAccessorIsDisplayOnlyAndLossy() throws {
        let oneThird = try RationalTime(value: 1, timescale: 3)

        XCTAssertEqual(oneThird.seconds, 1.0 / 3.0, accuracy: 0.000_000_000_001)
    }

    func testADR0008RoundsFrameIndexes() throws {
        let frameRate = try FrameRate(frames: 24)
        let justBeforeOneFrame = try RationalTime(value: 41, timescale: 1_000)
        let halfFrame = try RationalTime(value: 1, timescale: 48)
        let negativeHalfFrame = try RationalTime(value: -1, timescale: 48)

        XCTAssertEqual(try justBeforeOneFrame.frameIndex(at: frameRate, rounding: .towardZero), 0)
        XCTAssertEqual(try justBeforeOneFrame.frameIndex(at: frameRate, rounding: .up), 1)
        XCTAssertEqual(try halfFrame.frameIndex(at: frameRate, rounding: .nearestOrAwayFromZero), 1)
        XCTAssertEqual(
            try negativeHalfFrame.frameIndex(at: frameRate, rounding: .nearestOrAwayFromZero),
            -1
        )
    }

    func testADR0008TimeRangesAreHalfOpen() throws {
        let range = try TimeRange(
            start: RationalTime(value: 10, timescale: 1),
            duration: RationalTime(value: 5, timescale: 1)
        )

        XCTAssertTrue(try range.contains(RationalTime(value: 10, timescale: 1)))
        XCTAssertTrue(try range.contains(RationalTime(value: 14, timescale: 1)))
        XCTAssertFalse(try range.contains(RationalTime(value: 15, timescale: 1)))
        XCTAssertEqual(try range.end(), try RationalTime(value: 15, timescale: 1))
    }

    func testNFRSTAB003RejectsNegativeRangeDurationWithoutCrashing() throws {
        let negativeDuration = try RationalTime(value: -1, timescale: 1)

        XCTAssertThrowsError(
            try TimeRange(start: .zero, duration: negativeDuration)
        ) { error in
            XCTAssertEqual(error as? RationalTimeError, .negativeDuration(negativeDuration))
        }
    }
}
