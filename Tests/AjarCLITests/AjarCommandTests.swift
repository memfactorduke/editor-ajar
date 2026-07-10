// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
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

    func testRenderAudioWritesDeterministicWAVForSyntheticAudioClip() async throws {
        let directory = try temporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.wav")
        let projectURL = directory.appendingPathComponent("project.ajar")
        let outputURL = directory.appendingPathComponent("mix.wav")
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 1),
            frameCount: 4,
            samples: [0, 0.25, 0.5, 1]
        )
        try WAVCodec.write(source, to: sourceURL)
        try ProjectPackageIO.writeProject(
            makeAudioProject(mediaURL: sourceURL, source: source),
            to: projectURL
        )

        let standardOutput = BufferedTextOutput()
        let errorOutput = BufferedTextOutput()
        let exitCode = await AjarCommand.run(
            arguments: [
                "render-audio",
                "--duration",
                "1/1",
                projectURL.path,
                "-o",
                outputURL.path
            ],
            standardOutput: standardOutput,
            standardError: errorOutput
        )

        let diagnosticOutput = (standardOutput.lines + errorOutput.lines).joined(separator: "\n")
        XCTAssertEqual(exitCode, 0, diagnosticOutput)
        let rendered = try WAVCodec.readRenderedAudio(from: outputURL)
        XCTAssertEqual(rendered.format, AudioRenderFormat(sampleRate: 4, channelCount: 2))
        assertSamples(rendered.samples, equal: [0, 0, 0.25, 0.25, 0.5, 0.5, 1, 1])
    }

    func testTESTING2ADR0011GoldenAudioHarnessComparesStoredReferenceSamples() async throws {
        let firstOutput = BufferedTextOutput()
        let firstErrorOutput = BufferedTextOutput()
        let secondOutput = BufferedTextOutput()
        let secondErrorOutput = BufferedTextOutput()
        let firstExitCode = await AjarCommand.run(
            arguments: ["golden-audio", fixtureGoldenAudioDirectory().path],
            standardOutput: firstOutput,
            standardError: firstErrorOutput
        )
        let secondExitCode = await AjarCommand.run(
            arguments: ["golden-audio", fixtureGoldenAudioDirectory().path],
            standardOutput: secondOutput,
            standardError: secondErrorOutput
        )

        let diagnosticOutput =
            (firstOutput.lines + firstErrorOutput.lines
            + secondOutput.lines + secondErrorOutput.lines).joined(separator: "\n")
        XCTAssertEqual(firstExitCode, 0, diagnosticOutput)
        XCTAssertEqual(secondExitCode, 0, diagnosticOutput)
        XCTAssertEqual(firstOutput.lines, secondOutput.lines)
        XCTAssertEqual(firstErrorOutput.lines, secondErrorOutput.lines)

        XCTAssertTrue(
            firstOutput.lines.contains { line in
                line.contains("PASS ducking-sidechain")
            })
        XCTAssertTrue(
            firstOutput.lines.contains { line in
                line.contains("PASS ducking-ramp-envelope")
            })
        XCTAssertTrue(firstOutput.lines.contains { line in line.contains("PASS gain-pan-fade") })
        XCTAssertTrue(
            firstOutput.lines.contains { line in
                line.contains("PASS multi-track-summing")
            })
        XCTAssertTrue(
            firstOutput.lines.contains { line in
                line.contains("PASS solo-track-selection")
            })
        XCTAssertTrue(
            firstOutput.lines.contains { line in
                line.contains("PASS same-track-multiple-clips")
            })
        XCTAssertTrue(firstOutput.lines.contains { line in line.contains("golden-audio passed") })
    }

    func testGoldenAudioHarnessRecordsFormatMismatchAsFailureArtifact() async throws {
        let directory = try temporaryDirectory()
        let manifestDirectory = directory.appendingPathComponent("format-mismatch")
        let manifestURL = manifestDirectory.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(
            at: manifestDirectory,
            withIntermediateDirectories: true
        )
        try Data(formatMismatchGoldenAudioManifest().utf8).write(to: manifestURL)

        let output = BufferedTextOutput()
        let errorOutput = BufferedTextOutput()
        let exitCode = await AjarCommand.run(
            arguments: ["golden-audio", manifestURL.path],
            standardOutput: output,
            standardError: errorOutput
        )
        let actualURL =
            manifestDirectory
            .appendingPathComponent("_actual")
            .appendingPathComponent("format-mismatch.wav")

        let diagnosticOutput = (output.lines + errorOutput.lines).joined(separator: "\n")
        XCTAssertEqual(exitCode, 1, diagnosticOutput)
        XCTAssertTrue(output.lines.contains { line in line.contains("FAIL format-mismatch") })
        XCTAssertTrue(output.lines.contains { line in line.contains("formatMismatch") })
        XCTAssertTrue(errorOutput.lines.contains { line in line.contains("golden-audio failed") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: actualURL.path))
    }

    func testBenchmarkOptionsParseEnforceBudgetsFlag() throws {
        let defaultOptions = try BenchmarkOptions.parse(["all"])
        XCTAssertFalse(defaultOptions.enforceBudgets)
        XCTAssertEqual(defaultOptions.metric, .all)
        XCTAssertNil(defaultOptions.projectURL)

        let enforced = try BenchmarkOptions.parse([
            "all",
            "/tmp/fixture.ajar",
            "--enforce-budgets"
        ])
        XCTAssertTrue(enforced.enforceBudgets)
        XCTAssertEqual(enforced.projectURL?.path, "/tmp/fixture.ajar")

        let flagFirst = try BenchmarkOptions.parse([
            "--enforce-budgets",
            "effect-node-sharpen-1080p-fr-fx-002"
        ])
        XCTAssertTrue(flagFirst.enforceBudgets)
        XCTAssertEqual(
            flagFirst.metric,
            .metric(.effectNodeSharpen1080p)
        )
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
            "two-layer-chroma-key-choke-4k30-playback": "NFR-PERF-004",
            "scope-analyzer-compute": "FR-COL-003",
            "disk-cache-warm-start-playback": "FR-PLAY-005",
            "retimed-constant-2x-playback-fr-spd-005": "FR-SPD-005",
            "retimed-constant-half-speed-playback-fr-spd-005": "FR-SPD-005",
            "retimed-time-remap-ramp-playback-fr-spd-005": "FR-SPD-005",
            "retimed-reverse-playback-fr-spd-005": "FR-SPD-005",
            "retimed-freeze-frame-playback-fr-spd-005": "FR-SPD-005",
            "retimed-frame-blend-half-speed-playback-fr-spd-005": "FR-SPD-005",
            "retimed-nested-compound-playback-fr-spd-005": "FR-SPD-005",
            "rt-audio-plan-build-retimed-fr-spd-005": "FR-SPD-005",
            "rt-audio-plan-build-nested-compound-fr-aud-007": "FR-AUD-007",
            "rt-audio-plan-build-wide-timeline-fr-aud-007": "FR-AUD-007",
            "effect-node-gaussian-blur-1080p-fr-fx-002": "FR-FX-002",
            "effect-node-box-blur-1080p-fr-fx-002": "FR-FX-002",
            "effect-node-zoom-blur-1080p-fr-fx-002": "FR-FX-002",
            "effect-node-sharpen-1080p-fr-fx-002": "FR-FX-002",
            "effect-node-glow-1080p-fr-fx-002": "FR-FX-002",
            "effect-node-lut-gpu-fr-col-004": "FR-COL-004",
            "effect-node-vignette-1080p-fr-fx-002": "FR-FX-002",
            "effect-node-mirror-1080p-fr-fx-002": "FR-FX-002",
            "effect-node-mosaic-1080p-fr-fx-002": "FR-FX-002",
            "effect-node-color-adjust-1080p-fr-fx-002": "FR-FX-002",
            "effect-node-posterize-1080p-fr-fx-002": "FR-FX-002",
            "effect-node-invert-1080p-fr-fx-002": "FR-FX-002",
            "effect-node-curves-gpu-fr-col-002": "FR-COL-002",
            "transition-cross-dissolve-1080p-fr-fx-001": "FR-FX-001",
            "transition-dip-fade-1080p-fr-fx-001": "FR-FX-001",
            "transition-push-slide-1080p-fr-fx-001": "FR-FX-001",
            "transition-wipe-1080p-fr-fx-001": "FR-FX-001",
            "transition-zoom-1080p-fr-fx-001": "FR-FX-001"
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

private func fixtureGoldenAudioDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("golden-audio")
}

