// SPDX-License-Identifier: GPL-3.0-or-later
// swiftlint:disable file_length

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
public enum GoldenFrameHarness {  // swiftlint:disable:this type_body_length
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
        let mediaURLs: [URL?] = clipSpecs.indices.map { index in
            clipSpecs[index].isTitleClip
                ? nil
                : workingDirectory.appendingPathComponent("source-\(index).mov")
        }
        let projectURL = workingDirectory.appendingPathComponent("project.ajar")
        let actualURL = workingDirectory.appendingPathComponent("actual.png")
        for (clipSpec, mediaURL) in zip(clipSpecs, mediaURLs) {
            guard let mediaURL, let syntheticMedia = clipSpec.syntheticMedia else {
                continue
            }
            try SyntheticMovieWriter.writeMovie(to: mediaURL, spec: syntheticMedia)
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

        let referenceURL =
            manifestURL
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
        let actualURL =
            artifactRoot
            .appendingPathComponent("_actual")
            .appendingPathComponent("\(manifest.id).png")
        let diffURL =
            artifactRoot
            .appendingPathComponent("_diff")
            .appendingPathComponent("\(manifest.id).png")

        try PNGCodec.write(result.actualImage, to: actualURL)
        try PNGCodec.write(result.comparison.diffImage, to: diffURL)
    }

