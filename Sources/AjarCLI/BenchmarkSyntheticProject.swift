// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

enum BenchmarkSyntheticProject {
    static let multiLayerSequenceName = "Benchmark Multi-Layer Transform Sequence"

    static func write(to directory: URL) throws -> URL {
        let frameRate = try FrameRate(frames: 30)
        let clipCount = 50
        let frameCount = 60
        let movieSpec = SyntheticMovieSpec(
            width: 64,
            height: 36,
            frameCount: frameCount,
            frameRate: Int32(frameRate.frames),
            bgra: [32, 64, 192, 255]
        )
        let mediaURL = directory.appendingPathComponent("benchmark-source.mov")
        try SyntheticMovieWriter.writeMovie(to: mediaURL, spec: movieSpec)

        let project = try makeProject(
            mediaURL: mediaURL,
            movieSpec: movieSpec,
            frameRate: frameRate,
            clipCount: clipCount
        )
        let projectURL = directory.appendingPathComponent("benchmark.ajar")
        try ProjectPackageIO.writeProject(project, to: projectURL)
        return projectURL
    }

    private static func makeProject(
        mediaURL: URL,
        movieSpec: SyntheticMovieSpec,
        frameRate: FrameRate,
        clipCount: Int
    ) throws -> Project {
        let mediaID = try uuid("00000000-0000-0000-0000-000000002600")
        let mediaDuration = try frameRate.duration(ofFrames: Int64(movieSpec.frameCount))
        let media = MediaRef(
            id: mediaID,
            sourceURL: mediaURL,
            contentHash: ContentHash.sha256(data: Data("benchmark-synthetic".utf8)),
            metadata: MediaMetadata(
                codecID: "prores4444",
                pixelDimensions: PixelDimensions(width: movieSpec.width, height: movieSpec.height),
                frameRate: frameRate,
                duration: mediaDuration,
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )

        let clips = try (0..<clipCount).map { index in
            try makeClip(index: index, mediaID: mediaID, frameRate: frameRate)
        }
        let sequence = Sequence(
            id: try uuid("00000000-0000-0000-0000-000000002601"),
            name: "Benchmark 50 Clip Sequence",
            videoTracks: [
                Track(
                    id: try uuid("00000000-0000-0000-0000-000000002602"),
                    kind: .video,
                    items: clips.map(TimelineItem.clip)
                )
            ],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        let multiLayerSequence = try makeMultiLayerSequence(
            mediaID: mediaID,
            frameRate: frameRate,
            duration: mediaDuration
        )

        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: movieSpec.width, height: movieSpec.height),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [media],
            sequences: [sequence, multiLayerSequence]
        )
    }

    private static func makeMultiLayerSequence(
        mediaID: UUID,
        frameRate: FrameRate,
        duration: RationalTime
    ) throws -> Sequence {
        let tracks = try (0..<4).map { index in
            Track(
                id: try uuid(String(format: "00000000-0000-0000-0000-000000%06d", 2_900 + index)),
                kind: .video,
                items: [
                    .clip(
                        try makeLayeredClip(
                            index: index,
                            mediaID: mediaID,
                            frameRate: frameRate,
                            duration: duration
                        )
                    )
                ]
            )
        }
        return Sequence(
            id: try uuid("00000000-0000-0000-0000-000000002899"),
            name: multiLayerSequenceName,
            videoTracks: tracks,
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
    }

    private static func makeLayeredClip(
        index: Int,
        mediaID: UUID,
        frameRate: FrameRate,
        duration: RationalTime
    ) throws -> Clip {
        Clip(
            id: try uuid(String(format: "00000000-0000-0000-0000-000000%06d", 2_950 + index)),
            source: .media(id: mediaID),
            sourceRange: try TimeRange(start: .zero, duration: duration),
            timelineRange: try TimeRange(start: .zero, duration: duration),
            kind: .video,
            name: "Benchmark Transform Layer \(index)",
            transformAnimation: try makeTransformAnimation(index: index, frameRate: frameRate)
        )
    }

    private static func makeTransformAnimation(
        index: Int,
        frameRate: FrameRate
    ) throws -> AnimatableClipTransform {
        let start = try RationalTime.atFrame(0, frameRate: frameRate)
        let end = try RationalTime.atFrame(59, frameRate: frameRate)
        return try AnimatableClipTransform(
            position: Animatable(
                base: .zero,
                keyframes: [
                    Keyframe(
                        time: start,
                        value: CanvasPoint(x: RationalValue(Int64(index * 2)), y: .zero),
                        interpolation: .easeInOut
                    ),
                    Keyframe(
                        time: end,
                        value: CanvasPoint(x: RationalValue(Int64(index * 4)), y: RationalValue(2)),
                        interpolation: .hold
                    )
                ]
            ),
            opacity: .constant(try RationalValue(numerator: Int64(4 - index), denominator: 4)),
            blendMode: index == 0 ? .normal : .screen
        )
    }

    private static func makeClip(
        index: Int,
        mediaID: UUID,
        frameRate: FrameRate
    ) throws -> Clip {
        let start = try RationalTime.atFrame(Int64(index), frameRate: frameRate)
        let duration = try frameRate.duration(ofFrames: 1)
        return Clip(
            id: try uuid(String(format: "00000000-0000-0000-0000-000000%06d", 2_700 + index)),
            source: .media(id: mediaID),
            sourceRange: try TimeRange(start: start, duration: duration),
            timelineRange: try TimeRange(start: start, duration: duration),
            kind: .video,
            name: "Benchmark Clip \(index)"
        )
    }

    private static func uuid(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw AjarCLIError.benchmarkFailed("invalid benchmark UUID \(value)")
        }
        return uuid
    }
}
