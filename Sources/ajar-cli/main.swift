// SPDX-License-Identifier: GPL-3.0-or-later
//
// ============================================================================================
//  ajar — headless CLI: render / inspect / benchmark / golden-frame harness.
// ============================================================================================
//
//  Purpose (see docs/TESTING.md and ADR-0011/ADR-0014):
//    The `ajar` tool drives the engine without a GUI so the autonomous loop can verify pixels
//    (golden-frame), audio, and performance benchmarks deterministically. Planned subcommands:
//      ajar version
//      ajar inspect <project.ajar>
//      ajar render  --frame <t> <project.ajar> -o <png>
//      ajar bench   <project.ajar> <metric>
//      ajar golden  <suite>
//
//  Links the testable AjarCLI implementation for headless engine workflows.
//
//  The executable stays thin; the implementation lives in the testable AjarCLI target.

import AjarCLI
import Darwin
import Foundation

@main
struct AjarExecutable {
    static func main() async {
        let exitCode = await AjarCommand.run(
            arguments: Array(CommandLine.arguments.dropFirst())
        )
        guard exitCode == 0 else {
            Darwin.exit(exitCode)
        }
    }
}
