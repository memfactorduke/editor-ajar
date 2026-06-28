// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal

/// Parsed options for `ajar bench`.
public struct BenchmarkOptions: Equatable, Sendable {
    /// Metric to run, or all report-only metrics.
    public let metric: BenchmarkMetricSelection

    /// Optional `.ajar` package. If nil, a synthetic fixture is generated.
    public let projectURL: URL?

    /// Creates benchmark options.
    public init(metric: BenchmarkMetricSelection, projectURL: URL?) {
        self.metric = metric
        self.projectURL = projectURL
    }

    static func parse(_ arguments: [String]) throws -> BenchmarkOptions {
        guard let rawMetric = arguments.first else {
            throw AjarCLIError.invalidUsage("bench requires a metric")
        }
        guard arguments.count <= 2 else {
            throw AjarCLIError.invalidUsage("bench accepts at most one project.ajar path")
        }

        return BenchmarkOptions(
            metric: try BenchmarkMetricSelection.parse(rawMetric),
            projectURL: arguments.dropFirst().first.map(URL.init(fileURLWithPath:))
        )
    }
}

/// Metric selector accepted by `ajar bench`.
public enum BenchmarkMetricSelection: Equatable, Sendable {
    /// Run every report-only metric.
    case all

    /// Run one metric.
    case metric(BenchmarkMetric)

    static func parse(_ rawValue: String) throws -> BenchmarkMetricSelection {
        if rawValue == "all" {
            return .all
        }
        if let metric = BenchmarkMetric(rawValue: rawValue) {
            return .metric(metric)
        }
        throw AjarCLIError.invalidUsage("unknown benchmark metric '\(rawValue)'")
    }
}

/// One benchmark metric emitted by the report-only harness.
public enum BenchmarkMetric: String, CaseIterable, Sendable {
    /// Build graph, decode source, execute render, and wait until the frame is present-ready.
    case singleFrameRenderSeekLatency = "single-frame-render-seek-latency"

    /// Load and decode the `.ajar` project package.
    case projectOpenDecodeLoad = "project-open-decode-load"

    /// In-process CLI startup proxy until app signposts are wired.
    case coldStartProxy = "cold-start-proxy"

    /// Render a transformed four-layer frame as a report-only proxy for timeline playback.
    case multiLayerTransformPlayback = "multi-layer-transform-playback"

    /// Render a 4K30 two-layer frame with chroma key and choke enabled.
    case twoLayerChromaKeyChoke4K30Playback = "two-layer-chroma-key-choke-4k30-playback"

    /// Compute FR-COL-003 scopes for one display-encoded frame.
    case scopeAnalyzerCompute = "scope-analyzer-compute"

    var requirementID: String {
        switch self {
        case .singleFrameRenderSeekLatency:
            "NFR-PERF-005"
        case .projectOpenDecodeLoad:
            "NFR-PERF-002"
        case .coldStartProxy:
            "NFR-PERF-001"
        case .multiLayerTransformPlayback:
            "NFR-PERF-003"
        case .twoLayerChromaKeyChoke4K30Playback:
            "NFR-PERF-004"
        case .scopeAnalyzerCompute:
            "FR-COL-003"
        }
    }
}

/// Structured JSON benchmark result.
public struct BenchmarkResult: Codable, Equatable, Sendable {
    /// Stable metric slug.
    public let metric: String

    /// Median measured value.
    public let value: Double

    /// Unit for `value`.
    public let unit: String

    /// SPEC requirement this metric covers.
    public let requirementID: String
}

/// Implements `ajar bench`.
public enum BenchmarkCommand {
    /// Runs the selected report-only benchmark metrics.
    public static func run(options: BenchmarkOptions) async throws -> [BenchmarkResult] {
        let fixture = try BenchmarkProjectFixture(projectURL: options.projectURL)
        defer {
            fixture.removeGeneratedFiles()
        }

        let metrics = options.metric.metrics
        var results: [BenchmarkResult] = []
        for metric in metrics {
            results.append(try await run(metric: metric, projectURL: fixture.projectURL))
        }
        return results
    }

