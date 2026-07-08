// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import Foundation

/// In-memory timelines for the realtime audio plan-build benchmarks.
///
/// Each fixture measures `RealtimeAudioRenderPlan.preparingCompoundMix` over the same
/// two-second look-ahead window the live coordinator publishes; the budget is the one-second
/// refill margin that remains once a refill triggers
/// (`BenchmarkBudget.realtimeAudioLookAheadRefill`).
struct BenchmarkRealtimeAudioPlanFixture {
    /// The 30 fps timebase shared by every plan-build fixture timeline.
    private static let timebaseFrames: Int64 = 30

    /// The look-ahead render window in timeline frames (two seconds at 30 fps).
    private static let windowFrames: Int64 = 60

    let project: Project
    let sequence: Sequence
    let range: TimeRange
    let sourceProvider: InMemoryAudioSourceProvider

    /// Retimed audio: one 2x varispeed clip, one 2x WSOLA pitch-corrected clip, and one 1/2x
    /// varispeed clip, each on its own track (FR-SPD-001, FR-SPD-005).
    static func retimedTimeline() throws -> BenchmarkRealtimeAudioPlanFixture {
        let frameRate = try FrameRate(frames: timebaseFrames)
        let media = try makeSineMedia(ordinal: 0, durationFrames: 120, frameRate: frameRate)
        let doubleSpeed = try RationalValue(numerator: 2, denominator: 1)
        let halfSpeed = try RationalValue(numerator: 1, denominator: 2)
        let clips = [
            try makeAudioClip(
                ordinal: 0,
                mediaID: media.ref.id,
                frameRate: frameRate,
                sourceFrames: 0..<120,
                timelineFrames: 0..<60,
                speed: doubleSpeed
            ),
            try makeAudioClip(
                ordinal: 1,
                mediaID: media.ref.id,
                frameRate: frameRate,
                sourceFrames: 0..<120,
                timelineFrames: 0..<60,
                speed: doubleSpeed,
                retimeMode: .pitchCorrected
            ),
            try makeAudioClip(
                ordinal: 2,
                mediaID: media.ref.id,
                frameRate: frameRate,
                sourceFrames: 0..<30,
                timelineFrames: 0..<60,
                speed: halfSpeed
            )
        ]
        let tracks = try clips.enumerated().map { index, clip in
            Track(id: try uuid(4_400 + index), kind: .audio, items: [.clip(clip)])
        }
        let sequence = Sequence(
            id: try uuid(4_410),
            name: "Benchmark RT Plan Retimed Audio",
            videoTracks: [],
            audioTracks: tracks,
            markers: [],
            timebase: frameRate
        )
        return try make(sequences: [sequence], media: [media], frameRate: frameRate)
    }

    /// A five-deep compound chain with one media-backed audio clip at every level, so the plan
    /// build recursively flattens nested sequences at depth four-plus (FR-AUD-007, issue #146).
    static func nestedCompoundTimeline() throws -> BenchmarkRealtimeAudioPlanFixture {
        let frameRate = try FrameRate(frames: timebaseFrames)
        let media = try makeSineMedia(
            ordinal: 1,
            durationFrames: windowFrames,
            frameRate: frameRate
        )
        let depth = 5
        var sequences: [Sequence] = []
        var deeperSequenceID: UUID?
        for level in stride(from: depth - 1, through: 0, by: -1) {
            let sequence = try makeNestedLevelSequence(
                level: level,
                deeperSequenceID: deeperSequenceID,
                mediaID: media.ref.id,
                frameRate: frameRate
            )
            deeperSequenceID = sequence.id
            sequences.insert(sequence, at: 0)
        }
        return try make(sequences: sequences, media: [media], frameRate: frameRate)
    }

    /// A wide flat timeline: sixteen audio tracks with four half-second clips each (FR-AUD-007).
    static func wideTimeline() throws -> BenchmarkRealtimeAudioPlanFixture {
        let frameRate = try FrameRate(frames: timebaseFrames)
        let media = try makeSineMedia(
            ordinal: 2,
            durationFrames: windowFrames,
            frameRate: frameRate
        )
        let tracks = try (0..<16).map { trackIndex in
            let clips = try (0..<4).map { clipIndex -> Clip in
                let start = Int64(clipIndex) * 15
                return try makeAudioClip(
                    ordinal: 100 + (trackIndex * 10) + clipIndex,
                    mediaID: media.ref.id,
                    frameRate: frameRate,
                    sourceFrames: start..<(start + 15),
                    timelineFrames: start..<(start + 15)
                )
            }
            return Track(
                id: try uuid(4_600 + trackIndex),
                kind: .audio,
                items: clips.map(TimelineItem.clip)
            )
        }
        let sequence = Sequence(
            id: try uuid(4_620),
            name: "Benchmark RT Plan Wide Timeline",
            videoTracks: [],
            audioTracks: tracks,
            markers: [],
            timebase: frameRate
        )
        return try make(sequences: [sequence], media: [media], frameRate: frameRate)
    }
}

