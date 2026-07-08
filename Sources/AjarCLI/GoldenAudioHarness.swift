// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import Foundation

/// Parsed options for `ajar golden-audio`.
public struct GoldenAudioOptions: Equatable, Sendable {
    /// Suite directory or manifest file.
    public let suiteURL: URL

    /// Creates options for a golden-audio run.
    public init(suiteURL: URL) {
        self.suiteURL = suiteURL
    }

    static func parse(_ arguments: [String]) throws -> GoldenAudioOptions {
        guard arguments.count <= 1 else {
            throw AjarCLIError.invalidUsage("golden-audio accepts at most one suite path")
        }

        let path = arguments.first ?? "Tests/Fixtures/golden-audio"
        return GoldenAudioOptions(suiteURL: URL(fileURLWithPath: path))
    }
}

/// Summary of one golden-audio run.
public struct GoldenAudioSummary: Equatable, Sendable {
    /// Number of passing cases.
    public let passCount: Int

    /// Number of failing cases.
    public let failureCount: Int
}

/// Manifest-driven golden-audio harness for TESTING Section 2 and ADR-0011.
public enum GoldenAudioHarness {
    /// Runs all manifests found under the suite path.
    public static func run(
        options: GoldenAudioOptions,
        standardOutput: any AjarTextOutput
    ) async throws -> GoldenAudioSummary {
        let manifestURLs = try discoverManifestURLs(at: options.suiteURL)
        guard !manifestURLs.isEmpty else {
            throw AjarCLIError.invalidGoldenManifest(
                "no golden-audio manifest JSON files found at \(options.suiteURL.path)"
            )
        }

        var passCount = 0
        var failureCount = 0
        for manifestURL in manifestURLs {
            let result = try runCase(manifestURL: manifestURL)
            if result.comparison.passed {
                passCount += 1
                standardOutput.writeLine(result.passLine)
            } else {
                failureCount += 1
                try writeFailureArtifacts(result: result, manifestURL: manifestURL)
                standardOutput.writeLine(result.failLine)
            }
        }

        return GoldenAudioSummary(passCount: passCount, failureCount: failureCount)
    }
}

private struct GoldenAudioCaseResult {
    let id: String
    let actual: RenderedAudioBuffer
    let comparison: GoldenAudioComparison

    var passLine: String {
        "PASS \(id) maxAbsError=" + String(format: "%.8f", comparison.maximumAbsoluteError)
    }

    var failLine: String {
        let error = "FAIL \(id) maxAbsError="
            + String(format: "%.8f", comparison.maximumAbsoluteError)
        guard let diagnostic = comparison.diagnostic else {
            return error
        }
        return "\(error) \(diagnostic)"
    }
}

private struct GoldenAudioComparison {
    let passed: Bool
    let maximumAbsoluteError: Float
    let diagnostic: String?
}

private struct GoldenAudioProjectBuildState {
    let sampleRate: Int
    var nextNestedSequenceOrdinal = 0
    var nestedSequences: [Sequence] = []
}

