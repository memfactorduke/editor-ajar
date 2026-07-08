// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Synthetic retimed timelines for the FR-SPD-005 playback benchmarks.
///
/// Every case runs a 30 fps timeline over one generated 60-frame synthetic movie, so each
/// rendered frame is asserted against the same playback budget: one frame interval at the
/// timeline target rate (`BenchmarkBudget.playbackFrameAt30fps`).
struct BenchmarkRetimedPlaybackFixture {
    /// One FR-SPD-005 retime scenario.
    enum RetimeCase {
        /// Constant 2x fast motion.
        case constant2x

        /// Constant 1/2x slow motion with nearest frame sampling.
        case constantHalf

        /// A 1x-to-4x FR-SPD-002 time-remap ramp, rendered inside the 4x segment.
        case timeRemapRamp

        /// Reverse playback (FR-SPD-003).
        case reverse

        /// Freeze frame hold (FR-SPD-003).
        case freezeFrame

        /// Constant 1/2x slow motion with FR-SPD-004 frame blending at a fractional position.
        case frameBlendHalf

        /// A retimed compound clip nesting a retimed compound clip over retimed media.
        case nestedCompound
    }

    let project: Project
    let sequence: Sequence
    let renderTime: RationalTime
    private let generatedDirectory: URL

    init(retimeCase: RetimeCase) throws {
        let frameRate = try FrameRate(frames: 30)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-retime-benchmarks")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        generatedDirectory = directory

        let movieSpec = SyntheticMovieSpec(
            width: 64,
            height: 36,
            frameCount: 60,
            frameRate: Int32(frameRate.frames),
            bgra: [32, 96, 160, 255]
        )
        let mediaURL = directory.appendingPathComponent("retime-benchmark-source.mov")
        try SyntheticMovieWriter.writeMovie(to: mediaURL, spec: movieSpec)
        let media = try Self.makeMedia(url: mediaURL, spec: movieSpec, frameRate: frameRate)

        let build = try Self.makeSequences(
            retimeCase: retimeCase,
            mediaID: media.id,
            frameRate: frameRate
        )
        guard let mainSequence = build.sequences.first else {
            throw AjarCLIError.missingSequence
        }
        sequence = mainSequence
        renderTime = try RationalTime.atFrame(build.renderFrame, frameRate: frameRate)
        project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: movieSpec.width, height: movieSpec.height),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [media],
            sequences: build.sequences
        )
    }

    func removeGeneratedFiles() {
        try? FileManager.default.removeItem(at: generatedDirectory)
    }
}

private extension BenchmarkRetimedPlaybackFixture {
    struct SequenceBuild {
        /// The benchmarked sequence first, then any nested sequences it references.
        let sequences: [Sequence]
        let renderFrame: Int64
    }

    static func makeSequences(
        retimeCase: RetimeCase,
        mediaID: UUID,
        frameRate: FrameRate
    ) throws -> SequenceBuild {
        switch retimeCase {
        case .constant2x:
            try makeConstantSpeedBuild(
                name: "Benchmark Retimed Constant 2x",
                mediaID: mediaID,
                frameRate: frameRate,
                timelineFrames: 0..<30,
                renderFrame: 15,
                speed: try RationalValue(numerator: 2, denominator: 1)
            )
        case .constantHalf:
            try makeConstantSpeedBuild(
                name: "Benchmark Retimed Constant Half Speed",
                mediaID: mediaID,
                frameRate: frameRate,
                timelineFrames: 0..<120,
                renderFrame: 30,
                speed: try RationalValue(numerator: 1, denominator: 2)
            )
        case .timeRemapRamp:
            try makeTimeRemapRampBuild(mediaID: mediaID, frameRate: frameRate)
        case .reverse:
            try makeReverseBuild(mediaID: mediaID, frameRate: frameRate)
        case .freezeFrame:
            try makeFreezeFrameBuild(mediaID: mediaID, frameRate: frameRate)
        case .frameBlendHalf:
            try makeConstantSpeedBuild(
                name: "Benchmark Retimed Frame Blend Half Speed",
                mediaID: mediaID,
                frameRate: frameRate,
                timelineFrames: 0..<120,
                renderFrame: 31,
                speed: try RationalValue(numerator: 1, denominator: 2),
                frameSampling: .frameBlend
            )
        case .nestedCompound:
            try makeNestedCompoundBuild(mediaID: mediaID, frameRate: frameRate)
        }
    }

