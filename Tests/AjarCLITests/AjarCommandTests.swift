// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import XCTest

@testable import AjarCLI

final class AjarCommandTests: XCTestCase {
    func testRenderFrameWritesDeterministicPNGForSyntheticSingleClip() async throws {
        try requireMetal()
        let directory = try temporaryDirectory()
        let mediaURL = directory.appendingPathComponent("source.mov")
        let projectURL = directory.appendingPathComponent("project.ajar")
        let firstOutputURL = directory.appendingPathComponent("first.png")
        let secondOutputURL = directory.appendingPathComponent("second.png")
        let movieSpec = SyntheticMovieSpec(
            width: 16,
            height: 16,
            frameCount: 1,
            frameRate: 24,
            bgra: [0, 0, 255, 255]
        )
        try SyntheticMovieWriter.writeMovie(to: mediaURL, spec: movieSpec)
        try ProjectPackageIO.writeProject(
            makeProject(mediaURL: mediaURL, movieSpec: movieSpec),
            to: projectURL
        )

        let firstExit = await AjarCommand.run(
            arguments: [
                "render",
                "--frame",
                "0/24",
                projectURL.path,
                "-o",
                firstOutputURL.path
            ],
            standardOutput: BufferedTextOutput(),
            standardError: BufferedTextOutput()
        )
        let secondExit = await AjarCommand.run(
            arguments: [
                "render",
                "--frame",
                "0/24",
                projectURL.path,
                "-o",
                secondOutputURL.path
            ],
            standardOutput: BufferedTextOutput(),
            standardError: BufferedTextOutput()
        )

        XCTAssertEqual(firstExit, 0)
        XCTAssertEqual(secondExit, 0)
        let firstImage = try PNGCodec.read(from: firstOutputURL)
        let secondImage = try PNGCodec.read(from: secondOutputURL)
        XCTAssertEqual(firstImage, secondImage)
        XCTAssertEqual(firstImage.width, 16)
        XCTAssertEqual(firstImage.height, 16)
    }

    func testTESTING2ADR0011NFRQUAL001GoldenHarnessComparesStoredReferencePNG() async throws {
        try requireMetal()
        let output = BufferedTextOutput()
        let errorOutput = BufferedTextOutput()
        let exitCode = await AjarCommand.run(
            arguments: ["golden", fixtureGoldenDirectory().path],
            standardOutput: output,
            standardError: errorOutput
        )

        let diagnosticOutput = (output.lines + errorOutput.lines).joined(separator: "\n")
        XCTAssertEqual(exitCode, 0, diagnosticOutput)
        XCTAssertTrue(output.lines.contains { line in line.contains("PASS single-clip-blue") })
        XCTAssertTrue(output.lines.contains { line in line.contains("golden-frame passed") })
    }

    func testBenchmarkAllEmitsReportOnlyPerformanceJSON() async throws {
        try requireMetal()
        let output = BufferedTextOutput()
        let errorOutput = BufferedTextOutput()
        let exitCode = await AjarCommand.run(
            arguments: ["bench", "all"],
            standardOutput: output,
            standardError: errorOutput
        )

        let diagnosticOutput = (output.lines + errorOutput.lines).joined(separator: "\n")
        XCTAssertEqual(exitCode, 0, diagnosticOutput)
        XCTAssertTrue(errorOutput.lines.isEmpty, diagnosticOutput)
        let reportData = try XCTUnwrap(output.lines.joined(separator: "\n").data(using: .utf8))
        let results = try JSONDecoder().decode([BenchmarkReportRow].self, from: reportData)
        let expectedRequirementIDs = [
            "single-frame-render-seek-latency": "NFR-PERF-005",
            "project-open-decode-load": "NFR-PERF-002",
            "cold-start-proxy": "NFR-PERF-001",
            "multi-layer-transform-playback": "NFR-PERF-003",
            "two-layer-chroma-key-choke-4k30-playback": "NFR-PERF-004"
        ]

        XCTAssertEqual(Set(results.map(\.metric)), Set(expectedRequirementIDs.keys))
        for result in results {
            XCTAssertEqual(result.unit, "ms")
            XCTAssertGreaterThanOrEqual(result.value, 0)
            XCTAssertEqual(result.requirementID, expectedRequirementIDs[result.metric])
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-cli-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

private final class BufferedTextOutput: AjarTextOutput {
    private(set) var lines: [String] = []

    func writeLine(_ line: String) {
        lines.append(line)
    }
}

private struct BenchmarkReportRow: Decodable {
    let metric: String
    let value: Double
    let unit: String
    let requirementID: String
}

private func requireMetal() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
        throw XCTSkip("Metal device unavailable on this runner")
    }
}

private func fixtureGoldenDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("golden")
}

private func makeProject(mediaURL: URL, movieSpec: SyntheticMovieSpec) throws -> Project {
    let frameRate = try FrameRate(frames: Int64(movieSpec.frameRate))
    let duration = try frameRate.duration(ofFrames: Int64(movieSpec.frameCount))
    let mediaID = try uuid("00000000-0000-0000-0000-000000001018")
    let clipID = try uuid("00000000-0000-0000-0000-000000001118")
    let media = MediaRef(
        id: mediaID,
        sourceURL: mediaURL,
        contentHash: ContentHash.sha256(data: Data("cli-test".utf8)),
        metadata: MediaMetadata(
            codecID: "prores4444",
            pixelDimensions: PixelDimensions(width: movieSpec.width, height: movieSpec.height),
            frameRate: frameRate,
            duration: duration,
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
    let clip = Clip(
        id: clipID,
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: .zero, duration: duration),
        timelineRange: try TimeRange(start: .zero, duration: duration),
        kind: .video,
        name: "CLI Synthetic"
    )
    let sequence = Sequence(
        id: try uuid("00000000-0000-0000-0000-000000001218"),
        name: "CLI Render",
        videoTracks: [
            Track(
                id: try uuid("00000000-0000-0000-0000-000000001318"),
                kind: .video,
                items: [.clip(clip)]
            )
        ],
        audioTracks: [],
        markers: [],
        timebase: frameRate
    )

    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: frameRate,
            resolution: PixelDimensions(width: movieSpec.width, height: movieSpec.height),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [media],
        sequences: [sequence]
    )
}

private func uuid(_ value: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: value))
}
