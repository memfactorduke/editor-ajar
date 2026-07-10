// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCLI

/// M8 exit typical-stack metric must stay attributable and budgeted without requiring Metal.
final class BenchmarkTypicalStackM8ExitTests: XCTestCase {
    func testTypicalStackM8ExitMetricHasTwentyEightMillisecondPlaybackBudget() throws {
        let metric = BenchmarkMetric.typicalStack1080pPlaybackM8Exit
        let budget = try XCTUnwrap(metric.budget, metric.rawValue)
        XCTAssertEqual(metric.rawValue, "typical-stack-1080p-playback-m8-exit")
        XCTAssertEqual(metric.requirementID, "NFR-PERF-003")
        XCTAssertTrue(metric.isSelfContainedEffectNodeMetric)
        XCTAssertEqual(budget.targetMilliseconds, 28)
        XCTAssertEqual(budget.noiseBandPercent, 5)
        // PERFORMANCE §2/§3: 30 fps frame is ~33.3 ms; 28 ms leaves headroom.
        XCTAssertLessThan(budget.targetMilliseconds, 1_000.0 / 30.0)
    }
}