    static func makeConstantSpeedBuild(
        name: String,
        mediaID: UUID,
        frameRate: FrameRate,
        timelineFrames: Range<Int64>,
        renderFrame: Int64,
        speed: RationalValue = .one,
        frameSampling: ClipFrameSamplingMode = .nearest
    ) throws -> SequenceBuild {
        let clip = try makeMediaClip(
            ordinal: 0,
            mediaID: mediaID,
            frameRate: frameRate,
            sourceFrames: 0..<60,
            timelineFrames: timelineFrames,
            speed: speed,
            frameSampling: frameSampling
        )
        return SequenceBuild(
            sequences: [try makeSingleClipSequence(name: name, clip: clip, frameRate: frameRate)],
            renderFrame: renderFrame
        )
    }

    static func makeReverseBuild(mediaID: UUID, frameRate: FrameRate) throws -> SequenceBuild {
        let clip = try makeMediaClip(
            ordinal: 0,
            mediaID: mediaID,
            frameRate: frameRate,
            sourceFrames: 0..<60,
            timelineFrames: 0..<60,
            reverse: true
        )
        let sequence = try makeSingleClipSequence(
            name: "Benchmark Retimed Reverse",
            clip: clip,
            frameRate: frameRate
        )
        return SequenceBuild(sequences: [sequence], renderFrame: 15)
    }

    static func makeFreezeFrameBuild(mediaID: UUID, frameRate: FrameRate) throws -> SequenceBuild {
        let clip = try makeMediaClip(
            ordinal: 0,
            mediaID: mediaID,
            frameRate: frameRate,
            sourceFrames: 20..<50,
            timelineFrames: 0..<60,
            freezeFrame: true
        )
        let sequence = try makeSingleClipSequence(
            name: "Benchmark Retimed Freeze Frame",
            clip: clip,
            frameRate: frameRate
        )
        return SequenceBuild(sequences: [sequence], renderFrame: 30)
    }

    /// Two linear segments: unit slope over frames 0..<12, then slope four up to the exclusive
    /// source end at frame 60. Rendering frame 18 lands mid-ramp inside the 4x segment.
    static func makeTimeRemapRampBuild(
        mediaID: UUID,
        frameRate: FrameRate
    ) throws -> SequenceBuild {
        let remap = try ClipTimeRemap(
            keyframes: [
                TimeRemapKeyframe(time: .zero, sourceTime: .zero),
                TimeRemapKeyframe(
                    time: try RationalTime.atFrame(12, frameRate: frameRate),
                    sourceTime: try RationalTime.atFrame(12, frameRate: frameRate)
                ),
                TimeRemapKeyframe(
                    time: try RationalTime.atFrame(24, frameRate: frameRate),
                    sourceTime: try RationalTime.atFrame(60, frameRate: frameRate)
                )
            ]
        )
        let sequence = try makeSingleClipSequence(
            name: "Benchmark Retimed Time-Remap Ramp",
            clip: try makeMediaClip(
                ordinal: 0,
                mediaID: mediaID,
                frameRate: frameRate,
                sourceFrames: 0..<60,
                timelineFrames: 0..<24,
                timeRemap: remap
            ),
            frameRate: frameRate
        )
        return SequenceBuild(sequences: [sequence], renderFrame: 18)
    }

    /// Outer 2x compound -> mid sequence (1/2x compound over a 2x inner clip, plus a reversed
    /// media layer) -> inner 2x media clip.
    static func makeNestedCompoundBuild(
        mediaID: UUID,
        frameRate: FrameRate
    ) throws -> SequenceBuild {
        let inner = try makeNestedInnerSequence(mediaID: mediaID, frameRate: frameRate)
        let mid = try makeNestedMidSequence(
            innerSequenceID: inner.id,
            mediaID: mediaID,
            frameRate: frameRate
        )
        let outer = try makeSingleClipSequence(
            name: "Benchmark Retimed Nested Compound",
            clip: try makeCompoundClip(
                ordinal: 13,
                sequenceID: mid.id,
                frameRate: frameRate,
                sourceFrames: 0..<60,
                timelineFrames: 0..<30,
                speed: try RationalValue(numerator: 2, denominator: 1)
            ),
            frameRate: frameRate
        )
        return SequenceBuild(sequences: [outer, mid, inner], renderFrame: 15)
    }