    /// Emits the result list as JSON. One selected metric prints an object; `all` prints an array.
    public static func writeJSON(
        _ results: [BenchmarkResult],
        standardOutput: any AjarTextOutput
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        if results.count == 1, let result = results.first {
            data = try encoder.encode(result)
        } else {
            data = try encoder.encode(results)
        }

        guard let line = String(data: data, encoding: .utf8) else {
            throw AjarCLIError.benchmarkFailed("could not encode benchmark JSON as UTF-8")
        }
        standardOutput.writeLine(line)
    }

    private static func run(
        metric: BenchmarkMetric,
        projectURL: URL
    ) async throws -> BenchmarkResult {
        let value: Double
        switch metric {
        case .singleFrameRenderSeekLatency:
            value = try await measureSingleFrameRenderSeek(projectURL: projectURL)
        case .projectOpenDecodeLoad:
            value = try await measureProjectOpen(projectURL: projectURL)
        case .coldStartProxy:
            value = try await measureColdStartProxy()
        case .multiLayerTransformPlayback:
            value = try await measureMultiLayerTransformPlayback(projectURL: projectURL)
        case .twoLayerChromaKeyChoke4K30Playback:
            value = try await measureTwoLayerChromaKeyChoke4K30Playback()
        case .scopeAnalyzerCompute:
            value = try await measureScopeAnalyzerCompute()
        }

        return BenchmarkResult(
            metric: metric.rawValue,
            value: value,
            unit: "ms",
            requirementID: metric.requirementID
        )
    }

    private static func measureSingleFrameRenderSeek(projectURL: URL) async throws -> Double {
        let project = try ProjectPackageIO.loadProject(from: projectURL)
        guard let sequence = project.sequences.first else {
            throw AjarCLIError.missingSequence
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }

        let executor = try MetalRenderExecutor(device: device)
        let renderTime = try RationalTime.atFrame(0, frameRate: project.settings.frameRate)
        return try await medianMilliseconds {
            executor.removeAllCachedFrames()
            let graph = try buildRenderGraph(for: sequence, at: renderTime, in: project)
            let sourceProvider = try await PredecodedSourceTextureProvider(
                graph: graph,
                project: project,
                device: device
            )
            let frame = try executor.render(
                graph: graph,
                output: RenderOutputDescriptor(pixelDimensions: project.settings.resolution),
                sourceProvider: sourceProvider
            )
            try await frame.waitForCompletion()
        }
    }

    private static func measureProjectOpen(projectURL: URL) async throws -> Double {
        try await medianMilliseconds {
            let project = try ProjectPackageIO.loadProject(from: projectURL)
            _ = project.mediaPool.count + project.sequences.count
        }
    }

    private static func measureMultiLayerTransformPlayback(projectURL: URL) async throws -> Double {
        let project = try ProjectPackageIO.loadProject(from: projectURL)
        guard let sequence = multiLayerTransformSequence(in: project) else {
            throw AjarCLIError.missingSequence
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }

        let executor = try MetalRenderExecutor(device: device)
        let renderTime = try RationalTime.atFrame(30, frameRate: project.settings.frameRate)
        return try await medianMilliseconds {
            executor.removeAllCachedFrames()
            let graph = try buildRenderGraph(for: sequence, at: renderTime, in: project)
            let sourceProvider = try await PredecodedSourceTextureProvider(
                graph: graph,
                project: project,
                device: device
            )
            let frame = try executor.render(
                graph: graph,
                output: RenderOutputDescriptor(pixelDimensions: project.settings.resolution),
                sourceProvider: sourceProvider
            )
            try await frame.waitForCompletion()
        }
    }

    private static func measureTwoLayerChromaKeyChoke4K30Playback() async throws -> Double {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }

        let fixture = try BenchmarkChromaKeyChokeFixture(device: device)
        let executor = try MetalRenderExecutor(device: device)
        let renderTime = try RationalTime.atFrame(0, frameRate: fixture.project.settings.frameRate)

