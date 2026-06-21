// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class AnimatableTests: XCTestCase {
    func testFRKEY001EmptyKeyframesEvaluateBase() throws {
        let animation = try Animatable<Double>(base: 42)

        XCTAssertEqual(animation.value(at: .zero), 42)
        XCTAssertEqual(
            animation.value(at: try RationalTime(value: 10, timescale: 1)),
            42
        )
    }

    func testFRKEY003ExactKeyframeTimesReturnKeyframeValues() throws {
        let animation = try Animatable(
            base: -1,
            keyframes: makeKeyframes(
                keyframe(seconds: 0, value: 10, interpolation: .linear),
                keyframe(seconds: 1, value: 20, interpolation: .linear),
                keyframe(seconds: 3, value: 80, interpolation: .hold)
            )
        )

        XCTAssertEqual(animation.value(at: try time(seconds: 0)), 10)
        XCTAssertEqual(animation.value(at: try time(seconds: 1)), 20)
        XCTAssertEqual(animation.value(at: try time(seconds: 3)), 80)
    }

    func testFRKEY003HoldAndLinearBetweenKeyframesUseLeftInterpolationMode() throws {
        let hold = try Animatable(
            base: -1,
            keyframes: makeKeyframes(
                keyframe(seconds: 0, value: 0, interpolation: .hold),
                keyframe(seconds: 10, value: 100, interpolation: .linear)
            )
        )
        let linear = try Animatable(
            base: -1,
            keyframes: makeKeyframes(
                keyframe(seconds: 0, value: 0, interpolation: .linear),
                keyframe(seconds: 10, value: 100, interpolation: .hold)
            )
        )

        XCTAssertEqual(hold.value(at: try time(seconds: 5)), 0)
        XCTAssertEqual(linear.value(at: try time(seconds: 5)), 50)
    }

    func testFRKEY001ClampsBeforeFirstAndAfterLastKeyframes() throws {
        let animation = try Animatable(
            base: -1,
            keyframes: makeKeyframes(
                keyframe(seconds: 2, value: 20, interpolation: .linear),
                keyframe(seconds: 4, value: 40, interpolation: .linear)
            )
        )

        XCTAssertEqual(animation.value(at: try time(seconds: 1)), 20)
        XCTAssertEqual(animation.value(at: try time(seconds: 5)), 40)
    }

    func testFRKEY009LinearFractionUsesExactRationalTimePosition() throws {
        let animation = try Animatable(
            base: 0,
            keyframes: makeKeyframes(
                keyframe(
                    time: try RationalTime(value: 1, timescale: 3),
                    value: 3,
                    interpolation: .linear
                ),
                keyframe(
                    time: try RationalTime(value: 2, timescale: 3),
                    value: 9,
                    interpolation: .hold
                )
            )
        )

        XCTAssertEqual(
            animation.value(at: try RationalTime(value: 1, timescale: 2)),
            6
        )
    }

    func testFRKEY009DeterminismPropertyAtKeyframesAndRepeatedEvaluation() throws {
        let keyframes = makeKeyframes(
            keyframe(
                time: try RationalTime(value: 0, timescale: 24),
                value: 0,
                interpolation: .linear
            ),
            keyframe(
                time: try RationalTime(value: 12, timescale: 24),
                value: 12,
                interpolation: .hold
            ),
            keyframe(
                time: try RationalTime(value: 36, timescale: 24),
                value: 24,
                interpolation: .linear
            ),
            keyframe(
                time: try RationalTime(value: 48, timescale: 24),
                value: 36,
                interpolation: .hold
            )
        )
        let animation = try Animatable(base: -1, keyframes: keyframes)

        for keyframe in keyframes {
            XCTAssertEqual(animation.value(at: keyframe.time), keyframe.value)
        }

        for sample in -6...54 {
            let time = try RationalTime(value: Int64(sample), timescale: 24)
            let firstEvaluation = animation.value(at: time)
            let secondEvaluation = animation.value(at: time)

            XCTAssertEqual(firstEvaluation, secondEvaluation)
        }
    }

    func testNFRSTAB003RejectsUnsortedKeyframesWithoutCrashing() throws {
        let first = try keyframe(seconds: 2, value: 2, interpolation: .linear)
        let second = try keyframe(seconds: 1, value: 1, interpolation: .linear)
        let expectedError = AnimatableValidationError.keyframesNotSorted(
            previousIndex: 0,
            index: 1,
            previousTime: first.time,
            time: second.time
        )

        XCTAssertEqual(
            Animatable<Double>.validate(keyframes: [first, second]),
            .invalid(expectedError)
        )

        XCTAssertThrowsError(
            try Animatable(base: 0, keyframes: [first, second])
        ) { error in
            XCTAssertEqual(error as? AnimatableValidationError, expectedError)
        }
    }

    func testNFRSTAB003RejectsDuplicateKeyframeTimesWithoutCrashing() throws {
        let first = try keyframe(seconds: 1, value: 1, interpolation: .linear)
        let second = try keyframe(seconds: 1, value: 2, interpolation: .hold)
        let expectedError = AnimatableValidationError.duplicateKeyframeTime(
            previousIndex: 0,
            index: 1,
            time: first.time
        )

        XCTAssertEqual(
            Animatable<Double>.validate(keyframes: [first, second]),
            .invalid(expectedError)
        )

        XCTAssertThrowsError(
            try Animatable(base: 0, keyframes: [first, second])
        ) { error in
            XCTAssertEqual(error as? AnimatableValidationError, expectedError)
        }
    }

    func testFRKEY001AnimatableAndKeyframesRoundTripThroughCodable() throws {
        let animation = try Animatable(
            base: 7,
            keyframes: makeKeyframes(
                keyframe(seconds: 0, value: 10, interpolation: .hold),
                keyframe(seconds: 2, value: 30, interpolation: .linear)
            )
        )

        let encoded = try JSONEncoder().encode(animation)
        let decoded = try JSONDecoder().decode(Animatable<Double>.self, from: encoded)

        XCTAssertEqual(decoded, animation)
    }

    private func keyframe(
        seconds: Int64,
        value: Double,
        interpolation: InterpolationMode
    ) throws -> Keyframe<Double> {
        try keyframe(time: time(seconds: seconds), value: value, interpolation: interpolation)
    }

    private func keyframe(
        time: RationalTime,
        value: Double,
        interpolation: InterpolationMode
    ) -> Keyframe<Double> {
        Keyframe(time: time, value: value, interpolation: interpolation)
    }

    private func time(seconds: Int64) throws -> RationalTime {
        try RationalTime(value: seconds, timescale: 1)
    }

    private func makeKeyframes(_ keyframes: Keyframe<Double>...) -> [Keyframe<Double>] {
        keyframes
    }
}
