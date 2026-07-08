// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import Foundation

/// Parsed options for `ajar soak`.
struct SoakOptions: Equatable {
    /// Fixed default seed so unattended runs are reproducible without flags.
    static let defaultSeed: UInt64 = 0xA1A9_0169

    /// Default number of warmup iterations excluded from the trend (caches fill, Metal and
    /// AVFoundation pools reach steady state).
    static let defaultWarmupIterations = 3

    /// Maximum iteration count, if limited.
    let iterations: Int?

    /// Maximum wall-clock duration in seconds, if limited.
    let durationSeconds: Double?

    /// Seed for the deterministic scripted loop.
    let seed: UInt64

    /// Iterations excluded from the memory trend while caches warm up.
    let warmupIterations: Int

    /// Growth thresholds applied to post-warmup samples.
    let policy: SoakGrowthPolicy

    static func parse(_ arguments: [String]) throws -> SoakOptions {
        var parser = SoakOptionParser()
        try parser.consume(arguments)
        return try parser.options()
    }
}

/// Final result of a passing soak run.
struct SoakRunSummary {
    /// Total iterations executed, including warmup.
    let iterationCount: Int

    /// Passing post-warmup memory trend.
    let report: SoakMemoryReport

    /// Whether the video render cycle ran (a Metal device was available).
    let videoCycleRan: Bool
}

/// Implements `ajar soak`: the NFR-STAB-005 leak/allocations soak harness.
///
/// Each iteration runs the deterministic scripted loop — edits with undo/redo through
/// `EditHistory`, render-graph builds, offline audio mixes (compound audio included), realtime
/// plan publish/consume handoff cycles, and, when a GPU is present, offline video renders with
/// disk-cache persist/lookup/quarantine/reset churn — inside autoreleasepool boundaries, then
/// samples process memory via mach `task_info`. After the documented warmup the post-warmup
/// footprint trend must stay inside the growth band and must not rise monotonically.
enum SoakCommand {
    /// Runs the soak loop and evaluates the memory trend, printing one progress line per
    /// iteration so long runs stream observable output.
    static func run(
        options: SoakOptions,
        standardOutput: any AjarTextOutput
    ) async throws -> SoakRunSummary {
        let workspace = try SoakWorkspace()
        defer {
            workspace.removeGeneratedFiles()
        }

        let environment = try SoakEnvironment(options: options, workspace: workspace)
        standardOutput.writeLine(environment.header(options: options))

        var rng = SoakDeterministicRandom(seed: options.seed)
        var samples: [SoakMemorySample] = []
        let startedAt = DispatchTime.now()
        var iteration = 0
        while !shouldStop(options: options, iteration: iteration, startedAt: startedAt) {
            let stats = try await runIteration(
                iteration: iteration,
                environment: environment,
                rng: &rng
            )
            let sample = try SoakMemorySampler.sample(iteration: iteration)
            samples.append(sample)
            standardOutput.writeLine(
                progressLine(
                    iteration: iteration,
                    options: options,
                    stats: stats,
                    sample: sample,
                    startedAt: startedAt
                )
            )
            iteration += 1
        }

        let postWarmup = samples.filter { $0.iteration >= options.warmupIterations }
        let report = try SoakMemoryTrend.evaluate(samples: postWarmup, policy: options.policy)
        standardOutput.writeLine(passLine(iteration: iteration, report: report))
        return SoakRunSummary(
            iterationCount: iteration,
            report: report,
            videoCycleRan: environment.videoRenderer != nil
        )
    }

    private static func runIteration(
        iteration: Int,
        environment: SoakEnvironment,
        rng: inout SoakDeterministicRandom
    ) async throws -> SoakIterationStats {
        let fixture = environment.fixtures[iteration % environment.fixtures.count]
        let scripted = try autoreleasepool {
            try SoakEditScript.run(fixture: fixture, using: &rng)
        }
        guard
            let sequence = scripted.project.sequences
                .first(where: { $0.id == fixture.sequenceID })
        else {
            throw AjarCLIError.missingSequence
        }

        let graphCount = try autoreleasepool {
            try buildStandaloneGraphs(project: scripted.project, sequence: sequence)
        }
        let audioFrameCount = try autoreleasepool {
            try environment.audioCycle.runCycle(project: scripted.project, sequence: sequence)
        }
        var videoStats: SoakVideoCycleStats?
        if let videoRenderer = environment.videoRenderer {
            videoStats = try await videoRenderer.runCycle(
                project: scripted.project,
                sequence: sequence,
                iteration: iteration
            )
        }
        return SoakIterationStats(
            variant: iteration % environment.fixtures.count,
            commandCount: scripted.commandCount,
            graphCount: graphCount,
            audioFrameCount: audioFrameCount,
            videoStats: videoStats
        )
    }

