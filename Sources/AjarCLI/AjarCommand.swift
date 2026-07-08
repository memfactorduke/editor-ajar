// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Text output sink used by the CLI and tests.
public protocol AjarTextOutput {
    /// Writes one line of text.
    func writeLine(_ line: String)
}

/// File-handle backed output for the executable.
public struct FileHandleTextOutput: AjarTextOutput {
    private let fileHandle: FileHandle

    /// Creates an output sink for `fileHandle`.
    public init(_ fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    /// Writes one UTF-8 line.
    public func writeLine(_ line: String) {
        let data = Data("\(line)\n".utf8)
        fileHandle.write(data)
    }
}

/// Entrypoint for the `ajar` headless CLI.
public enum AjarCommand {
    /// Runs a command and returns a process exit code.
    public static func run(
        arguments: [String],
        standardOutput: any AjarTextOutput = FileHandleTextOutput(.standardOutput),
        standardError: any AjarTextOutput = FileHandleTextOutput(.standardError)
    ) async -> Int32 {
        guard let command = arguments.first else {
            standardError.writeLine(usage)
            return 2
        }

        do {
            switch command {
            case "version":
                standardOutput.writeLine("ajar 0.1.0")
                return 0
            case "render":
                return try await runRender(arguments: arguments, standardOutput: standardOutput)
            case "render-audio":
                return try runRenderAudio(arguments: arguments, standardOutput: standardOutput)
            case "golden":
                return try await runGoldenFrame(
                    arguments: arguments,
                    standardOutput: standardOutput,
                    standardError: standardError
                )
            case "golden-audio":
                return try await runGoldenAudio(
                    arguments: arguments,
                    standardOutput: standardOutput,
                    standardError: standardError
                )
            case "bench":
                return try await runBench(arguments: arguments, standardOutput: standardOutput)
            case "soak":
                return try await runSoak(arguments: arguments, standardOutput: standardOutput)
            default:
                standardError.writeLine("error: unknown command '\(command)'")
                standardError.writeLine(usage)
                return 2
            }
        } catch let error as AjarCLIError {
            standardError.writeLine("error: \(error.description)")
            return error.isUsageError ? 2 : 1
        } catch {
            standardError.writeLine("error: \(String(describing: error))")
            return 1
        }
    }

    private static func runRender(
        arguments: [String],
        standardOutput: any AjarTextOutput
    ) async throws -> Int32 {
        let options = try RenderFrameOptions.parse(Array(arguments.dropFirst()))
        _ = try await RenderFrameCommand.render(options: options)
        standardOutput.writeLine("wrote \(options.outputURL.path)")
        return 0
    }

    private static func runRenderAudio(
        arguments: [String],
        standardOutput: any AjarTextOutput
    ) throws -> Int32 {
        let options = try RenderAudioOptions.parse(Array(arguments.dropFirst()))
        _ = try RenderAudioCommand.render(options: options)
        standardOutput.writeLine("wrote \(options.outputURL.path)")
        return 0
    }

    private static func runGoldenFrame(
        arguments: [String],
        standardOutput: any AjarTextOutput,
        standardError: any AjarTextOutput
    ) async throws -> Int32 {
        let options = try GoldenFrameOptions.parse(Array(arguments.dropFirst()))
        let summary = try await GoldenFrameHarness.run(
            options: options,
            standardOutput: standardOutput
        )
        return goldenExitCode(
            label: "golden-frame",
            passCount: summary.passCount,
            failureCount: summary.failureCount,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }

    private static func runGoldenAudio(
        arguments: [String],
        standardOutput: any AjarTextOutput,
        standardError: any AjarTextOutput
    ) async throws -> Int32 {
        let options = try GoldenAudioOptions.parse(Array(arguments.dropFirst()))
        let summary = try await GoldenAudioHarness.run(
            options: options,
            standardOutput: standardOutput
        )
        return goldenExitCode(
            label: "golden-audio",
            passCount: summary.passCount,
            failureCount: summary.failureCount,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }

    private static func runBench(
        arguments: [String],
        standardOutput: any AjarTextOutput
    ) async throws -> Int32 {
        let options = try BenchmarkOptions.parse(Array(arguments.dropFirst()))
        let results = try await BenchmarkCommand.run(options: options)
        try BenchmarkCommand.writeJSON(results, standardOutput: standardOutput)
        return 0
    }

    private static func runSoak(
        arguments: [String],
        standardOutput: any AjarTextOutput
    ) async throws -> Int32 {
        let options = try SoakOptions.parse(Array(arguments.dropFirst()))
        _ = try await SoakCommand.run(options: options, standardOutput: standardOutput)
        return 0
    }

    private static func goldenExitCode(
        label: String,
        passCount: Int,
        failureCount: Int,
        standardOutput: any AjarTextOutput,
        standardError: any AjarTextOutput
    ) -> Int32 {
        if failureCount == 0 {
            standardOutput.writeLine("\(label) passed: \(passCount) passed")
            return 0
        }
        standardError.writeLine(
            "\(label) failed: \(failureCount) failed, \(passCount) passed"
        )
        return 1
    }

    private static let usage = """
        usage:
          ajar version
          ajar render --frame <value|value/timescale> <project.ajar> -o <out.png>
          ajar render-audio [--start <value|value/timescale>]
              --duration <value|value/timescale> <project.ajar> -o <out.wav>
          ajar golden [Tests/Fixtures/golden | manifest.json]
          ajar golden-audio [Tests/Fixtures/golden-audio | manifest.json]
          ajar bench <all|metric> [project.ajar]
          ajar soak [--iterations <n>] [--duration-seconds <s>] [--seed <n|0xN>]
              [--warmup-iterations <n>] [--growth-band-mb <MiB>]
        """
}
