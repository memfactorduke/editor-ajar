// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarExport
import Foundation
import Metal

/// Parsed options for `ajar golden-export`.
public struct GoldenExportOptions: Equatable, Sendable {
    /// Suite directory or single manifest file.
    public let suiteURL: URL

    /// Creates options for an export-golden run.
    public init(suiteURL: URL) {
        self.suiteURL = suiteURL
    }

    static func parse(_ arguments: [String]) throws -> GoldenExportOptions {
        guard arguments.count <= 1 else {
            throw AjarCLIError.invalidUsage("golden-export accepts at most one suite path")
        }
        let path = arguments.first ?? "Tests/Fixtures/golden-export"
        return GoldenExportOptions(suiteURL: URL(fileURLWithPath: path))
    }
}

/// Summary of one export-golden run (FR-EXP-007).
public struct GoldenExportSummary: Equatable, Sendable {
    /// Passing cases (including capability-gated skips counted as pass-with-skip).
    public let passCount: Int

    /// Failing cases.
    public let failureCount: Int

    /// Cases skipped because a hardware encoder was unavailable.
    public let skipCount: Int
}

/// Manifest-driven export golden harness for FR-EXP-007.
///
/// **Why a separate `golden-export` subcommand (not `golden --export`):**
/// the existing `golden` path compares render-harness PNGs to stored references; export golden
/// pulls through `ExportSession`, decodes containers, and compares against the live render-path
/// expectation with codec-banded tolerances. That is a different pipeline, different fixtures
/// (`Tests/Fixtures/golden-export`), and different skip rules (hardware encoder capability).
/// The same shape as `golden-audio` keeps the CLI map predictable.
public enum GoldenExportHarness {
    /// Runs all manifests found under the suite path.
    public static func run(
        options: GoldenExportOptions,
        standardOutput: any AjarTextOutput
    ) async throws -> GoldenExportSummary {
        guard MTLCreateSystemDefaultDevice() != nil else {
            standardOutput.writeLine("SKIP golden-export: Metal device unavailable")
            return GoldenExportSummary(passCount: 0, failureCount: 0, skipCount: 0)
        }

        let manifestURLs = try discoverManifestURLs(at: options.suiteURL)
        guard !manifestURLs.isEmpty else {
            throw AjarCLIError.invalidGoldenManifest(
                "no golden-export manifest JSON files found at \(options.suiteURL.path)"
            )
        }

        var passCount = 0
        var failureCount = 0
        var skipCount = 0
        for manifestURL in manifestURLs {
            let manifest = try GoldenExportManifest.load(from: manifestURL)
            let outcome = try await runCase(manifest: manifest)
            switch outcome {
            case .passed(let line):
                passCount += 1
                standardOutput.writeLine(line)
            case .skipped(let line):
                skipCount += 1
                standardOutput.writeLine(line)
            case .failed(let line):
                failureCount += 1
                standardOutput.writeLine(line)
            }
        }

        // Zero-verified-work guard (theater gate): all-skip or empty effective work is a failure.
        // Callers map passCount==0 && failureCount==0 to a nonzero process exit.
        if passCount == 0, failureCount == 0 {
            standardOutput.writeLine(
                "FAIL golden-export: zero verified work "
                    + "(passCount=0 failureCount=0 skipCount=\(skipCount))"
            )
        }

        return GoldenExportSummary(
            passCount: passCount,
            failureCount: failureCount,
            skipCount: skipCount
        )
    }

    enum CaseOutcome {
        case passed(String)
        case skipped(String)
        case failed(String)
    }

