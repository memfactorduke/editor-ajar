// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCLI

/// FR-COL-002 curves metric must remain attributable and budgeted without requiring Metal.
final class BenchmarkEffectNodeCurvesTests: XCTestCase {
    func testFRCOL002CurvesMetricHasStableTwoMillisecondGPUNodeBudget() throws {
        let metric = BenchmarkMetric.effectNodeCurvesGPU
        let budget = try XCTUnwrap(metric.budget, metric.rawValue)
        XCTAssertEqual(metric.requirementID, "FR-COL-002")
        XCTAssertTrue(metric.isSelfContainedEffectNodeMetric)
        XCTAssertEqual(metric.rawValue, "effect-node-curves-gpu-fr-col-002")
        XCTAssertEqual(budget.targetMilliseconds, 2)
        XCTAssertEqual(budget.noiseBandPercent, 5)
    }
}
