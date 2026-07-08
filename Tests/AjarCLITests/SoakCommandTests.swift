// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarCLI

/// Covers the `ajar soak` leak/allocations harness (NFR-STAB-005).
final class SoakCommandTests: XCTestCase {
    // MARK: - Deterministic script (TESTING §3: seeded, recorded RNG)

    func testNFRSTAB005EditScriptIsDeterministicForFixedSeed() throws {
        let fixture = try SoakSyntheticProject.makeFixture(
            variant: 1,
            movieURL: URL(fileURLWithPath: "/nonexistent/soak-test.mov")
        )
        var firstRNG = SoakDeterministicRandom(seed: 0xFEED)
        var secondRNG = SoakDeterministicRandom(seed: 0xFEED)

        let first = try SoakEditScript.run(fixture: fixture, using: &firstRNG)
        let second = try SoakEditScript.run(fixture: fixture, using: &secondRNG)

        XCTAssertEqual(first.project, second.project)
        XCTAssertEqual(first.commandCount, second.commandCount)
        XCTAssertGreaterThanOrEqual(first.commandCount, 8)
        XCTAssertNotEqual(first.project, fixture.project)
        XCTAssertEqual(first.project.validate(), .valid)
    }

    func testNFRSTAB005EditScriptDivergesForDifferentSeeds() throws {
        let fixture = try SoakSyntheticProject.makeFixture(
            variant: 0,
            movieURL: URL(fileURLWithPath: "/nonexistent/soak-test.mov")
        )
        var firstRNG = SoakDeterministicRandom(seed: 1)
        var secondRNG = SoakDeterministicRandom(seed: 2)

        let first = try SoakEditScript.run(fixture: fixture, using: &firstRNG)
        let second = try SoakEditScript.run(fixture: fixture, using: &secondRNG)

        XCTAssertNotEqual(first.project, second.project)
    }

    // MARK: - Memory trend evaluation (typed errors + growth curve report)

    func testNFRSTAB005MemoryTrendAcceptsFlatSteadyState() throws {
        let jitter: [Int64] = [0, 3, -2, 1, -1, 2, 0, -3, 1, 0]
        let samples = jitter.enumerated().map { index, offset in
            makeSample(iteration: index, megabytes: Int64(200) + offset)
        }

        let report = try SoakMemoryTrend.evaluate(samples: samples, policy: .standard)

        XCTAssertEqual(report.samples.count, samples.count)
        let growth = Int64(report.peakBytes) - Int64(report.baselineBytes)
        XCTAssertLessThanOrEqual(growth, Int64(SoakGrowthPolicy.standard.growthBandBytes))
    }

    func testNFRSTAB005MemoryTrendBandViolationThrowsTypedError() {
        let samples = [200, 201, 200, 202, 201, 280].enumerated().map { index, megabytes in
            makeSample(iteration: index, megabytes: Int64(megabytes))
        }

        XCTAssertThrowsError(
            try SoakMemoryTrend.evaluate(samples: samples, policy: .standard)
        ) { error in
            guard case .memoryGrowthExceededBand(let report)? = error as? SoakError else {
                return XCTFail("expected memoryGrowthExceededBand, got \(error)")
            }
            XCTAssertEqual(report.samples.count, samples.count)
            XCTAssertTrue(
                String(describing: error).contains("iteration 5"),
                "the typed error must include the growth curve"
            )
        }
    }

    func testNFRSTAB005MemoryTrendMonotonicGrowthThrowsTypedError() {
        // +2 MiB per iteration: inside the 64 MiB band, but strictly increasing quartile
        // means with a 12 MiB rise — beyond the 8 MiB monotonic noise tolerance.
        let samples = (0..<8).map { index in
            makeSample(iteration: index, megabytes: 200 + Int64(index) * 2)
        }

        XCTAssertThrowsError(
            try SoakMemoryTrend.evaluate(samples: samples, policy: .standard)
        ) { error in
            guard case .monotonicGrowthDetected? = error as? SoakError else {
                return XCTFail("expected monotonicGrowthDetected, got \(error)")
            }
        }
    }

    func testNFRSTAB005MemoryTrendSlowLinearLeakFailsFittedSlopeCheck() {
        // 10 MiB of perfectly linear growth over 2,400 samples: inside the 64 MiB band, and
        // the quartile-mean rise is 7.5 MiB — under the 8 MiB monotonic tolerance — so only
        // the least-squares slope check can see this leak (~10 MiB/hour at soak pace).
        let samples = makeLinearSamples(count: 2_400, totalGrowthMegabytes: 10)

        XCTAssertThrowsError(
            try SoakMemoryTrend.evaluate(samples: samples, policy: .standard)
        ) { error in
            guard case .linearGrowthDetected(let report)? = error as? SoakError else {
                return XCTFail("expected linearGrowthDetected, got \(error)")
            }
            XCTAssertGreaterThan(
                report.fittedGrowthBytes,
                Double(SoakGrowthPolicy.standard.slopeToleranceBytes)
            )
            XCTAssertTrue(
                String(describing: error).contains("fitted slope"),
                "the typed error must report the fitted slope"
            )
        }
    }