private extension BenchmarkRealtimeAudioPlanFixture {
    struct SineMedia {
        let ref: MediaRef
        let buffer: AudioSourceBuffer
    }

    static func make(
        sequences: [Sequence],
        media: [SineMedia],
        frameRate: FrameRate
    ) throws -> BenchmarkRealtimeAudioPlanFixture {
        guard let mainSequence = sequences.first else {
            throw AjarCLIError.missingSequence
        }
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 64, height: 36),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: media.map(\.ref),
            sequences: sequences
        )
        return BenchmarkRealtimeAudioPlanFixture(
            project: project,
            sequence: mainSequence,
            range: try TimeRange(
                start: .zero,
                duration: frameRate.duration(ofFrames: windowFrames)
            ),
            sourceProvider: InMemoryAudioSourceProvider(
                sources: Dictionary(
                    uniqueKeysWithValues: media.map { ($0.ref.id, $0.buffer) }
                )
            )
        )
    }

    /// One level of the nested chain: an audio clip plus, above the deepest level, a
    /// video-track compound clip wrapping the next-deeper sequence.
    static func makeNestedLevelSequence(
        level: Int,
        deeperSequenceID: UUID?,
        mediaID: UUID,
        frameRate: FrameRate
    ) throws -> Sequence {
        var videoTracks: [Track] = []
        if let deeperSequenceID {
            let compoundClip = Clip(
                id: try uuid(4_500 + (level * 10)),
                source: .sequence(id: deeperSequenceID),
                sourceRange: try frameRange(0..<windowFrames, frameRate: frameRate),
                timelineRange: try frameRange(0..<windowFrames, frameRate: frameRate),
                kind: .video,
                name: "Benchmark RT Plan Compound Level \(level)"
            )
            videoTracks.append(
                Track(id: try uuid(4_520 + level), kind: .video, items: [.clip(compoundClip)])
            )
        }
        let audioClip = try makeAudioClip(
            ordinal: 300 + level,
            mediaID: mediaID,
            frameRate: frameRate,
            sourceFrames: 0..<windowFrames,
            timelineFrames: 0..<windowFrames
        )
        return Sequence(
            id: try uuid(4_540 + level),
            name: "Benchmark RT Plan Nested Level \(level)",
            videoTracks: videoTracks,
            audioTracks: [
                Track(id: try uuid(4_560 + level), kind: .audio, items: [.clip(audioClip)])
            ],
            markers: [],
            timebase: frameRate
        )
    }

    static func makeAudioClip(
        ordinal: Int,
        mediaID: UUID,
        frameRate: FrameRate,
        sourceFrames: Range<Int64>,
        timelineFrames: Range<Int64>,
        speed: RationalValue = .one,
        retimeMode: ClipAudioRetimeMode = .pitchShifted
    ) throws -> Clip {
        Clip(
            id: try uuid(4_700 + ordinal),
            source: .media(id: mediaID),
            sourceRange: try frameRange(sourceFrames, frameRate: frameRate),
            timelineRange: try frameRange(timelineFrames, frameRate: frameRate),
            kind: .audio,
            name: "Benchmark RT Plan Clip \(ordinal)",
            audioMix: ClipAudioMix(retimeMode: retimeMode),
            speed: speed
        )
    }

    static func makeSineMedia(
        ordinal: Int,
        durationFrames: Int64,
        frameRate: FrameRate
    ) throws -> SineMedia {
        let sampleRate = 48_000
        let channelCount = 2
        let duration = try frameRate.duration(ofFrames: durationFrames)
        let sampleFrames = Int(try duration.value(atTimescale: Int64(sampleRate)))
        var samples: [Float] = []
        samples.reserveCapacity(sampleFrames * channelCount)
        for frame in 0..<sampleFrames {
            let phase = 2.0 * Double.pi * 440.0 * Double(frame) / Double(sampleRate)
            let sample = Float(sin(phase) * 0.1)
            for _ in 0..<channelCount {
                samples.append(sample)
            }
        }

        let ref = MediaRef(
            id: try uuid(4_300 + ordinal),
            sourceURL: URL(fileURLWithPath: "/benchmark/rt-plan-sine-\(ordinal).wav"),
            contentHash: ContentHash.sha256(data: Data("rt-plan-sine-\(ordinal)".utf8)),
            metadata: MediaMetadata(
                codecID: "pcm_f32le",
                pixelDimensions: nil,
                frameRate: nil,
                duration: duration,
                colorSpace: .unspecified,
                audioChannelLayout: AudioChannelLayout(channelCount: channelCount),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        return SineMedia(
            ref: ref,
            buffer: try AudioSourceBuffer(
                format: AudioRenderFormat(sampleRate: sampleRate, channelCount: channelCount),
                frameCount: sampleFrames,
                samples: samples
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
            throw AjarCLIError.benchmarkFailed("invalid audio plan benchmark UUID \(number)")
        }
        return uuid
    }
}