private extension GoldenAudioHarness {
    static func discoverManifestURLs(at url: URL) throws -> [URL] {
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

    static func runCase(manifestURL: URL) throws -> GoldenAudioCaseResult {
        let manifest = try GoldenAudioManifest.load(from: manifestURL)
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-golden-audio")
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let projectURL = workingDirectory.appendingPathComponent("project.ajar")
        let actualURL = workingDirectory.appendingPathComponent("actual.wav")
        let project = try makeProject(manifest: manifest, workingDirectory: workingDirectory)
        try ProjectPackageIO.writeProject(project, to: projectURL)
        _ = try RenderAudioCommand.render(
            options: RenderAudioOptions(
                startTime: .rational(.zero),
                duration: .rational(try manifest.renderDuration()),
                channelCount: manifest.channelCount,
                projectURL: projectURL,
                outputURL: actualURL
            )
        )

        let actual = try WAVCodec.readRenderedAudio(from: actualURL)
        let expected = try expectedBuffer(manifest: manifest)
        return GoldenAudioCaseResult(
            id: manifest.id,
            actual: actual,
            comparison: compare(
                actual: actual,
                expected: expected,
                tolerance: manifest.tolerance
            )
        )
    }
}

private extension GoldenAudioHarness {
    static func makeProject(
        manifest: GoldenAudioManifest,
        workingDirectory: URL
    ) throws -> Project {
        let media = try makeMedia(manifest: manifest, workingDirectory: workingDirectory)
        let trackSpecs = try manifest.trackSpecs()
        let trackIDs = try makeTrackIDs(count: trackSpecs.count)
        var buildState = GoldenAudioProjectBuildState(sampleRate: manifest.sampleRate)
        let tracks = try makeTracks(
            trackSpecs: trackSpecs,
            trackIDs: trackIDs,
            media: media,
            buildState: &buildState,
            clipIDBase: 72_400
        )
        let frameRate = try FrameRate(frames: Int64(manifest.sampleRate))
        let sequence = Sequence(
            id: try numberedUUID(72_100),
            name: "Golden Audio \(manifest.id)",
            videoTracks: tracks.filter { $0.kind == .video },
            audioTracks: tracks.filter { $0.kind == .audio },
            markers: [],
            audioDucking: try manifest.audioDuckingRules(trackIDs: trackIDs),
            timebase: frameRate
        )

        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 16, height: 16),
                colorSpace: .rec709,
                audioSampleRate: manifest.sampleRate
            ),
            mediaPool: media,
            sequences: [sequence] + buildState.nestedSequences
        )
    }

    static func makeMedia(
        manifest: GoldenAudioManifest,
        workingDirectory: URL
    ) throws -> [MediaRef] {
        try manifest.sources.enumerated().map { index, sourceSpec in
            let source = try sourceSpec.buffer()
            let sourceURL = workingDirectory.appendingPathComponent("source-\(index).wav")
            try WAVCodec.write(source, to: sourceURL)
            return try mediaRef(
                source: source,
                sourceURL: sourceURL,
                id: numberedUUID(72_300 + index)
            )
        }
    }

    static func makeTrackIDs(count: Int) throws -> [UUID] {
        try (0..<count).map { try numberedUUID(72_200 + $0) }
    }

    static func makeTracks(
        trackSpecs: [GoldenAudioTrackSpec],
        trackIDs: [UUID],
        media: [MediaRef],
        buildState: inout GoldenAudioProjectBuildState,
        clipIDBase: Int
    ) throws -> [Track] {
        return try trackSpecs.enumerated().map { trackIndex, trackSpec in
            let clips = try makeClips(
                for: trackSpec,
                trackIndex: trackIndex,
                media: media,
                buildState: &buildState,
                clipIDBase: clipIDBase
            )
            return trackSpec.track(
                id: trackIDs[trackIndex],
                items: clips.map { .clip($0) }
            )
        }
    }

    static func makeClips(
        for trackSpec: GoldenAudioTrackSpec,
        trackIndex: Int,
        media: [MediaRef],
        buildState: inout GoldenAudioProjectBuildState,
        clipIDBase: Int
    ) throws -> [Clip] {
        let specs = trackSpec.clips
        return try specs.enumerated().map { clipIndex, clipSpec in
            let source = try clipSource(
                clipSpec,
                media: media,
                buildState: &buildState
            )
            let clipNumber = clipIDBase + (trackIndex * 100) + clipIndex
            // `crossfadeToNext` stores the ADR-0015 pair: the trailing record on this clip
            // and the mirroring leading record on the next clip (FR-AUD-002).
            if clipSpec.crossfadeToNext != nil, clipIndex == specs.count - 1 {
                throw AjarCLIError.invalidGoldenManifest(
                    "crossfadeToNext on the last clip of a track has no partner"
                )
            }
            let leadingSpec = clipIndex > 0 ? specs[clipIndex - 1].crossfadeToNext : nil
            return try clipSpec.clip(
                id: numberedUUID(clipNumber),
                source: source,
                kind: trackSpec.kind,
                leadingCrossfade: leadingSpec?.record(
                    partnerClipID: try numberedUUID(clipNumber - 1)
                ),
                trailingCrossfade: clipSpec.crossfadeToNext?.record(
                    partnerClipID: try numberedUUID(clipNumber + 1)
                )
            )
        }
    }

    static func clipSource(
        _ clipSpec: GoldenAudioClipSpec,
        media: [MediaRef],
        buildState: inout GoldenAudioProjectBuildState
    ) throws -> ClipSource {
        if let compound = clipSpec.compound {
            guard clipSpec.sourceIndex == nil else {
                throw AjarCLIError.invalidGoldenManifest(
                    "compound audio clip cannot also set sourceIndex"
                )
            }
            return .sequence(
                id: try makeNestedSequence(
                    compound: compound,
                    media: media,
                    buildState: &buildState
                )
            )
        }

        guard let sourceIndex = clipSpec.sourceIndex,
              sourceIndex >= 0,
              sourceIndex < media.count
        else {
            throw AjarCLIError.invalidGoldenManifest("clip sourceIndex is out of range")
        }
        return .media(id: media[sourceIndex].id)
    }

    static func makeNestedSequence(
        compound: GoldenAudioCompoundSpec,
        media: [MediaRef],
        buildState: inout GoldenAudioProjectBuildState
    ) throws -> UUID {
        let sequenceOrdinal = buildState.nextNestedSequenceOrdinal
        buildState.nextNestedSequenceOrdinal += 1
        let sequenceID = try numberedUUID(72_500 + sequenceOrdinal)
        let trackSpecs = try compound.trackSpecs()
        let trackIDs = try makeNestedTrackIDs(
            sequenceOrdinal: sequenceOrdinal,
            count: trackSpecs.count
        )
        let tracks = try makeTracks(
            trackSpecs: trackSpecs,
            trackIDs: trackIDs,
            media: media,
            buildState: &buildState,
            clipIDBase: 72_700 + (sequenceOrdinal * 1_000)
        )
        let sequence = Sequence(
            id: sequenceID,
            name: "Golden Nested Audio \(sequenceOrdinal)",
            videoTracks: tracks.filter { $0.kind == .video },
            audioTracks: tracks.filter { $0.kind == .audio },
            markers: [],
            timebase: try FrameRate(frames: Int64(buildState.sampleRate))
        )
        buildState.nestedSequences.append(sequence)
        return sequenceID
    }

    static func makeNestedTrackIDs(sequenceOrdinal: Int, count: Int) throws -> [UUID] {
        try (0..<count).map { try numberedUUID(72_600 + (sequenceOrdinal * 100) + $0) }
    }

    static func mediaRef(source: AudioSourceBuffer, sourceURL: URL, id: UUID) throws -> MediaRef {
        let duration = try RationalTime(
            value: Int64(source.frameCount),
            timescale: Int64(source.format.sampleRate)
        )
        return MediaRef(
            id: id,
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: Data(sourceURL.path.utf8)),
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
    }
}

