// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal
import XCTest

@testable import AjarCLI

final class GoldenExportCommandTests: XCTestCase {
    func testFREXP007GoldenExportHarnessRunsSuite() async throws {
        try requireMetal()
        let output = BufferedGoldenExportOutput()
        let errorOutput = BufferedGoldenExportOutput()
        let exitCode = await AjarCommand.run(
            arguments: ["golden-export", fixtureGoldenExportDirectory().path],
            standardOutput: output,
            standardError: errorOutput
        )

        let diagnostic = (output.lines + errorOutput.lines).joined(separator: "\n")
        // Capability-gated H.264/HEVC skips still leave ProRes + still PNG as hard passes.
        XCTAssertEqual(exitCode, 0, diagnostic)
        XCTAssertTrue(
            output.lines.contains { $0.contains("PASS export-prores422-title") }
                || output.lines.contains { $0.contains("SKIP export-prores422-title") },
            diagnostic
        )
        // ProRes must not capability-skip for hardware encoder (it is not VT-required).
        XCTAssertFalse(
            output.lines.contains {
                $0.contains("SKIP export-prores422-title") && $0.contains("hardware encoder")
            },
            diagnostic
        )
        XCTAssertTrue(
            output.lines.contains { $0.contains("PASS export-still-png") },
            diagnostic
        )
        XCTAssertTrue(
            output.lines.contains { $0.contains("PASS export-animated-gif-title") },
            diagnostic
        )
        XCTAssertFalse(
            output.lines.contains { $0.contains("SKIP export-animated-gif-title") },
            "GIF uses ImageIO and must be a hard pass, not a hardware-encoder skip"
        )
        XCTAssertTrue(
            output.lines.contains { $0.contains("PASS export-h264-title") }
                || output.lines.contains { $0.contains("SKIP export-h264-title") },
            diagnostic
        )
        XCTAssertTrue(
            output.lines.contains { $0.contains("PASS export-hevc-title") }
                || output.lines.contains { $0.contains("SKIP export-hevc-title") },
            diagnostic
        )
        XCTAssertTrue(
            output.lines.contains { $0.contains("golden-export passed") },
            diagnostic
        )
    }

    func testFREXP007GoldenExportOptionsDefaultSuitePath() throws {
        let options = try GoldenExportOptions.parse([])
        XCTAssertTrue(options.suiteURL.path.hasSuffix("Tests/Fixtures/golden-export"))
    }

    func testFREXP007GoldenExportRejectsExtraArguments() {
        XCTAssertThrowsError(try GoldenExportOptions.parse(["a", "b"])) { error in
            guard let cli = error as? AjarCLIError else {
                return XCTFail("expected AjarCLIError")
            }
            XCTAssertTrue(cli.isUsageError)
        }
    }

    /// Theater gate: passCount==0 && failureCount==0 must exit nonzero (all-skip / empty).
    func testFREXP007GoldenExportZeroVerifiedWorkExitsNonzero() {
        let output = BufferedGoldenExportOutput()
        let errorOutput = BufferedGoldenExportOutput()
        let exitCode = AjarCommand.goldenExitCode(
            label: "golden-export",
            passCount: 0,
            failureCount: 0,
            standardOutput: output,
            standardError: errorOutput
        )
        XCTAssertEqual(exitCode, 1)
        XCTAssertTrue(
            errorOutput.lines.contains { $0.contains("zero verified work") },
            errorOutput.lines.joined(separator: "\n")
        )
    }

    private func requireMetal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on this runner")
        }
    }

    private func fixtureGoldenExportDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("golden-export")
    }
}

private final class BufferedGoldenExportOutput: AjarTextOutput {
    private(set) var lines: [String] = []

    func writeLine(_ line: String) {
        lines.append(line)
    }
}
