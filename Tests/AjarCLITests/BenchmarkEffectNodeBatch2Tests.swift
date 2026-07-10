// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCLI

/// FR-FX-002 batch-2 metrics must remain attributable and budgeted without requiring Metal.
final class BenchmarkEffectNodeBatch2Tests: XCTestCase {
    func testFRFX002Batch2EveryKindHasStableTwoMillisecondGPUNodeBudget() throws {
        let metrics: [BenchmarkMetric] = [
            .effectNodeVignette1080p,
            .effectNodeMirror1080p,
            .effectNodeMosaic1080p,
            .effectNodeColorAdjust1080p,
            .effectNodePosterize1080p,
            .effectNodeInvert1080p
        ]

        for metric in metrics {
            let budget = try XCTUnwrap(metric.budget, metric.rawValue)
            XCTAssertEqual(metric.requirementID, "FR-FX-002")
            XCTAssertTrue(metric.isSelfContainedEffectNodeMetric)
            XCTAssertEqual(budget.targetMilliseconds, 2)
            XCTAssertEqual(budget.noiseBandPercent, 5)
        }
    }
}
