// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCLI

/// FR-TXT-001 styled title metric must stay attributable and budgeted without requiring Metal.
final class BenchmarkTitleNodeTests: XCTestCase {
    func testFRTXT001StyledTitleMetricHasTenMillisecondNodeBudget() throws {
        let metric = BenchmarkMetric.titleNodeStyled1080p
        let budget = try XCTUnwrap(metric.budget, metric.rawValue)
        XCTAssertEqual(metric.rawValue, "title-node-styled-1080p-fr-txt-001")
        XCTAssertEqual(metric.requirementID, "FR-TXT-001")
        XCTAssertTrue(metric.isSelfContainedEffectNodeMetric)
        XCTAssertEqual(budget.targetMilliseconds, 10)
        XCTAssertEqual(budget.noiseBandPercent, 5)
        // Heavier than pure GPU effect nodes (2–6 ms) because CoreText raster is CPU-side,
        // still well under the 30 fps frame (~33.3 ms).
        XCTAssertLessThan(budget.targetMilliseconds, 1_000.0 / 30.0)
        XCTAssertGreaterThan(budget.targetMilliseconds, 6)
    }
}
