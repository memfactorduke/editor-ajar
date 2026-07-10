// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarExport

final class ExportProgressEstimatorTests: XCTestCase {
    func testFREXP005ProgressFractionIsMonotonicNonDecreasing() {
        var estimator = ExportProgressEstimator(windowSeconds: 2)
        var previous = -1.0
        let clock = ContinuousClock()
        var now = clock.now

        for frames in [0, 1, 2, 2, 3, 5, 5, 8, 10] as [Int64] {
            let estimate = estimator.update(
                progress: ExportProgress(framesWritten: frames, totalFrames: 10),
                now: now
            )
            XCTAssertGreaterThanOrEqual(estimate.fractionCompleted, previous)
            previous = estimate.fractionCompleted
            now = now.advanced(by: .milliseconds(50))
        }

        XCTAssertEqual(previous, 1.0, accuracy: 0.000_1)
    }

    func testFREXP005RollingETAAppearsAfterFrameDeltas() {
        var estimator = ExportProgressEstimator(windowSeconds: 2)
        let clock = ContinuousClock()
        var now = clock.now

        _ = estimator.update(
            progress: ExportProgress(framesWritten: 0, totalFrames: 100),
            now: now
        )
        now = now.advanced(by: .milliseconds(500))
        let mid = estimator.update(
            progress: ExportProgress(framesWritten: 25, totalFrames: 100),
            now: now
        )

        XCTAssertNotNil(mid.averageFramesPerSecond)
        XCTAssertNotNil(mid.estimatedSecondsRemaining)
        if let fps = mid.averageFramesPerSecond {
            XCTAssertGreaterThan(fps, 0)
        }
        if let eta = mid.estimatedSecondsRemaining {
            XCTAssertGreaterThan(eta, 0)
        }
    }

    func testFREXP005ResetClearsPeakFractionForRestart() {
        var estimator = ExportProgressEstimator()
        _ = estimator.update(progress: ExportProgress(framesWritten: 8, totalFrames: 10))
        estimator.reset()
        let after = estimator.update(progress: ExportProgress(framesWritten: 0, totalFrames: 10))
        XCTAssertEqual(after.fractionCompleted, 0)
    }
}