    private static func makeSyntheticProject(
        manifest: GoldenFrameManifest,
        clipSpecs: [GoldenFrameClipSpec],
        mediaURLs: [URL?]
    ) throws -> Project {
        guard !clipSpecs.isEmpty, clipSpecs.count == mediaURLs.count else {
            throw AjarCLIError.invalidGoldenManifest("\(manifest.id) has no synthetic clips")
        }

        let timing = try timingAndSize(from: clipSpecs, manifest: manifest)
        let context = GoldenFrameBuildContext(
            manifestID: manifest.id,
            frameRate: timing.frameRate,
            duration: timing.duration
        )
        let resolution =
            manifest.outputDimensions
            ?? PixelDimensions(
                width: timing.defaultWidth,
                height: timing.defaultHeight
            )
        var media: [MediaRef?] = Array(repeating: nil, count: clipSpecs.count)
        for index in clipSpecs.indices {
            guard let mediaURL = mediaURLs[index], clipSpecs[index].title == nil else {
                continue
            }
            media[index] = try makeMediaRef(
                context: context,
                clipSpec: clipSpecs[index],
                mediaURL: mediaURL,
                index: index
            )
        }
        let tracks = try makeTracks(context: context, clipSpecs: clipSpecs, media: media)
        let compoundSequences = try makeCompoundSequences(
            context: context,
            clipSpecs: clipSpecs,
            media: media
        )
        let sequence = Sequence(
            id: try uuid("00000000-0000-0000-0000-000000000218"),
            name: "Golden \(manifest.id)",
            videoTracks: tracks,
            audioTracks: [],
            markers: [],
            timebase: timing.frameRate
        )

        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: timing.frameRate,
                resolution: resolution,
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: media.compactMap { $0 },
            sequences: [sequence] + compoundSequences
        )
    }

    private struct GoldenTimingAndSize {
        let frameRate: FrameRate
        let duration: RationalTime
        let defaultWidth: Int
        let defaultHeight: Int
    }

    private static func timingAndSize(
        from clipSpecs: [GoldenFrameClipSpec],
        manifest: GoldenFrameManifest
    ) throws -> GoldenTimingAndSize {
        if let mediaSpec = clipSpecs.compactMap(\.syntheticMedia).first {
            let frameRate = try FrameRate(frames: Int64(mediaSpec.frameRate))
            let duration = try frameRate.duration(ofFrames: Int64(mediaSpec.frameCount))
            return GoldenTimingAndSize(
                frameRate: frameRate,
                duration: duration,
                defaultWidth: mediaSpec.width,
                defaultHeight: mediaSpec.height
            )
        }
        // Title-only fixtures must declare output dimensions and use a fixed 24 fps / 1 frame.
        let frameRate = try FrameRate(frames: 24)
        let duration = try frameRate.duration(ofFrames: 1)
        return GoldenTimingAndSize(
            frameRate: frameRate,
            duration: duration,
            defaultWidth: manifest.outputDimensions?.width ?? 64,
            defaultHeight: manifest.outputDimensions?.height ?? 64
        )
    }

    private static func makeTracks(
        context: GoldenFrameBuildContext,
        clipSpecs: [GoldenFrameClipSpec],
        media: [MediaRef?]
    ) throws -> [Track] {
        // FR-FX-001: when any clip carries cut-edge transition metadata, place all clips
        // on one video track at their `timelineStartFrame` so the fade-tail region is live.
        let usesTransitions = clipSpecs.contains(where: \.hasVideoTransition)
        if usesTransitions {
            let items: [TimelineItem] = try clipSpecs.indices.map { index in
                .clip(
                    try makeClip(
                        context: context,
                        clipSpec: clipSpecs[index],
                        mediaID: media[index]?.id,
                        index: index
                    )
                )
            }
            return [
                Track(
                    id: try numberedUUID(318),
                    kind: .video,
                    items: items,
                    opacity: clipSpecs[0].trackOpacity ?? .constant(.one),
                    blendMode: clipSpecs[0].trackBlendMode ?? .normal
                )
            ]
        }
        return try clipSpecs.indices.map { index in
            Track(
                id: try numberedUUID(318 + index),
                kind: .video,
                items: [
                    .clip(
                        try makeClip(
                            context: context,
                            clipSpec: clipSpecs[index],
                            mediaID: media[index]?.id,
                            index: index
                        )
                    )
                ],
                opacity: clipSpecs[index].trackOpacity ?? .constant(.one),
                blendMode: clipSpecs[index].trackBlendMode ?? .normal
            )
        }
    }

    private static func makeCompoundSequences(
        context: GoldenFrameBuildContext,
        clipSpecs: [GoldenFrameClipSpec],
        media: [MediaRef?]
    ) throws -> [Sequence] {
        try clipSpecs.indices.compactMap { index in
            guard let compound = clipSpecs[index].compound else {
                return nil
            }
            guard let mediaID = media[index]?.id else {
                throw AjarCLIError.invalidGoldenManifest(
                    "\(context.manifestID) compound clip \(index) needs syntheticMedia"
                )
            }

            let clip = try makeMediaClip(
                context: context,
                clipSpec: clipSpecs[index],
                mediaID: mediaID,
                index: index,
                compound: compound
            )
            return Sequence(
                id: try compoundSequenceID(index: index),
                name: "Golden compound \(context.manifestID) \(index)",
                videoTracks: [
                    Track(
                        id: try numberedUUID(518 + index),
                        kind: .video,
                        items: [.clip(clip)]
                    )
                ],
                audioTracks: [],
                markers: [],
                timebase: context.frameRate
            )
        }
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
        guard let syntheticMedia = clipSpec.syntheticMedia else {
            throw AjarCLIError.invalidGoldenManifest(
                "\(context.manifestID) media clip \(index) missing syntheticMedia"
            )
        }
        return MediaRef(
            id: try numberedUUID(18 + index),
            sourceURL: mediaURL,
            contentHash: ContentHash.sha256(data: Data("\(context.manifestID)-\(index)".utf8)),
            metadata: MediaMetadata(
                codecID: "prores4444",
                pixelDimensions: PixelDimensions(
                    width: syntheticMedia.width,
                    height: syntheticMedia.height
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
        mediaID: UUID?,
        index: Int
    ) throws -> Clip {
        let speed = clipSpec.speed ?? .one
        let timeRemap = try clipSpec.timeRemap.map { try $0.clipTimeRemap() }
        let clipDuration = try clipTimelineDuration(
            context: context,
            clipSpec: clipSpec,
            speed: speed,
            timeRemap: timeRemap
        )
        let timelineStart: RationalTime
        if let startFrame = clipSpec.timelineStartFrame {
            timelineStart = try context.frameRate.duration(ofFrames: startFrame)
        } else {
            timelineStart = .zero
        }
        let sourceDuration: RationalTime
        if let sourceFrames = clipSpec.sourceFrameCount {
            sourceDuration = try context.frameRate.duration(ofFrames: sourceFrames)
        } else if let media = clipSpec.syntheticMedia {
            sourceDuration = try context.frameRate.duration(ofFrames: Int64(media.frameCount))
        } else {
            sourceDuration = context.duration
        }
        let resolvedTimelineDuration: RationalTime
        if clipSpec.sourceFrameCount != nil, timeRemap == nil {
            // Timeline span matches the declared source window at the clip speed.
            resolvedTimelineDuration = try Clip.timelineDuration(
                forSourceDuration: sourceDuration,
                speed: speed
            )
        } else {
            resolvedTimelineDuration = clipDuration
        }
        return Clip(
            id: try numberedUUID(118 + index),
            source: try source(for: clipSpec, mediaID: mediaID, index: index),
            sourceRange: try TimeRange(start: .zero, duration: sourceDuration),
            timelineRange: try TimeRange(
                start: timelineStart,
                duration: resolvedTimelineDuration
            ),
            kind: .video,
            name: "Golden \(context.manifestID) \(index)",
            transform: clipSpec.transform ?? .identity,
            transformAnimation: clipSpec.transformAnimation,
            effects: clipSpec.effects ?? .none,
            effectsAnimation: clipSpec.effectsAnimation,
            effectStack: clipSpec.effectStack ?? .empty,
            effectStackAnimation: clipSpec.effectStackAnimation,
            leadingTransition: clipSpec.leadingTransition,
            trailingTransition: clipSpec.trailingTransition,
            speed: speed,
            reverse: clipSpec.reverse ?? false,
            freezeFrame: clipSpec.freezeFrame ?? false,
            timeRemap: timeRemap,
            frameSampling: clipSpec.frameSampling ?? .nearest
        )
    }

    private static func clipTimelineDuration(
        context: GoldenFrameBuildContext,
        clipSpec: GoldenFrameClipSpec,
        speed: RationalValue,
        timeRemap: ClipTimeRemap?
    ) throws -> RationalTime {
        if let timeRemap {
            return timeRemap.duration
        }
        if let media = clipSpec.syntheticMedia {
            let sourceDuration = try context.frameRate.duration(ofFrames: Int64(media.frameCount))
            return try Clip.timelineDuration(forSourceDuration: sourceDuration, speed: speed)
        }
        return try timelineDuration(context: context, speed: speed, timeRemap: nil)
    }

    private static func makeMediaClip(
        context: GoldenFrameBuildContext,
        clipSpec: GoldenFrameClipSpec,
        mediaID: UUID,
        index: Int,
        compound: GoldenFrameCompoundSpec
    ) throws -> Clip {
        let speed = clipSpec.speed ?? .one
        return Clip(
            id: try numberedUUID(618 + index),
            source: .media(id: mediaID),
            sourceRange: try TimeRange(start: .zero, duration: context.duration),
            timelineRange: try TimeRange(
                start: .zero,
                duration: Clip.timelineDuration(forSourceDuration: context.duration, speed: speed)
            ),
            kind: .video,
            name: "Golden nested \(context.manifestID) \(index)",
            transform: compound.innerTransform ?? .identity,
            transformAnimation: clipSpec.transformAnimation,
            effects: compound.innerEffects ?? .none,
            effectsAnimation: clipSpec.effectsAnimation,
            effectStack: clipSpec.effectStack ?? .empty,
            effectStackAnimation: clipSpec.effectStackAnimation,
            speed: speed,
            reverse: clipSpec.reverse ?? false,
            freezeFrame: clipSpec.freezeFrame ?? false,
            frameSampling: clipSpec.frameSampling ?? .nearest
        )
    }

    private static func timelineDuration(
        context: GoldenFrameBuildContext,
        speed: RationalValue,
        timeRemap: ClipTimeRemap?
    ) throws -> RationalTime {
        if let timeRemap {
            return timeRemap.duration
        }
        return try Clip.timelineDuration(forSourceDuration: context.duration, speed: speed)
    }

    private static func source(
        for clipSpec: GoldenFrameClipSpec,
        mediaID: UUID?,
        index: Int
    ) throws -> ClipSource {
        if let title = clipSpec.title {
            return .title(title)
        }
        if clipSpec.compound != nil {
            return .sequence(id: try compoundSequenceID(index: index))
        }
        guard let mediaID else {
            throw AjarCLIError.invalidGoldenManifest(
                "media clip \(index) missing media reference"
            )
        }
        return .media(id: mediaID)
    }

    private static func compoundSequenceID(index: Int) throws -> UUID {
        try numberedUUID(418 + index)
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

private struct GoldenFrameCaseResult {
    let actualImage: PNGImage
    let comparison: GoldenFrameComparison
}
