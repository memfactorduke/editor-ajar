// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal
import XCTest

@testable import AjarCLI

/// FR-SPD-005 / FR-AUD-007: the retimed-playback and realtime plan-build benchmark metrics
/// carry their docs/PERFORMANCE.md budgets so flipping the report-only CI job to a gate is
/// mechanical.
final class BenchmarkRetimeCommandTests: XCTestCase {
    /// FR-SPD-005: a retimed-playback metric renders successfully and carries the 30 fps
    /// playback frame budget with the default five percent noise band.
    func testRetimedPlaybackBenchmarkCarriesPlaybackBudgetFRSPD005() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on this runner")
        }
        let result = try await runSingleBenchmark(
            metric: "retimed-constant-2x-playback-fr-spd-005"
        )

        XCTAssertEqual(result.requirementID, "FR-SPD-005")
        XCTAssertEqual(result.unit, "ms")
        XCTAssertGreaterThanOrEqual(result.value, 0)
        let budget = try XCTUnwrap(result.budgetMilliseconds)
        XCTAssertEqual(budget, 1_000.0 / 30.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.noiseBandPercent), 5)
        XCTAssertNotNil(result.withinBudget)
    }

    /// FR-SPD-005: every retimed-playback metric definition references FR-SPD-005 in its slug
    /// and carries the playback budget.
    func testEveryRetimedPlaybackMetricDefinitionReferencesFRSPD005() throws {
        let retimedMetrics = BenchmarkMetric.allCases.filter { metric in
            metric.rawValue.hasPrefix("retimed-")
        }

        XCTAssertEqual(retimedMetrics.count, 7)
        for metric in retimedMetrics {
            XCTAssertTrue(metric.rawValue.hasSuffix("fr-spd-005"), metric.rawValue)
            XCTAssertEqual(metric.requirementID, "FR-SPD-005")
            let budget = try XCTUnwrap(metric.budget)
            XCTAssertEqual(budget.targetMilliseconds, 1_000.0 / 30.0, accuracy: 0.001)
            XCTAssertEqual(budget.noiseBandPercent, 5)
        }
    }

    /// FR-AUD-007: the nested-compound plan-build metric (the issue #146 refill-pressure
    /// evidence) carries the one-second look-ahead refill budget derived from the live
    /// coordinator's two-second window and one-second refill margin.
    func testRealtimeAudioPlanBuildBenchmarkCarriesRefillBudgetFRSPD005() async throws {
        let result = try await runSingleBenchmark(
            metric: "rt-audio-plan-build-nested-compound-fr-aud-007"
        )

        XCTAssertEqual(result.requirementID, "FR-AUD-007")
        XCTAssertEqual(result.unit, "ms")
        XCTAssertGreaterThanOrEqual(result.value, 0)
        XCTAssertEqual(try XCTUnwrap(result.budgetMilliseconds), 1_000)
        XCTAssertEqual(try XCTUnwrap(result.noiseBandPercent), 5)
        XCTAssertNotNil(result.withinBudget)
    }

    /// FR-SPD-005: the retimed-audio plan build (2x varispeed plus one WSOLA pitch-corrected
    /// clip) runs against the same refill budget.
    func testRetimedAudioPlanBuildBenchmarkRunsAgainstRefillBudgetFRSPD005() async throws {
        let result = try await runSingleBenchmark(
            metric: "rt-audio-plan-build-retimed-fr-spd-005"
        )

        XCTAssertEqual(result.requirementID, "FR-SPD-005")
        XCTAssertEqual(try XCTUnwrap(result.budgetMilliseconds), 1_000)
        XCTAssertNotNil(result.withinBudget)
    }

    private func runSingleBenchmark(metric: String) async throws -> BenchmarkBudgetReportRow {
        let output = BufferedBenchmarkTextOutput()
        let errorOutput = BufferedBenchmarkTextOutput()
        let exitCode = await AjarCommand.run(
            arguments: ["bench", metric],
            standardOutput: output,
            standardError: errorOutput
        )

        let diagnosticOutput = (output.lines + errorOutput.lines).joined(separator: "\n")
        XCTAssertEqual(exitCode, 0, diagnosticOutput)
        let reportData = try XCTUnwrap(output.lines.joined(separator: "\n").data(using: .utf8))
        return try JSONDecoder().decode(BenchmarkBudgetReportRow.self, from: reportData)
    }
}

private struct BenchmarkBudgetReportRow: Decodable {
    let metric: String
    let value: Double
    let unit: String
    let requirementID: String
    let budgetMilliseconds: Double?
    let noiseBandPercent: Double?
    let withinBudget: Bool?
}

private final class BufferedBenchmarkTextOutput: AjarTextOutput {
    private(set) var lines: [String] = []

    func writeLine(_ line: String) {
        lines.append(line)
    }
}
