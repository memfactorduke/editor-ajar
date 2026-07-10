// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import CoreVideo
import Foundation
import Metal

/// Small synthetic export project used by FR-EXP-007 golden / determinism gates.
///
/// Title-backed video (no decode dependency) plus optional offline-mixer tone keeps runtime
/// under ~10–20 frames at 64×64 while still exercising the real `ExportSession` path.
public struct ExportGoldenFixture: Sendable {
    /// Working directory for destinations (caller may delete).
    public let directoryURL: URL

    /// Captured project snapshot.
    public let project: Project

    /// Sequence under test.
    public let sequence: Sequence

    /// Export range (zero-based, exact frame count at the sequence timebase).
    public let range: TimeRange

    /// Optional in-memory audio for PCM / AAC offline mix.
    public let audioProvider: InMemoryAudioSourceProvider?

    /// Frame count planned for movie export.
    public let frameCount: Int64

    /// Delivery color space.
    public let colorSpace: ExportColorSpace

    /// Builds a title + optional tone fixture at low resolution.
    public init(
        frameCount: Int64 = 12,
        width: Int = 64,
        height: Int = 64,
        frameRate: FrameRate? = nil,
        colorSpace: ExportColorSpace = .rec709,
        includeAudio: Bool = false,
        directoryURL: URL? = nil
    ) throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "Metal device unavailable"
            )
        }
        let resolvedFrameRate = try frameRate ?? FrameRate(frames: 30)
        self.frameCount = frameCount
        self.colorSpace = colorSpace
        self.directoryURL = directoryURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-export-golden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: self.directoryURL,
            withIntermediateDirectories: true
        )

        let duration = try resolvedFrameRate.duration(ofFrames: frameCount)
        range = try TimeRange(start: .zero, duration: duration)
        let mediaID = UUID()
        sequence = try Self.makeSequence(
            mediaID: mediaID,
            frameRate: resolvedFrameRate,
            range: range,
            includeAudio: includeAudio
        )
        project = Self.makeProject(
            sequence: sequence,
            mediaID: mediaID,
            duration: duration,
            settings: ProjectSettings(
                frameRate: resolvedFrameRate,
                resolution: PixelDimensions(width: width, height: height),
                colorSpace: colorSpace.mediaColorSpace,
                audioSampleRate: 48_000
            ),
            colorSpace: colorSpace
        )
        if includeAudio {
            audioProvider = try Self.makeAudioProvider(mediaID: mediaID, duration: duration)
        } else {
            audioProvider = nil
        }
    }

    /// Validated movie export settings for this fixture.
    public func movieSettings(
        container: ExportContainer,
        codec: ExportVideoCodec,
        audioCodec: ExportAudioCodec? = nil
    ) throws -> ExportSettings {
        let averageBitRate: Int? = codec.isProRes ? nil : 1_500_000
        let quality: Double? = codec.isProRes ? nil : nil
        let audioSettings: ExportAudioSettings?
        if let audioCodec, audioProvider != nil {
            audioSettings = try ExportAudioSettings(
                codec: audioCodec,
                sampleRate: project.settings.audioSampleRate,
                channelCount: 2,
                bitRate: audioCodec == .aac ? 128_000 : nil
            )
        } else {
            audioSettings = nil
        }
        return try ExportSettings(
            container: container,
            video: ExportVideoSettings(
                codec: codec,
                resolution: project.settings.resolution,
                frameRate: sequence.timebase,
                averageBitRate: averageBitRate,
                quality: quality,
                colorSpace: colorSpace
            ),
            audio: audioSettings
        )
    }

    /// Runs one movie export through the production `ExportSession` boundary.
    public func exportMovie(
        to destinationURL: URL,
        settings: ExportSettings,
        sourceSelectionPolicy: ExportSourceSelectionPolicy = .alwaysOriginal
    ) async throws -> (result: ExportResult, session: ExportSession) {
        let request = try ExportRequest(
            project: project,
            sequenceID: sequence.id,
            range: range,
            destinationURL: destinationURL,
            settings: settings
        )
        let frameProvider = try RenderGraphExportFrameProvider(
            project: project,
            sequence: sequence,
            videoSettings: settings.video,
            sourceProvider: SourceLessExportProvider()
        )
        let session = ExportSession(
            request: request,
            frameProvider: frameProvider,
            audioSourceProvider: audioProvider,
            sourceSelectionPolicy: sourceSelectionPolicy
        )
        let result = try await session.run()
        return (result, session)
    }

    /// Renders delivery-path BGRA expectations for every export frame (pre-encode reference).
    ///
    /// Uses the 8-bit BGRA delivery packing (same path as H.264 encoder input / still PNG).
    /// Movie under test may be ProRes; decoded frames are also 8-bit BGRA for comparison.
    ///
    /// **Canvas flatten:** title generators are transparent (ADR-0017 / smoke corner alpha).
    /// Non-alpha codecs (ProRes 422/HQ, H.264, HEVC) drop alpha on encode; `AVAssetReader`
    /// synthesizes `A=255` on decode. Expectations are therefore composited over **opaque
    /// black** (premultiplied RGB unchanged, alpha forced to 255) so golden compare matches
    /// the decoded movie appearance rather than the pre-encode alpha channel.
    public func renderExpectedBGRAFrames(
        resolution: PixelDimensions? = nil,
        colorSpace: ExportColorSpace? = nil
    ) async throws -> [ExportDecodedBGRAFrame] {
        let resolvedResolution = resolution ?? project.settings.resolution
        let resolvedColorSpace = colorSpace ?? self.colorSpace
        let expectationSettings = try ExportVideoSettings(
            codec: .h264,
            resolution: resolvedResolution,
            frameRate: sequence.timebase,
            averageBitRate: 1_000_000,
            colorSpace: resolvedColorSpace
        )
        let expectationProvider = try RenderGraphExportFrameProvider(
            project: project,
            sequence: sequence,
            videoSettings: expectationSettings,
            sourceProvider: SourceLessExportProvider()
        )
        var frames: [ExportDecodedBGRAFrame] = []
        frames.reserveCapacity(Int(frameCount))
        for index in 0..<frameCount {
            let timelineTime = try range.start.adding(
                sequence.timebase.duration(ofFrames: index)
            )
            let pixelBuffer = try Self.makeBGRAPixelBuffer(
                width: resolvedResolution.width,
                height: resolvedResolution.height
            )
            try await expectationProvider.renderFrame(at: timelineTime, into: pixelBuffer)
            let packed = try ExportMovieDecoder.packedBGRA8Frame(from: pixelBuffer)
            frames.append(packed.flattenedOverOpaqueBlack())
        }
        return frames
    }

    /// Exports a still PNG at the first export frame time via FR-EXP-004.
    public func exportStillPNG(to destinationURL: URL) async throws {
        let request = try StillFrameExportRequest(
            project: project,
            sequenceID: sequence.id,
            time: .zero,
            destinationURL: destinationURL,
            resolution: project.settings.resolution,
            colorSpace: colorSpace,
            format: .png
        )
        try await StillFrameExporter.export(
            request: request,
            sourceProvider: SourceLessExportProvider()
        )
    }

    /// Renders delivery BGRA at t=0 for bit-exact still comparison.
    public func renderStillExpectationBGRA() async throws -> ExportDecodedBGRAFrame {
        let request = try StillFrameExportRequest(
            project: project,
            sequenceID: sequence.id,
            time: .zero,
            destinationURL: directoryURL.appendingPathComponent("unused.png"),
            resolution: project.settings.resolution,
            colorSpace: colorSpace,
            format: .png
        )
        let buffer = try await StillFrameExporter.renderDeliveryBGRA(
            request: request,
            sourceProvider: SourceLessExportProvider()
        )
        return try ExportMovieDecoder.packedBGRA8Frame(from: buffer)
    }

    // MARK: - Construction

    private static func makeSequence(
        mediaID: UUID,
        frameRate: FrameRate,
        range: TimeRange,
        includeAudio: Bool
    ) throws -> Sequence {
        let title = TitleSource(boxes: [
            TitleTextBox(
                id: UUID(),
                text: "EXP7",
                origin: CanvasPoint(x: RationalValue(4), y: RationalValue(4)),
                width: RationalValue(56),
                height: RationalValue(24),
                style: TitleTextStyle(fontSize: RationalValue(14))
            )
        ])
        // timelineRange == export range [0, frameCount) so sample times 0…frameCount-1 inclusive
        // (half-open) all hit the static title — last-frame golden failures are not clip-end misses.
        let videoClip = Clip(
            id: UUID(),
            source: .title(title),
            sourceRange: range,
            timelineRange: range,
            kind: .video,
            name: "FR-EXP-007 title"
        )
        var audioTracks: [Track] = []
        if includeAudio {
            let audioClip = Clip(
                id: UUID(),
                source: .media(id: mediaID),
                sourceRange: range,
                timelineRange: range,
                kind: .audio,
                name: "FR-EXP-007 tone"
            )
            audioTracks = [
                Track(id: UUID(), kind: .audio, items: [.clip(audioClip)])
            ]
        }
        return Sequence(
            id: UUID(),
            name: "FR-EXP-007 export golden",
            videoTracks: [
                Track(id: UUID(), kind: .video, items: [.clip(videoClip)])
            ],
            audioTracks: audioTracks,
            markers: [],
            timebase: frameRate
        )
    }

    private static func makeProject(
        sequence: Sequence,
        mediaID: UUID,
        duration: RationalTime,
        settings: ProjectSettings,
        colorSpace: ExportColorSpace
    ) -> Project {
        let media = MediaRef(
            id: mediaID,
            sourceURL: nil,
            contentHash: nil,
            metadata: MediaMetadata(
                codecID: "pcm_f32le",
                pixelDimensions: nil,
                frameRate: nil,
                duration: duration,
                colorSpace: colorSpace.mediaColorSpace,
                audioChannelLayout: AudioChannelLayout(channelCount: 1),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: settings,
            mediaPool: [media],
            sequences: [sequence]
        )
    }

    private static func makeAudioProvider(
        mediaID: UUID,
        duration: RationalTime
    ) throws -> InMemoryAudioSourceProvider {
        let frameCount = Int(duration.seconds * 48_000)
        let samples = (0..<frameCount).map { frame in
            Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000) * 0.1)
        }
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 48_000, channelCount: 1),
            frameCount: frameCount,
            samples: samples
        )
        return InMemoryAudioSourceProvider(sources: [mediaID: source])
    }

    private static func makeBGRAPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw ExportError.pixelBufferCreationFailed(status)
        }
        return buffer
    }
}

/// Title-only graph source provider shared by export golden / smoke paths.
public final class SourceLessExportProvider: ExportRenderSourceProvider {
    /// Creates a provider that rejects media-backed source nodes.
    public init() {}

    /// Ensures the export graph has no media source nodes.
    public func prepare(graph: RenderGraph) async throws {
        if graph.nodes.contains(where: { node in
            if case .source = node.kind {
                return true
            }
            return false
        }) {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "export golden fixture unexpectedly referenced media sources"
            )
        }
    }

    /// Always fails — title graphs never request textures.
    public func texture(for _: RenderSourceNode) throws -> MTLTexture {
        throw ExportError.frameRenderFailed(
            frameIndex: 0,
            reason: "export golden fixture has no media textures"
        )
    }
}
