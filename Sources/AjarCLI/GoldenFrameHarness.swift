// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal

/// Parsed options for `ajar golden`.
public struct GoldenFrameOptions: Equatable, Sendable {
    /// Suite directory or manifest file.
    public let suiteURL: URL

    /// Creates options for a golden-frame run.
    public init(suiteURL: URL) {
        self.suiteURL = suiteURL
    }

    static func parse(_ arguments: [String]) throws -> GoldenFrameOptions {
        guard arguments.count <= 1 else {
            throw AjarCLIError.invalidUsage("golden accepts at most one suite path")
        }

        let path = arguments.first ?? "Tests/Fixtures/golden"
        return GoldenFrameOptions(suiteURL: URL(fileURLWithPath: path))
    }
}

/// Summary of one golden-frame run.
public struct GoldenFrameSummary: Equatable, Sendable {
    /// Number of passing cases.
    public let passCount: Int

    /// Number of failing cases.
    public let failureCount: Int
}

/// Manifest-driven golden-frame harness for TESTING Section 2 and ADR-0011.
public enum GoldenFrameHarness {
    /// Runs all manifests found under the suite path.
    public static func run(
        options: GoldenFrameOptions,
        standardOutput: any AjarTextOutput
    ) async throws -> GoldenFrameSummary {
        guard MTLCreateSystemDefaultDevice() != nil else {
            standardOutput.writeLine("SKIP golden-frame: Metal device unavailable")
            return GoldenFrameSummary(passCount: 0, failureCount: 0)
        }

        let manifestURLs = try discoverManifestURLs(at: options.suiteURL)
        guard !manifestURLs.isEmpty else {
            throw AjarCLIError.invalidGoldenManifest(
                "no golden manifest JSON files found at \(options.suiteURL.path)"
            )
        }

        var passCount = 0
        var failureCount = 0
        for manifestURL in manifestURLs {
            let manifest = try GoldenFrameManifest.load(from: manifestURL)
            let result = try await runCase(manifest: manifest, manifestURL: manifestURL)
            if result.comparison.passed {
                passCount += 1
                standardOutput.writeLine(
                    "PASS \(manifest.id) maxDeltaE="
                        + String(format: "%.3f", result.comparison.maximumDeltaE)
                        + " ssim="
                        + String(format: "%.6f", result.comparison.ssim)
                )
            } else {
                failureCount += 1
                try writeFailureArtifacts(
                    result: result,
                    manifest: manifest,
                    manifestURL: manifestURL
                )
                standardOutput.writeLine(
                    "FAIL \(manifest.id) maxDeltaE="
                        + String(format: "%.3f", result.comparison.maximumDeltaE)
                        + " ssim="
                        + String(format: "%.6f", result.comparison.ssim)
                )
            }
        }

        return GoldenFrameSummary(passCount: passCount, failureCount: failureCount)
    }

    private static func discoverManifestURLs(at url: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AjarCLIError.missingFile(url.path)
        }

        if !isDirectory.boolValue {
            return [url]
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil
        ) else {
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

    private static func runCase(
        manifest: GoldenFrameManifest,
        manifestURL: URL
    ) async throws -> GoldenFrameCaseResult {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-golden")
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let clipSpecs = try manifest.resolvedClipSpecs()
        let mediaURLs = clipSpecs.indices.map { index in
            workingDirectory.appendingPathComponent("source-\(index).mov")
        }
        let projectURL = workingDirectory.appendingPathComponent("project.ajar")
        let actualURL = workingDirectory.appendingPathComponent("actual.png")
        for (clipSpec, mediaURL) in zip(clipSpecs, mediaURLs) {
            try SyntheticMovieWriter.writeMovie(to: mediaURL, spec: clipSpec.syntheticMedia)
        }
        let project = try makeSyntheticProject(
            manifest: manifest,
            clipSpecs: clipSpecs,
            mediaURLs: mediaURLs
        )
        try ProjectPackageIO.writeProject(project, to: projectURL)

        _ = try await RenderFrameCommand.render(
            options: RenderFrameOptions(
                frameTime: try FrameTimeArgument.parse(manifest.frame),
                projectURL: projectURL,
                outputURL: actualURL
            )
        )

        let referenceURL = manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(manifest.referencePNG)
        let actualImage = try PNGCodec.read(from: actualURL)
        let referenceImage = try PNGCodec.read(from: referenceURL)
        let comparison = try GoldenFrameComparator.compare(
            actual: actualImage,
            reference: referenceImage,
            tolerance: manifest.tolerance
        )

        return GoldenFrameCaseResult(
            actualImage: actualImage,
            comparison: comparison
        )
    }

    private static func writeFailureArtifacts(
        result: GoldenFrameCaseResult,
        manifest: GoldenFrameManifest,
        manifestURL: URL
    ) throws {
        let artifactRoot = manifestURL.deletingLastPathComponent()
        let actualURL = artifactRoot
            .appendingPathComponent("_actual")
            .appendingPathComponent("\(manifest.id).png")
        let diffURL = artifactRoot
            .appendingPathComponent("_diff")
            .appendingPathComponent("\(manifest.id).png")

        try PNGCodec.write(result.actualImage, to: actualURL)
        try PNGCodec.write(result.comparison.diffImage, to: diffURL)
    }

    private static func makeSyntheticProject(
        manifest: GoldenFrameManifest,
        clipSpecs: [GoldenFrameClipSpec],
        mediaURLs: [URL]
    ) throws -> Project {
        guard let firstClipSpec = clipSpecs.first, clipSpecs.count == mediaURLs.count else {
            throw AjarCLIError.invalidGoldenManifest("\(manifest.id) has no synthetic clips")
        }

        let frameRate = try FrameRate(frames: Int64(firstClipSpec.syntheticMedia.frameRate))
        let duration = try frameRate.duration(
            ofFrames: Int64(firstClipSpec.syntheticMedia.frameCount)
        )
        let context = GoldenFrameBuildContext(
            manifestID: manifest.id,
            frameRate: frameRate,
            duration: duration
        )
        let resolution = manifest.outputDimensions ?? PixelDimensions(
            width: firstClipSpec.syntheticMedia.width,
            height: firstClipSpec.syntheticMedia.height
        )
        let media = try zip(clipSpecs, mediaURLs).enumerated().map { index, pair in
            try makeMediaRef(
                context: context,
                clipSpec: pair.0,
                mediaURL: pair.1,
                index: index
            )
        }
        let tracks = try clipSpecs.indices.map { index in
            Track(
                id: try numberedUUID(318 + index),
                kind: .video,
                items: [
                    .clip(
                        try makeClip(
                            context: context,
                            clipSpec: clipSpecs[index],
                            mediaID: media[index].id,
                            index: index
                        )
                    )
                ]
            )
        }
        let sequence = Sequence(
            id: try uuid("00000000-0000-0000-0000-000000000218"),
            name: "Golden \(manifest.id)",
            videoTracks: tracks,
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )

        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: resolution,
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: media,
            sequences: [sequence]
        )
    }

