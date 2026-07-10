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

    /// When true, exit nonzero if any result with a budget has `withinBudget == false`.
    /// Default off so CI stays report-only until the reference runner is gated (ADR-0016 §4).
    public let enforceBudgets: Bool

    /// Creates benchmark options.
    public init(
        metric: BenchmarkMetricSelection,
        projectURL: URL?,
        enforceBudgets: Bool = false
    ) {
        self.metric = metric
        self.projectURL = projectURL
        self.enforceBudgets = enforceBudgets
    }

    static func parse(_ arguments: [String]) throws -> BenchmarkOptions {
        var metricRaw: String?
        var projectPath: String?
        var enforceBudgets = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--enforce-budgets" {
                enforceBudgets = true
                index += 1
                continue
            }
            if argument.hasPrefix("-") {
                throw AjarCLIError.invalidUsage("unknown bench option '\(argument)'")
            }
            if metricRaw == nil {
                metricRaw = argument
            } else if projectPath == nil {
                projectPath = argument
            } else {
                throw AjarCLIError.invalidUsage("bench accepts at most one project.ajar path")
            }
            index += 1
        }

        guard let rawMetric = metricRaw else {
            throw AjarCLIError.invalidUsage("bench requires a metric")
        }

        return BenchmarkOptions(
            metric: try BenchmarkMetricSelection.parse(rawMetric),
            projectURL: projectPath.map(URL.init(fileURLWithPath:)),
            enforceBudgets: enforceBudgets
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

/// Implements `ajar bench`.
public enum BenchmarkCommand {
    /// Runs the selected report-only benchmark metrics.
    public static func run(options: BenchmarkOptions) async throws -> [BenchmarkResult] {
        let metrics = options.metric.metrics
        // FR-FX-002 per-node metrics synthesize their own 1080p textures and never need the
        // shared synthetic `.ajar` package (avoids AVFoundation pixel-buffer setup for pure GPU
        // node timing).
        let needsProjectFixture = metrics.contains { metric in
            !metric.isSelfContainedEffectNodeMetric
        }
        let fixture =
            needsProjectFixture
            ? try BenchmarkProjectFixture(projectURL: options.projectURL)
            : nil
        defer {
            fixture?.removeGeneratedFiles()
        }

        var results: [BenchmarkResult] = []
        for metric in metrics {
            // Self-contained effect-node metrics ignore the project URL; pass a dummy path.
            let projectURL =
                fixture?.projectURL
                ?? options.projectURL
                ?? URL(fileURLWithPath: "/dev/null")
            results.append(try await run(metric: metric, projectURL: projectURL))
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
        let value = try await measureValue(metric: metric, projectURL: projectURL)
        let budget = metric.budget
        return BenchmarkResult(
            metric: metric.rawValue,
            value: value,
            unit: "ms",
            requirementID: metric.requirementID,
            budgetMilliseconds: budget?.targetMilliseconds,
            noiseBandPercent: budget?.noiseBandPercent,
            withinBudget: budget.map { value <= $0.allowedMilliseconds }
        )
    }

    private static func measureValue(
        metric: BenchmarkMetric,
        projectURL: URL
    ) async throws -> Double {
        switch metric {
        case .singleFrameRenderSeekLatency:
            try await measureSingleFrameRenderSeek(projectURL: projectURL)
        case .projectOpenDecodeLoad:
            try await measureProjectOpen(projectURL: projectURL)
        case .coldStartProxy:
            try await measureColdStartProxy()
        case .multiLayerTransformPlayback:
            try await measureMultiLayerTransformPlayback(projectURL: projectURL)
        case .twoLayerChromaKeyChoke4K30Playback:
            try await measureTwoLayerChromaKeyChoke4K30Playback()
        case .scopeAnalyzerCompute:
            try await measureScopeAnalyzerCompute()
        case .diskCacheWarmStartPlayback:
            try await measureDiskCacheWarmStartPlayback(projectURL: projectURL)
        case .effectNodeGaussianBlur1080p, .effectNodeBoxBlur1080p,
            .effectNodeZoomBlur1080p, .effectNodeSharpen1080p, .effectNodeGlow1080p,
            .effectNodeVignette1080p, .effectNodeMirror1080p, .effectNodeMosaic1080p,
            .effectNodeColorAdjust1080p, .effectNodePosterize1080p, .effectNodeInvert1080p,
            .effectNodeCurvesGPU:
            try await measureEffectNodeMetric(metric)
        case .effectNodeLUTGPU:
            try await BenchmarkLUTMeasurement.measureEffectNodeLUTGPU()
        case .transitionCrossDissolve1080p, .transitionDipFade1080p,
            .transitionPushSlide1080p, .transitionWipe1080p, .transitionZoom1080p:
            try await BenchmarkTransitionFixture.measure(metric: metric)
        default:
            try await measureRetimeMetric(metric)
        }
    }

    private static func measureEffectNodeMetric(_ metric: BenchmarkMetric) async throws -> Double {
        try await BenchmarkEffectNodeFixture.measure(metric: metric)
    }

    private static func measureSingleFrameRenderSeek(projectURL: URL) async throws -> Double {
        // Bench reads only — higher-minor (read-only) packages are allowed.
        let project = try ProjectPackageIO.loadProject(from: projectURL).project
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
            let project = try ProjectPackageIO.loadProject(from: projectURL).project
            _ = project.mediaPool.count + project.sequences.count
        }
    }

    private static func measureMultiLayerTransformPlayback(projectURL: URL) async throws -> Double {
        // Bench reads only — higher-minor (read-only) packages are allowed.
        let project = try ProjectPackageIO.loadProject(from: projectURL).project
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

    private static func measureDiskCacheWarmStartPlayback(projectURL: URL) async throws -> Double {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }

        let fixture = try await BenchmarkDiskCacheFixture(projectURL: projectURL, device: device)
        defer {
            fixture.removeGeneratedFiles()
        }

        // Each iteration simulates a process restart: a fresh executor with an empty RAM tier
        // warms itself from the persisted disk entry and serves the frame without decoding or
        // rendering (FR-PLAY-005). The source provider throws to prove no source is touched.
        return try await medianMilliseconds {
            let diskCache = try MetalDiskFrameCache(
                device: device,
                directoryURL: fixture.cacheDirectoryURL
            )
            let executor = try MetalRenderExecutor(device: device, diskCache: diskCache)
            let graph = try buildRenderGraph(
                for: fixture.sequence,
                at: fixture.renderTime,
                in: fixture.project
            )
            guard let contentHash = graph.outputNode?.contentHash else {
                throw AjarCLIError.benchmarkFailed("benchmark graph has no output node")
            }
            executor.prefetchCachedFrame(contentHash: contentHash, output: fixture.output)
            diskCache.waitUntilIdle()
            let frame = try executor.render(
                graph: graph,
                output: fixture.output,
                sourceProvider: ClosureRenderSourceTextureProvider { _ in
                    throw AjarCLIError.benchmarkFailed("warm disk start must not decode sources")
                }
            )
            guard frame.cacheHit else {
                throw AjarCLIError.benchmarkFailed("warm disk start did not hit the frame cache")
            }
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

    static func medianMilliseconds(
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