    static func makeNestedInnerSequence(
        mediaID: UUID,
        frameRate: FrameRate
    ) throws -> Sequence {
        let clip = try makeMediaClip(
            ordinal: 10,
            mediaID: mediaID,
            frameRate: frameRate,
            sourceFrames: 0..<60,
            timelineFrames: 0..<30,
            speed: try RationalValue(numerator: 2, denominator: 1)
        )
        return Sequence(
            id: try uuid(4_240),
            name: "Benchmark Retimed Nested Inner",
            videoTracks: [Track(id: try uuid(4_250), kind: .video, items: [.clip(clip)])],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
    }

    static func makeNestedMidSequence(
        innerSequenceID: UUID,
        mediaID: UUID,
        frameRate: FrameRate
    ) throws -> Sequence {
        let compoundClip = try makeCompoundClip(
            ordinal: 11,
            sequenceID: innerSequenceID,
            frameRate: frameRate,
            sourceFrames: 0..<30,
            timelineFrames: 0..<60,
            speed: try RationalValue(numerator: 1, denominator: 2)
        )
        let reversedClip = try makeMediaClip(
            ordinal: 12,
            mediaID: mediaID,
            frameRate: frameRate,
            sourceFrames: 0..<60,
            timelineFrames: 0..<60,
            reverse: true
        )
        return Sequence(
            id: try uuid(4_241),
            name: "Benchmark Retimed Nested Mid",
            videoTracks: [
                Track(id: try uuid(4_251), kind: .video, items: [.clip(compoundClip)]),
                Track(id: try uuid(4_252), kind: .video, items: [.clip(reversedClip)])
            ],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
    }

    static func makeSingleClipSequence(
        name: String,
        clip: Clip,
        frameRate: FrameRate
    ) throws -> Sequence {
        Sequence(
            id: try uuid(4_200),
            name: name,
            videoTracks: [Track(id: try uuid(4_210), kind: .video, items: [.clip(clip)])],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
    }

    static func makeMediaClip(
        ordinal: Int,
        mediaID: UUID,
        frameRate: FrameRate,
        sourceFrames: Range<Int64>,
        timelineFrames: Range<Int64>,
        speed: RationalValue = .one,
        reverse: Bool = false,
        freezeFrame: Bool = false,
        timeRemap: ClipTimeRemap? = nil,
        frameSampling: ClipFrameSamplingMode = .nearest
    ) throws -> Clip {
        Clip(
            id: try uuid(4_100 + ordinal),
            source: .media(id: mediaID),
            sourceRange: try frameRange(sourceFrames, frameRate: frameRate),
            timelineRange: try frameRange(timelineFrames, frameRate: frameRate),
            kind: .video,
            name: "Benchmark Retimed Clip \(ordinal)",
            speed: speed,
            reverse: reverse,
            freezeFrame: freezeFrame,
            timeRemap: timeRemap,
            frameSampling: frameSampling
        )
    }

    static func makeCompoundClip(
        ordinal: Int,
        sequenceID: UUID,
        frameRate: FrameRate,
        sourceFrames: Range<Int64>,
        timelineFrames: Range<Int64>,
        speed: RationalValue = .one
    ) throws -> Clip {
        Clip(
            id: try uuid(4_100 + ordinal),
            source: .sequence(id: sequenceID),
            sourceRange: try frameRange(sourceFrames, frameRate: frameRate),
            timelineRange: try frameRange(timelineFrames, frameRate: frameRate),
            kind: .video,
            name: "Benchmark Retimed Compound \(ordinal)",
            speed: speed
        )
    }

    static func makeMedia(
        url: URL,
        spec: SyntheticMovieSpec,
        frameRate: FrameRate
    ) throws -> MediaRef {
        MediaRef(
            id: try uuid(4_000),
            sourceURL: url,
            contentHash: ContentHash.sha256(data: Data("retime-benchmark-synthetic".utf8)),
            metadata: MediaMetadata(
                codecID: "prores4444",
                pixelDimensions: PixelDimensions(width: spec.width, height: spec.height),
                frameRate: frameRate,
                duration: try frameRate.duration(ofFrames: Int64(spec.frameCount)),
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
    }

    static func frameRange(_ frames: Range<Int64>, frameRate: FrameRate) throws -> TimeRange {
        try TimeRange(
            start: RationalTime.atFrame(frames.lowerBound, frameRate: frameRate),
            duration: frameRate.duration(ofFrames: frames.upperBound - frames.lowerBound)
        )
    }

    static func uuid(_ number: Int) throws -> UUID {
        let suffix = String(format: "%012d", number)
        guard let uuid = UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") else {
            throw AjarCLIError.benchmarkFailed("invalid retime benchmark UUID \(number)")
        }
        return uuid
    }
}
