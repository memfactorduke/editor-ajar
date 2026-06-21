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
                let options = try RenderFrameOptions.parse(Array(arguments.dropFirst()))
                _ = try await RenderFrameCommand.render(options: options)
                standardOutput.writeLine("wrote \(options.outputURL.path)")
                return 0
            case "golden":
                let options = try GoldenFrameOptions.parse(Array(arguments.dropFirst()))
                let summary = try await GoldenFrameHarness.run(
                    options: options,
                    standardOutput: standardOutput
                )
                if summary.failureCount == 0 {
                    standardOutput.writeLine("golden-frame passed: \(summary.passCount) passed")
                    return 0
                }
                standardError.writeLine(
                    "golden-frame failed: "
                        + "\(summary.failureCount) failed, \(summary.passCount) passed"
                )
                return 1
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

    private static let usage = """
        usage:
          ajar version
          ajar render --frame <value|value/timescale> <project.ajar> -o <out.png>
          ajar golden [Tests/Fixtures/golden | manifest.json]
        """
}