private extension GoldenAudioHarness {
    static func expectedBuffer(manifest: GoldenAudioManifest) throws -> RenderedAudioBuffer {
        guard manifest.channelCount > 0,
              manifest.referenceSamples.count % manifest.channelCount == 0
        else {
            throw AjarCLIError.invalidGoldenManifest("reference samples do not match channels")
        }

        return try RenderedAudioBuffer(
            format: AudioRenderFormat(
                sampleRate: manifest.sampleRate,
                channelCount: manifest.channelCount
            ),
            frameCount: manifest.referenceSamples.count / manifest.channelCount,
            samples: manifest.referenceSamples
        )
    }

    static func compare(
        actual: RenderedAudioBuffer,
        expected: RenderedAudioBuffer,
        tolerance: Float
    ) -> GoldenAudioComparison {
        guard actual.format == expected.format, actual.frameCount == expected.frameCount else {
            return GoldenAudioComparison(
                passed: false,
                maximumAbsoluteError: .infinity,
                diagnostic: formatMismatchDiagnostic(actual: actual, expected: expected)
            )
        }

        var maximumError = Float(0)
        for index in actual.samples.indices {
            maximumError = max(maximumError, abs(actual.samples[index] - expected.samples[index]))
        }
        return GoldenAudioComparison(
            passed: maximumError <= tolerance,
            maximumAbsoluteError: maximumError,
            diagnostic: nil
        )
    }

    static func formatMismatchDiagnostic(
        actual: RenderedAudioBuffer,
        expected: RenderedAudioBuffer
    ) -> String {
        "formatMismatch actual=\(actual.format.sampleRate)Hz/"
            + "\(actual.format.channelCount)ch/\(actual.frameCount)f"
            + " expected=\(expected.format.sampleRate)Hz/"
            + "\(expected.format.channelCount)ch/\(expected.frameCount)f"
    }

    static func writeFailureArtifacts(
        result: GoldenAudioCaseResult,
        manifestURL: URL
    ) throws {
        let actualURL = manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent("_actual")
            .appendingPathComponent("\(result.id).wav")
        try WAVCodec.write(result.actual, to: actualURL)
    }

    static func numberedUUID(_ number: Int) throws -> UUID {
        let suffix = String(format: "%012d", number)
        guard let uuid = UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") else {
            throw AjarCLIError.invalidGoldenManifest("could not build deterministic UUID")
        }
        return uuid
    }
}