    private struct GoldenFrameBuildContext {
        let manifestID: String
        let frameRate: FrameRate
        let duration: RationalTime
    }

    private static func makeMediaRef(
        context: GoldenFrameBuildContext,
        clipSpec: GoldenFrameClipSpec,
        mediaURL: URL,
        index: Int
    ) throws -> MediaRef {
        MediaRef(
            id: try numberedUUID(18 + index),
            sourceURL: mediaURL,
            contentHash: ContentHash.sha256(data: Data("\(context.manifestID)-\(index)".utf8)),
            metadata: MediaMetadata(
                codecID: "prores4444",
                pixelDimensions: PixelDimensions(
                    width: clipSpec.syntheticMedia.width,
                    height: clipSpec.syntheticMedia.height
                ),
                frameRate: context.frameRate,
                duration: context.duration,
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
    }

    private static func makeClip(
        context: GoldenFrameBuildContext,
        clipSpec: GoldenFrameClipSpec,
        mediaID: UUID,
        index: Int
    ) throws -> Clip {
        Clip(
            id: try numberedUUID(118 + index),
            source: .media(id: mediaID),
            sourceRange: try TimeRange(start: .zero, duration: context.duration),
            timelineRange: try TimeRange(start: .zero, duration: context.duration),
            kind: .video,
            name: "Golden \(context.manifestID) \(index)",
            transform: clipSpec.transform ?? .identity,
            transformAnimation: clipSpec.transformAnimation
        )
    }

    private static func uuid(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw AjarCLIError.invalidGoldenManifest("invalid fixture UUID \(value)")
        }
        return uuid
    }

    private static func numberedUUID(_ value: Int) throws -> UUID {
        try uuid(String(format: "00000000-0000-0000-0000-%012d", value))
    }
}

/// JSON manifest for one golden-frame case.
struct GoldenFrameManifest: Codable, Equatable, Sendable {
    /// Manifest schema version.
    let schemaVersion: Int

    /// Stable case ID.
    let id: String

    /// Requirement IDs or references covered by this golden.
    let requirements: [String]

    /// Frame time passed to `ajar render --frame`.
    let frame: String

    /// Reference PNG path relative to the manifest directory.
    let referencePNG: String

    /// Optional output canvas dimensions. Defaults to the first synthetic clip dimensions.
    let outputDimensions: PixelDimensions?

    /// Legacy single synthetic media source specification.
    let syntheticMedia: SyntheticMovieSpec?

    /// Synthetic clips to stack bottom-to-top.
    let clips: [GoldenFrameClipSpec]?

    /// Comparison tolerance.
    let tolerance: GoldenFrameTolerance

    static func load(from url: URL) throws -> GoldenFrameManifest {
        do {
            let manifest = try JSONDecoder().decode(
                GoldenFrameManifest.self,
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
            _ = try manifest.resolvedClipSpecs()
            return manifest
        } catch let error as AjarCLIError {
            throw error
        } catch {
            throw AjarCLIError.invalidGoldenManifest(
                "\(url.path): \(String(describing: error))"
            )
        }
    }

    func resolvedClipSpecs() throws -> [GoldenFrameClipSpec] {
        if let clips, !clips.isEmpty {
            return clips
        }
        if let syntheticMedia {
            return [
                GoldenFrameClipSpec(
                    syntheticMedia: syntheticMedia,
                    transform: nil,
                    transformAnimation: nil
                )
            ]
        }
        throw AjarCLIError.invalidGoldenManifest("\(id) has no synthetic media")
    }
}

struct GoldenFrameClipSpec: Codable, Equatable, Sendable {
    let syntheticMedia: SyntheticMovieSpec
    let transform: ClipTransform?
    let transformAnimation: AnimatableClipTransform?
}

private struct GoldenFrameCaseResult {
    let actualImage: PNGImage
    let comparison: GoldenFrameComparison
}