private func formatMismatchGoldenAudioManifest() -> String {
    """
    {
      "id": "format-mismatch",
      "sampleRate": 4,
      "channelCount": 2,
      "duration": "1",
      "tolerance": 0.00001,
      "sources": [
        {
          "sampleRate": 4,
          "channelCount": 1,
          "samples": [1.0, 1.0, 1.0, 1.0]
        }
      ],
      "clips": [
        {
          "sourceIndex": 0,
          "duration": "1"
        }
      ],
      "referenceSamples": [
        1.0, 1.0
      ]
    }
    """
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

private func makeAudioProject(mediaURL: URL, source: AudioSourceBuffer) throws -> Project {
    let frameRate = try FrameRate(frames: Int64(source.format.sampleRate))
    let duration = try RationalTime(
        value: Int64(source.frameCount),
        timescale: Int64(source.format.sampleRate)
    )
    let mediaID = try uuid("00000000-0000-0000-0000-000000001418")
    let clip = Clip(
        id: try uuid("00000000-0000-0000-0000-000000001518"),
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: .zero, duration: duration),
        timelineRange: try TimeRange(start: .zero, duration: duration),
        kind: .audio,
        name: "CLI Audio Synthetic"
    )

    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: frameRate,
            resolution: PixelDimensions(width: 16, height: 16),
            colorSpace: .rec709,
            audioSampleRate: source.format.sampleRate
        ),
        mediaPool: [
            MediaRef(
                id: mediaID,
                sourceURL: mediaURL,
                contentHash: ContentHash.sha256(data: Data("cli-audio-test".utf8)),
                metadata: MediaMetadata(
                    codecID: "pcm_f32le",
                    pixelDimensions: nil,
                    frameRate: nil,
                    duration: duration,
                    colorSpace: .unspecified,
                    audioChannelLayout: AudioChannelLayout(
                        channelCount: source.format.channelCount
                    ),
                    isVariableFrameRate: false,
                    conformedFrameRate: nil
                )
            )
        ],
        sequences: [
            Sequence(
                id: try uuid("00000000-0000-0000-0000-000000001618"),
                name: "CLI Audio Render",
                videoTracks: [],
                audioTracks: [
                    Track(
                        id: try uuid("00000000-0000-0000-0000-000000001718"),
                        kind: .audio,
                        items: [.clip(clip)]
                    )
                ],
                markers: [],
                timebase: frameRate
            )
        ]
    )
}

private func assertSamples(
    _ actual: [Float],
    equal expected: [Float],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for index in actual.indices {
        XCTAssertEqual(actual[index], expected[index], accuracy: 0.00001, file: file, line: line)
    }
}

private func uuid(_ value: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: value))
}