    private static func discoverManifestURLs(at url: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AjarCLIError.missingFile(url.path)
        }
        if !isDirectory.boolValue {
            return [url]
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: nil
            )
        else {
            throw AjarCLIError.invalidGoldenManifest("could not enumerate \(url.path)")
        }
        var manifests: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "manifest.json" else {
                continue
            }
            manifests.append(fileURL)
        }
        return manifests.sorted { left, right in left.path < right.path }
    }

    private static func runCase(manifest: GoldenExportManifest) async throws -> CaseOutcome {
        switch manifest.mode {
        case .movie:
            return try await runMovieCase(manifest: manifest)
        case .stillPNG:
            return try await runStillPNGCase(manifest: manifest)
        case .animatedGIF:
            return try await runAnimatedGIFCase(manifest: manifest)
        }
    }

    private static func runMovieCase(manifest: GoldenExportManifest) async throws -> CaseOutcome {
        let codec = try manifest.videoCodec()
        let container = try manifest.exportContainer()
        let fixture = try ExportGoldenFixture(
            frameCount: Int64(manifest.frameCount),
            width: manifest.width,
            height: manifest.height,
            includeAudio: manifest.includeAudio
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let settings = try fixture.movieSettings(
            container: container,
            codec: codec,
            audioCodec: manifest.includeAudio ? .linearPCM : nil
        )
        let destinationURL = fixture.directoryURL.appendingPathComponent(
            "export.\(container.rawValue)"
        )
        let exportStep = try await exportMovieOrSkip(
            fixture: fixture,
            destinationURL: destinationURL,
            settings: settings,
            codec: codec,
            manifest: manifest
        )
        switch exportStep {
        case .outcome(let outcome):
            return outcome
        case .session(let session):
            return try await compareMovieExport(
                context: MovieCompareContext(
                    fixture: fixture,
                    settings: settings,
                    destinationURL: destinationURL,
                    session: session,
                    codec: codec,
                    manifestID: manifest.id
                )
            )
        }
    }

    private enum MovieExportStep {
        case outcome(CaseOutcome)
        case session(ExportSession)
    }

    private struct MovieCompareContext {
        let fixture: ExportGoldenFixture
        let settings: ExportSettings
        let destinationURL: URL
        let session: ExportSession
        let codec: ExportVideoCodec
        let manifestID: String
    }

    private static func exportMovieOrSkip(
        fixture: ExportGoldenFixture,
        destinationURL: URL,
        settings: ExportSettings,
        codec: ExportVideoCodec,
        manifest: GoldenExportManifest
    ) async throws -> MovieExportStep {
        do {
            let exported = try await fixture.exportMovie(
                to: destinationURL,
                settings: settings
            )
            guard exported.result.videoFrameCount == Int64(manifest.frameCount) else {
                return .outcome(
                    .failed(
                        "FAIL \(manifest.id) frameCount=\(exported.result.videoFrameCount) "
                            + "expected=\(manifest.frameCount)"
                    )
                )
            }
            return .session(exported.session)
        } catch let error as ExportError {
            if error.isHardwareEncoderUnavailable(for: codec) {
                return .outcome(
                    .skipped(
                        "SKIP \(manifest.id) \(codec.rawValue) hardware encoder unavailable: "
                            + "\(error)"
                    )
                )
            }
            return .outcome(.failed("FAIL \(manifest.id) export error: \(error)"))
        }
    }

    private static func compareMovieExport(
        context: MovieCompareContext
    ) async throws -> CaseOutcome {
        let proxyOK = context.session.sourceSelectionRecords.allSatisfy { $0.tier == .original }
            && context.session.sourceSelectionPolicy == .alwaysOriginal
        guard proxyOK else {
            return .failed("FAIL \(context.manifestID) source selection used non-original media")
        }

        let expected = try await context.fixture.renderExpectedBGRAFrames(
            resolution: context.settings.video.resolution,
            colorSpace: context.settings.video.colorSpace
        )
        let actual = try await ExportMovieDecoder.decodeBGRA8Frames(from: context.destinationURL)
        let comparison = ExportGoldenComparator.compareSequences(
            actual: actual,
            expected: expected,
            tolerance: ExportGoldenTolerance.forVideoCodec(context.codec)
        )
        if comparison.passed {
            return .passed(
                "PASS \(context.manifestID) maxChΔ=\(comparison.maximumChannelDelta) "
                    + "mae=\(String(format: "%.3f", comparison.meanAbsoluteError))"
            )
        }
        try GoldenExportFrameDumper.dumpIfRequested(
            manifestID: context.manifestID,
            actual: actual,
            expected: expected,
            comparison: comparison
        )
        let diagnostic = comparison.diagnostic.map { " \($0)" } ?? ""
        return .failed(
            "FAIL \(context.manifestID) maxChΔ=\(comparison.maximumChannelDelta) "
                + "mae=\(String(format: "%.3f", comparison.meanAbsoluteError))"
                + diagnostic
        )
    }

    private static func runStillPNGCase(
        manifest: GoldenExportManifest
    ) async throws -> CaseOutcome {
        let fixture = try ExportGoldenFixture(
            frameCount: 1,
            width: manifest.width,
            height: manifest.height,
            includeAudio: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let destinationURL = fixture.directoryURL.appendingPathComponent("still.png")
        try await fixture.exportStillPNG(to: destinationURL)
        let expected = try await fixture.renderStillExpectationBGRA()
        let actual = try StillFrameExporter.decodeStillBGRA8(
            from: destinationURL,
            colorSpace: fixture.colorSpace
        )
        let comparison = ExportGoldenComparator.compare(
            actual: actual,
            expected: expected,
            tolerance: .stillPNGBitExact
        )
        if comparison.passed {
            return .passed("PASS \(manifest.id) still PNG bit-exact")
        }
        try GoldenExportFrameDumper.dumpIfRequested(
            manifestID: manifest.id,
            actual: [actual],
            expected: [expected],
            comparison: comparison
        )
        return .failed(
            "FAIL \(manifest.id) still PNG mismatch"
                + (comparison.diagnostic.map { " \($0)" } ?? "")
        )
    }
}

/// Optional CI diagnosis hook for `AJAR_GOLDEN_EXPORT_DUMP=<dir>`.
enum GoldenExportFrameDumper {
    static func dumpIfRequested(
        manifestID: String,
        actual: [ExportDecodedBGRAFrame],
        expected: [ExportDecodedBGRAFrame],
        comparison: ExportGoldenComparison
    ) throws {
        guard let dumpPath = ProcessInfo.processInfo.environment["AJAR_GOLDEN_EXPORT_DUMP"],
              !dumpPath.isEmpty
        else {
            return
        }
        let dumpDir = URL(fileURLWithPath: dumpPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)

        let frameIndex = failingFrameIndex(
            actual: actual,
            expected: expected,
            comparison: comparison
        )
        guard let frameIndex,
              actual.indices.contains(frameIndex),
              expected.indices.contains(frameIndex)
        else {
            return
        }
        let base = "\(manifestID)-frame\(frameIndex)"
        try writeBGRA8PNG(
            actual[frameIndex],
            to: dumpDir.appendingPathComponent("\(base)-actual.png")
        )
        try writeBGRA8PNG(
            expected[frameIndex],
            to: dumpDir.appendingPathComponent("\(base)-expected.png")
        )
    }

    private static func failingFrameIndex(
        actual: [ExportDecodedBGRAFrame],
        expected: [ExportDecodedBGRAFrame],
        comparison: ExportGoldenComparison
    ) -> Int? {
        if let diagnostic = comparison.diagnostic {
            // Diagnostics look like "frame 11 failed tolerance" or "frame 11: …".
            let prefix = "frame "
            if let range = diagnostic.range(of: prefix) {
                let rest = diagnostic[range.upperBound...]
                let digits = rest.prefix(while: \.isNumber)
                if let parsed = Int(digits) {
                    return parsed
                }
            }
        }
        guard actual.count == expected.count, !actual.isEmpty else {
            return actual.isEmpty ? nil : 0
        }
        // First index with any channel difference (dump hook; tolerance already failed).
        for index in actual.indices where actual[index].bgra8 != expected[index].bgra8 {
            return index
        }
        return actual.indices.last
    }

    private static func writeBGRA8PNG(_ frame: ExportDecodedBGRAFrame, to url: URL) throws {
        let image = PNGImage(
            width: frame.width,
            height: frame.height,
            bgra8: Array(frame.bgra8)
        )
        try PNGCodec.write(image, to: url)
    }
}

/// Manifest for one FR-EXP-007 export golden case.
struct GoldenExportManifest: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Equatable, Sendable {
        case movie
        case stillPNG
        case animatedGIF
    }

    let schemaVersion: Int
    let id: String
    let requirements: [String]
    let mode: Mode
    let codec: String?
    let container: String?
    let frameCount: Int
    let width: Int
    let height: Int
    let includeAudio: Bool

    static func load(from url: URL) throws -> GoldenExportManifest {
        do {
            let manifest = try JSONDecoder().decode(
                GoldenExportManifest.self,
                from: try Data(contentsOf: url)
            )
            guard manifest.schemaVersion == 1 else {
                throw AjarCLIError.invalidGoldenManifest(
                    "\(url.path) uses unsupported schema \(manifest.schemaVersion)"
                )
            }
            guard !manifest.requirements.isEmpty else {
                throw AjarCLIError.invalidGoldenManifest("\(url.path) has no requirement refs")
            }
            guard manifest.frameCount > 0, manifest.frameCount <= 30 else {
                throw AjarCLIError.invalidGoldenManifest(
                    "\(manifest.id) frameCount must be in 1...30"
                )
            }
            if manifest.mode == .movie {
                _ = try manifest.videoCodec()
                _ = try manifest.exportContainer()
            }
            return manifest
        } catch let error as AjarCLIError {
            throw error
        } catch {
            throw AjarCLIError.invalidGoldenManifest(
                "\(url.path): \(String(describing: error))"
            )
        }
    }

    func videoCodec() throws -> ExportVideoCodec {
        guard let codec, let value = ExportVideoCodec(rawValue: codec) else {
            throw AjarCLIError.invalidGoldenManifest("\(id) missing or unknown codec")
        }
        return value
    }

    func exportContainer() throws -> ExportContainer {
        guard let container, let value = ExportContainer(rawValue: container) else {
            throw AjarCLIError.invalidGoldenManifest("\(id) missing or unknown container")
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case requirements
        case mode
        case codec
        case container
        case frameCount
        case width
        case height
        case includeAudio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        requirements = try container.decode([String].self, forKey: .requirements)
        mode = try container.decode(Mode.self, forKey: .mode)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        frameCount = try container.decodeIfPresent(Int.self, forKey: .frameCount) ?? 12
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 64
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 64
        includeAudio = try container.decodeIfPresent(Bool.self, forKey: .includeAudio) ?? false
    }
}