    /// Builds render graphs on the pure `AjarCore` path even when no GPU is available.
    private static func buildStandaloneGraphs(
        project: Project,
        sequence: Sequence
    ) throws -> Int {
        var graphCount = 0
        for frameIndex in [Int64(1), Int64(7), Int64(13)] {
            let renderTime = try RationalTime.atFrame(
                frameIndex,
                frameRate: project.settings.frameRate
            )
            let graph = try buildRenderGraph(for: sequence, at: renderTime, in: project)
            graphCount += graph.nodes.isEmpty ? 0 : 1
        }
        return graphCount
    }

    private static func shouldStop(
        options: SoakOptions,
        iteration: Int,
        startedAt: DispatchTime
    ) -> Bool {
        if let iterations = options.iterations, iteration >= iterations {
            return true
        }
        if let durationSeconds = options.durationSeconds {
            // A duration-limited run always finishes enough iterations to evaluate the trend.
            let minimumIterations = options.warmupIterations + SoakMemoryTrend.minimumSampleCount
            return elapsedSeconds(since: startedAt) >= durationSeconds
                && iteration >= minimumIterations
        }
        return false
    }

    private static func progressLine(
        iteration: Int,
        options: SoakOptions,
        stats: SoakIterationStats,
        sample: SoakMemorySample,
        startedAt: DispatchTime
    ) -> String {
        var fields = [
            "soak iteration \(iteration)",
            "variant=\(stats.variant)",
            "commands=\(stats.commandCount)",
            "graphs=\(stats.graphCount)",
            "audio-frames=\(stats.audioFrameCount)"
        ]
        if let videoStats = stats.videoStats {
            fields.append("video-frames=\(videoStats.renderedFrameCount)")
            fields.append("disk-entries=\(videoStats.diskEntryCount)")
            fields.append("quarantined=\(videoStats.quarantinedEntryCount)")
            fields.append("disk-populated=\(videoStats.diskPopulatedFrameCount)")
        } else {
            fields.append("video=skipped(no-gpu)")
        }
        fields.append(
            "footprint=\(SoakMemoryReport.megabytes(sample.physicalFootprintBytes))MiB"
        )
        fields.append("resident=\(SoakMemoryReport.megabytes(sample.residentBytes))MiB")
        fields.append(String(format: "elapsed=%.1fs", elapsedSeconds(since: startedAt)))
        if iteration < options.warmupIterations {
            fields.append("(warmup)")
        }
        return fields.joined(separator: " ")
    }

    private static func passLine(iteration: Int, report: SoakMemoryReport) -> String {
        let growth = report.peakBytes > report.baselineBytes
            ? report.peakBytes - report.baselineBytes
            : 0
        return "soak passed (NFR-STAB-005): \(iteration) iterations, "
            + "baseline \(SoakMemoryReport.megabytes(report.baselineBytes)) MiB, "
            + "peak \(SoakMemoryReport.megabytes(report.peakBytes)) MiB, "
            + "growth \(SoakMemoryReport.megabytes(growth)) MiB within "
            + "\(SoakMemoryReport.megabytes(report.policy.growthBandBytes)) MiB band"
    }

    private static func elapsedSeconds(since startedAt: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds)
            / 1_000_000_000.0
    }
}

private struct SoakIterationStats {
    let variant: Int
    let commandCount: Int
    let graphCount: Int
    let audioFrameCount: Int
    let videoStats: SoakVideoCycleStats?
}

/// Run-long soak state: the project variants, audio cycle, and optional video renderer.
private struct SoakEnvironment {
    let fixtures: [SoakProjectFixture]
    let audioCycle: SoakAudioCycle
    let videoRenderer: SoakVideoRenderer?

    init(options: SoakOptions, workspace: SoakWorkspace) throws {
        try SoakSyntheticProject.writeSourceMovie(to: workspace.movieURL)
        fixtures = try (0..<SoakSyntheticProject.variantCount).map { variant in
            try SoakSyntheticProject.makeFixture(
                variant: variant,
                movieURL: workspace.movieURL
            )
        }

        let audioSource = try SoakSyntheticProject.makeAudioSource()
        var audioSources: [UUID: AudioSourceBuffer] = [:]
        for fixture in fixtures {
            audioSources[fixture.audioMediaID] = audioSource
        }
        audioCycle = try SoakAudioCycle(audioSources: audioSources)
        videoRenderer = SoakVideoRenderer(cacheDirectoryURL: workspace.cacheDirectoryURL)
    }