    func testNFRSTAB005MemoryTrendSlopeCheckNotEnforcedBelowSampleFloor() throws {
        // The same linear leak with fewer samples than the documented 2,000-sample floor:
        // short (PR-duration) runs are jitter-dominated, so the slope check must not fire.
        let samples = makeLinearSamples(count: 500, totalGrowthMegabytes: 10)

        let report = try SoakMemoryTrend.evaluate(samples: samples, policy: .standard)

        XCTAssertLessThan(samples.count, SoakMemoryTrend.slopeMinimumSampleCount)
        XCTAssertEqual(report.fittedGrowthBytes, 10 * 1_024 * 1_024, accuracy: 64 * 1_024)
    }

    func testNFRSTAB005MemoryTrendJitteryFlatLongRunPassesAllChecks() throws {
        // A long trend-free series with deterministic +/-5 MiB jitter passes the band,
        // quartile, and fitted-slope checks alike.
        let base = 200.0 * 1_024 * 1_024
        let samples = (0..<2_400).map { index -> SoakMemorySample in
            let jitter = sin(Double(index) * 0.7) * 5 * 1_024 * 1_024
            let footprint = UInt64(base + jitter)
            return SoakMemorySample(
                iteration: index,
                physicalFootprintBytes: footprint,
                residentBytes: footprint
            )
        }

        let report = try SoakMemoryTrend.evaluate(samples: samples, policy: .standard)

        XCTAssertLessThan(
            abs(report.fittedGrowthBytes),
            Double(SoakGrowthPolicy.standard.slopeToleranceBytes)
        )
    }

    func testNFRSTAB005MemoryTrendInsufficientSamplesThrowsTypedError() {
        let samples = [makeSample(iteration: 0, megabytes: 200)]

        XCTAssertThrowsError(
            try SoakMemoryTrend.evaluate(samples: samples, policy: .standard)
        ) { error in
            guard case .insufficientSamples(let count, let required)? = error as? SoakError
            else {
                return XCTFail("expected insufficientSamples, got \(error)")
            }
            XCTAssertEqual(count, 1)
            XCTAssertEqual(required, SoakMemoryTrend.minimumSampleCount)
        }
    }

    func testNFRSTAB005MemorySamplerReportsNonZeroFootprint() throws {
        let sample = try SoakMemorySampler.sample(iteration: 0)

        XCTAssertGreaterThan(sample.physicalFootprintBytes, 0)
        XCTAssertGreaterThan(sample.residentBytes, 0)
    }

    // MARK: - CLI wiring

    func testNFRSTAB005SoakCommandShortRunStreamsProgressAndPasses() async throws {
        let output = SoakBufferedOutput()
        let errorOutput = SoakBufferedOutput()

        let exitCode = await AjarCommand.run(
            arguments: ["soak", "--iterations", "4", "--warmup-iterations", "1"],
            standardOutput: output,
            standardError: errorOutput
        )

        XCTAssertEqual(exitCode, 0, "soak failed: \(errorOutput.lines)")
        XCTAssertEqual(
            output.lines.filter { $0.hasPrefix("soak iteration") }.count,
            4,
            "each iteration must stream one progress line"
        )
        XCTAssertTrue(
            output.lines.contains { $0.hasPrefix("soak passed (NFR-STAB-005)") },
            "missing pass summary in \(output.lines)"
        )
    }

    func testSoakRequiresIterationsOrDurationAsUsageError() async {
        let errorOutput = SoakBufferedOutput()

        let exitCode = await AjarCommand.run(
            arguments: ["soak"],
            standardOutput: SoakBufferedOutput(),
            standardError: errorOutput
        )

        XCTAssertEqual(exitCode, 2)
        XCTAssertTrue(
            errorOutput.lines.contains { $0.contains("--iterations and/or --duration-seconds") }
        )
    }

    func testSoakRejectsUnknownOptionAsUsageError() async {
        let exitCode = await AjarCommand.run(
            arguments: ["soak", "--iterations", "1", "--frames", "9"],
            standardOutput: SoakBufferedOutput(),
            standardError: SoakBufferedOutput()
        )

        XCTAssertEqual(exitCode, 2)
    }

    func testSoakParsesHexadecimalSeed() throws {
        let options = try SoakOptions.parse(["--iterations", "2", "--seed", "0xAB12"])

        XCTAssertEqual(options.seed, 0xAB12)
        XCTAssertEqual(options.iterations, 2)
        XCTAssertEqual(options.warmupIterations, SoakOptions.defaultWarmupIterations)
        XCTAssertEqual(options.policy, .standard)
    }

    // MARK: - Helpers

    private func makeLinearSamples(
        count: Int,
        totalGrowthMegabytes: Double
    ) -> [SoakMemorySample] {
        let base = 200.0 * 1_024 * 1_024
        let perStep = totalGrowthMegabytes * 1_024 * 1_024 / Double(count - 1)
        return (0..<count).map { index in
            let footprint = UInt64(base + Double(index) * perStep)
            return SoakMemorySample(
                iteration: index,
                physicalFootprintBytes: footprint,
                residentBytes: footprint
            )
        }
    }

    private func makeSample(iteration: Int, megabytes: Int64) -> SoakMemorySample {
        let footprint = UInt64(megabytes) * 1_024 * 1_024
        return SoakMemorySample(
            iteration: iteration,
            physicalFootprintBytes: footprint,
            residentBytes: footprint
        )
    }
}

private final class SoakBufferedOutput: AjarTextOutput {
    private(set) var lines: [String] = []

    func writeLine(_ line: String) {
        lines.append(line)
    }
}