        return try await medianMilliseconds {
            executor.removeAllCachedFrames()
            let graph = try buildRenderGraph(
                for: fixture.sequence,
                at: renderTime,
                in: fixture.project
            )
            let frame = try executor.render(
                graph: graph,
                output: RenderOutputDescriptor(pixelDimensions: fixture.dimensions),
                sourceProvider: fixture.sourceProvider
            )
            try await frame.waitForCompletion()
        }
    }

    private static func measureScopeAnalyzerCompute() async throws -> Double {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }

        let fixture = try BenchmarkScopeAnalyzerFixture(device: device)
        let analyzer = try MetalScopeAnalyzer(device: device)

        return try await medianMilliseconds {
            let frame = try analyzer.analyze(displayEncodedTexture: fixture.texture)
            try await frame.waitForCompletion()
        }
    }

    private static func multiLayerTransformSequence(in project: Project) -> Sequence? {
        project.sequences.first { sequence in
            sequence.name == BenchmarkSyntheticProject.multiLayerSequenceName
        } ?? project.sequences.first
    }

    private static func measureColdStartProxy() async throws -> Double {
        if let executableURL = findAjarExecutable() {
            return try await medianMilliseconds {
                try runVersionProcess(executableURL: executableURL)
            }
        }

        return try await medianMilliseconds {
            let output = NullTextOutput()
            let errorOutput = NullTextOutput()
            let exitCode = await AjarCommand.run(
                arguments: ["version"],
                standardOutput: output,
                standardError: errorOutput
            )
            guard exitCode == 0 else {
                throw AjarCLIError.benchmarkFailed("version command proxy exited \(exitCode)")
            }
        }
    }

    private static func findAjarExecutable() -> URL? {
        let currentExecutable = CommandLine.arguments
            .first
            .map(URL.init(fileURLWithPath:))
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            currentExecutable,
            workingDirectory.appendingPathComponent(".build/debug/ajar"),
            workingDirectory.appendingPathComponent(".build/release/ajar")
        ].compactMap { $0 }

        return candidates.first { candidate in
            candidate.lastPathComponent == "ajar"
                && FileManager.default.isExecutableFile(atPath: candidate.path)
        }
    }

    private static func runVersionProcess(executableURL: URL) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["version"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()
        _ = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw AjarCLIError.benchmarkFailed(
                "version subprocess exited \(process.terminationStatus)"
            )
        }
    }

    private static func medianMilliseconds(
        warmupIterations: Int = 1,
        measuredIterations: Int = 3,
        operation: () async throws -> Void
    ) async throws -> Double {
        for _ in 0..<warmupIterations {
            try await operation()
        }

        var values: [Double] = []
        for _ in 0..<measuredIterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try await operation()
            let end = DispatchTime.now().uptimeNanoseconds
            values.append(Double(end - start) / 1_000_000.0)
        }

        let sortedValues = values.sorted()
        let median = sortedValues[sortedValues.count / 2]
        return (median * 1_000).rounded() / 1_000
    }
}

private extension BenchmarkMetricSelection {
    var metrics: [BenchmarkMetric] {
        switch self {
        case .all:
            BenchmarkMetric.allCases
        case .metric(let metric):
            [metric]
        }
    }
}

private final class NullTextOutput: AjarTextOutput {
    func writeLine(_ line: String) {}
}

private final class BenchmarkProjectFixture {
    let projectURL: URL
    private let generatedDirectory: URL?

    init(projectURL: URL?) throws {
        if let projectURL {
            self.projectURL = projectURL
            generatedDirectory = nil
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-benchmarks")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.projectURL = try BenchmarkSyntheticProject.write(to: directory)
        generatedDirectory = directory
    }

    func removeGeneratedFiles() {
        guard let generatedDirectory else {
            return
        }
        try? FileManager.default.removeItem(at: generatedDirectory)
    }
}