    func header(options: SoakOptions) -> String {
        var fields = [
            "soak start (NFR-STAB-005):",
            String(format: "seed=0x%llX", options.seed),
            "warmup-iterations=\(options.warmupIterations)",
            "growth-band=\(SoakMemoryReport.megabytes(options.policy.growthBandBytes))MiB",
            "variants=\(fixtures.count)"
        ]
        if let iterations = options.iterations {
            fields.append("iterations=\(iterations)")
        }
        if let durationSeconds = options.durationSeconds {
            fields.append(String(format: "duration-seconds=%.0f", durationSeconds))
        }
        fields.append(videoRenderer == nil ? "video=disabled(no-gpu)" : "video=enabled")
        return fields.joined(separator: " ")
    }
}

/// Temporary on-disk workspace for the shared synthetic movie and the disk-cache directory.
private struct SoakWorkspace {
    let rootURL: URL
    let movieURL: URL
    let cacheDirectoryURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-soak")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        movieURL = rootURL.appendingPathComponent("soak-source.mov")
        cacheDirectoryURL = rootURL.appendingPathComponent("frame-cache")
    }

    func removeGeneratedFiles() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct SoakOptionParser {
    private var iterations: Int?
    private var durationSeconds: Double?
    private var seed = SoakOptions.defaultSeed
    private var warmupIterations = SoakOptions.defaultWarmupIterations
    private var growthBandBytes = SoakGrowthPolicy.standard.growthBandBytes

    mutating func consume(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let value = try nextValue(after: argument, in: arguments, index: &index)
            switch argument {
            case "--iterations":
                iterations = try parsePositiveInt(value, flag: argument)
            case "--duration-seconds":
                durationSeconds = try parsePositiveDouble(value, flag: argument)
            case "--seed":
                seed = try parseSeed(value)
            case "--warmup-iterations":
                warmupIterations = try parseNonNegativeInt(value, flag: argument)
            case "--growth-band-mb":
                let megabytes = try parsePositiveInt(value, flag: argument)
                growthBandBytes = UInt64(megabytes) * 1_024 * 1_024
            default:
                throw AjarCLIError.invalidUsage("unknown soak option '\(argument)'")
            }
            index += 1
        }
    }

    func options() throws -> SoakOptions {
        guard iterations != nil || durationSeconds != nil else {
            throw AjarCLIError.invalidUsage(
                "soak requires --iterations and/or --duration-seconds"
            )
        }
        return SoakOptions(
            iterations: iterations,
            durationSeconds: durationSeconds,
            seed: seed,
            warmupIterations: warmupIterations,
            policy: SoakGrowthPolicy(
                growthBandBytes: growthBandBytes,
                monotonicToleranceBytes: SoakGrowthPolicy.standard.monotonicToleranceBytes,
                slopeToleranceBytes: SoakGrowthPolicy.standard.slopeToleranceBytes
            )
        )
    }

    private func nextValue(
        after argument: String,
        in arguments: [String],
        index: inout Int
    ) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw AjarCLIError.invalidUsage("\(argument) requires a value")
        }
        return arguments[index]
    }

    private func parsePositiveInt(_ value: String, flag: String) throws -> Int {
        guard let parsed = Int(value), parsed > 0 else {
            throw AjarCLIError.invalidUsage("\(flag) must be a positive integer")
        }
        return parsed
    }

    private func parseNonNegativeInt(_ value: String, flag: String) throws -> Int {
        guard let parsed = Int(value), parsed >= 0 else {
            throw AjarCLIError.invalidUsage("\(flag) must be a non-negative integer")
        }
        return parsed
    }

    private func parsePositiveDouble(_ value: String, flag: String) throws -> Double {
        guard let parsed = Double(value), parsed > 0 else {
            throw AjarCLIError.invalidUsage("\(flag) must be a positive number")
        }
        return parsed
    }

    private func parseSeed(_ value: String) throws -> UInt64 {
        let parsed: UInt64?
        if value.lowercased().hasPrefix("0x") {
            parsed = UInt64(value.dropFirst(2), radix: 16)
        } else {
            parsed = UInt64(value)
        }
        guard let parsed else {
            throw AjarCLIError.invalidUsage("--seed must be a decimal or 0x-prefixed integer")
        }
        return parsed
    }
}
