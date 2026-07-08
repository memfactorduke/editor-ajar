// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import Foundation

/// One synthetic project variant plus the stable IDs the soak edit script addresses.
struct SoakProjectFixture {
    let project: Project
    let sequenceID: UUID
    let videoTrackID: UUID
    let compoundTrackID: UUID
    let audioTrackID: UUID
    let videoClipIDs: [UUID]
    let outgoingAudioClipID: UUID
    let incomingAudioClipID: UUID
    let videoMediaID: UUID
    let audioMediaID: UUID
}

/// Deterministic synthetic projects cycled by `ajar soak` (NFR-STAB-005).
///
/// Each variant shares one tiny synthetic movie and one synthetic audio tone but shifts clip
/// source offsets and nesting, so cycling variants churns every content-hash keyed cache
/// (executor RAM tier, disk tier, compound audio source cache) instead of replaying one graph.
enum SoakSyntheticProject {
    /// Number of project variants the soak cycles through.
    static let variantCount = 3

    /// Timeline and media frame rate for all soak fixtures.
    static func frameRate() throws -> FrameRate {
        try FrameRate(frames: 24)
    }

    /// Frame count of the shared synthetic movie.
    static let movieFrameCount = 48

    /// Movie/render dimensions kept tiny so soak iterations stay fast.
    static let pixelDimensions = PixelDimensions(width: 32, height: 18)

    /// Writes the shared synthetic movie used by every variant's video clips.
    static func writeSourceMovie(to url: URL) throws {
        try SyntheticMovieWriter.writeMovie(
            to: url,
            spec: SyntheticMovieSpec(
                width: pixelDimensions.width,
                height: pixelDimensions.height,
                frameCount: movieFrameCount,
                frameRate: 24,
                bgra: [40, 96, 200, 255]
            )
        )
    }

    /// Builds the shared 2.5-second stereo sine source for the audio media.
    static func makeAudioSource() throws -> AudioSourceBuffer {
        let format = AudioRenderFormat(sampleRate: 48_000, channelCount: 2)
        let frameCount = format.sampleRate * 5 / 2
        var samples = [Float](repeating: 0, count: frameCount * format.channelCount)
        for frame in 0..<frameCount {
            let phase = Double(frame) * 440.0 / Double(format.sampleRate)
            let value = Float(0.25 * sin(2.0 * Double.pi * phase))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        return try AudioSourceBuffer(format: format, frameCount: frameCount, samples: samples)
    }

    /// Builds project variant `variant` (0-based) referencing the shared movie at `movieURL`.
    static func makeFixture(variant: Int, movieURL: URL) throws -> SoakProjectFixture {
        let timebase = try frameRate()
        let ids = try SoakFixtureIDs(variant: variant)
        let audioClips = try makeAudioClipPair(
            variant: variant,
            audioMediaID: ids.audioMediaID,
            timebase: timebase
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: timebase,
                resolution: pixelDimensions,
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [
                try makeVideoMedia(id: ids.videoMediaID, movieURL: movieURL, timebase: timebase),
                try makeAudioMedia(id: ids.audioMediaID, timebase: timebase)
            ],
            sequences: [
                try makeMainSequence(
                    variant: variant,
                    ids: ids,
                    audioClips: audioClips,
                    timebase: timebase
                ),
                try makeNestedSequence(variant: variant, ids: ids, timebase: timebase)
            ]
        )
        return SoakProjectFixture(
            project: project,
            sequenceID: ids.sequenceID,
            videoTrackID: ids.videoTrackID,
            compoundTrackID: ids.compoundTrackID,
            audioTrackID: ids.audioTrackID,
            videoClipIDs: ids.videoClipIDs,
            outgoingAudioClipID: audioClips[0].id,
            incomingAudioClipID: audioClips[1].id,
            videoMediaID: ids.videoMediaID,
            audioMediaID: ids.audioMediaID
        )
    }

    private static func makeMainSequence(
        variant: Int,
        ids: SoakFixtureIDs,
        audioClips: [Clip],
        timebase: FrameRate
    ) throws -> Sequence {
        let videoClips = try (0..<4).map { index in
            try makeMovieClip(
                id: ids.videoClipIDs[index],
                mediaID: ids.videoMediaID,
                timelineStartFrame: Int64(index) * 8,
                sourceStartFrame: Int64(index) * 8 + Int64(variant) * 2,
                timebase: timebase
            )
        }
        let compoundClip = Clip(
            id: try soakUUID(variant: variant, item: 8),
            source: .sequence(id: ids.nestedSequenceID),
            sourceRange: try frameRange(start: 0, duration: 8, timebase: timebase),
            timelineRange: try frameRange(start: 0, duration: 8, timebase: timebase),
            kind: .video,
            name: "Soak compound \(variant)"
        )
        return Sequence(
            id: ids.sequenceID,
            name: "Soak timeline \(variant)",
            videoTracks: [
                Track(
                    id: ids.videoTrackID,
                    kind: .video,
                    items: videoClips.map(TimelineItem.clip)
                ),
                Track(id: ids.compoundTrackID, kind: .video, items: [.clip(compoundClip)])
            ],
            audioTracks: [
                Track(
                    id: ids.audioTrackID,
                    kind: .audio,
                    items: audioClips.map(TimelineItem.clip)
                )
            ],
            markers: [],
            timebase: timebase
        )
    }

    private static func makeNestedSequence(
        variant: Int,
        ids: SoakFixtureIDs,
        timebase: FrameRate
    ) throws -> Sequence {
        let nestedVideoClip = try makeMovieClip(
            id: try soakUUID(variant: variant, item: 20),
            mediaID: ids.videoMediaID,
            timelineStartFrame: 0,
            sourceStartFrame: Int64(variant) * 2,
            timebase: timebase
        )
        let nestedAudioClip = Clip(
            id: try soakUUID(variant: variant, item: 21),
            source: .media(id: ids.audioMediaID),
            sourceRange: try frameRange(start: 8, duration: 8, timebase: timebase),
            timelineRange: try frameRange(start: 0, duration: 8, timebase: timebase),
            kind: .audio,
            name: "Soak nested audio \(variant)"
        )
        return Sequence(
            id: ids.nestedSequenceID,
            name: "Soak nested \(variant)",
            videoTracks: [
                Track(
                    id: try soakUUID(variant: variant, item: 22),
                    kind: .video,
                    items: [.clip(nestedVideoClip)]
                )
            ],
            audioTracks: [
                Track(
                    id: try soakUUID(variant: variant, item: 23),
                    kind: .audio,
                    items: [.clip(nestedAudioClip)]
                )
            ],
            markers: [],
            timebase: timebase
        )
    }

    private static func makeAudioClipPair(
        variant: Int,
        audioMediaID: UUID,
        timebase: FrameRate
    ) throws -> [Clip] {
        let outgoing = Clip(
            id: try soakUUID(variant: variant, item: 30),
            source: .media(id: audioMediaID),
            sourceRange: try frameRange(start: 0, duration: 10, timebase: timebase),
            timelineRange: try frameRange(start: 0, duration: 10, timebase: timebase),
            kind: .audio,
            name: "Soak audio out \(variant)"
        )
        let incoming = Clip(
            id: try soakUUID(variant: variant, item: 31),
            source: .media(id: audioMediaID),
            sourceRange: try frameRange(start: 30, duration: 10, timebase: timebase),
            timelineRange: try frameRange(start: 10, duration: 10, timebase: timebase),
            kind: .audio,
            name: "Soak audio in \(variant)"
        )
        return [outgoing, incoming]
    }

    private static func makeMovieClip(
        id: UUID,
        mediaID: UUID,
        timelineStartFrame: Int64,
        sourceStartFrame: Int64,
        timebase: FrameRate
    ) throws -> Clip {
        Clip(
            id: id,
            source: .media(id: mediaID),
            sourceRange: try frameRange(start: sourceStartFrame, duration: 8, timebase: timebase),
            timelineRange: try frameRange(
                start: timelineStartFrame,
                duration: 8,
                timebase: timebase
            ),
            kind: .video,
            name: "Soak clip \(id.uuidString.prefix(8))"
        )
    }

    private static func makeVideoMedia(
        id: UUID,
        movieURL: URL,
        timebase: FrameRate
    ) throws -> MediaRef {
        MediaRef(
            id: id,
            sourceURL: movieURL,
            contentHash: ContentHash.sha256(data: Data("soak-video".utf8)),
            metadata: MediaMetadata(
                codecID: "prores4444",
                pixelDimensions: pixelDimensions,
                frameRate: timebase,
                duration: try timebase.duration(ofFrames: Int64(movieFrameCount)),
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
    }

    private static func makeAudioMedia(id: UUID, timebase: FrameRate) throws -> MediaRef {
        MediaRef(
            id: id,
            sourceURL: nil,
            contentHash: ContentHash.sha256(data: Data("soak-audio".utf8)),
            metadata: MediaMetadata(
                codecID: "pcm_f32le",
                pixelDimensions: nil,
                frameRate: nil,
                duration: try timebase.duration(ofFrames: 60),
                colorSpace: .rec709,
                audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
    }

    private static func frameRange(
        start: Int64,
        duration: Int64,
        timebase: FrameRate
    ) throws -> TimeRange {
        try TimeRange(
            start: RationalTime.atFrame(start, frameRate: timebase),
            duration: timebase.duration(ofFrames: duration)
        )
    }

    fileprivate static func soakUUID(variant: Int, item: Int) throws -> UUID {
        let value = String(format: "00000000-0000-0000-00%02d-0000000060%02d", variant, item)
        guard let uuid = UUID(uuidString: value) else {
            throw AjarCLIError.invalidUsage("invalid soak fixture UUID \(value)")
        }
        return uuid
    }
}

/// Deterministic per-variant IDs for the entities the soak fixture is built from.
private struct SoakFixtureIDs {
    let videoMediaID: UUID
    let audioMediaID: UUID
    let sequenceID: UUID
    let nestedSequenceID: UUID
    let videoTrackID: UUID
    let compoundTrackID: UUID
    let audioTrackID: UUID
    let videoClipIDs: [UUID]

    init(variant: Int) throws {
        videoMediaID = try SoakSyntheticProject.soakUUID(variant: variant, item: 1)
        audioMediaID = try SoakSyntheticProject.soakUUID(variant: variant, item: 2)
        sequenceID = try SoakSyntheticProject.soakUUID(variant: variant, item: 3)
        nestedSequenceID = try SoakSyntheticProject.soakUUID(variant: variant, item: 4)
        videoTrackID = try SoakSyntheticProject.soakUUID(variant: variant, item: 5)
        compoundTrackID = try SoakSyntheticProject.soakUUID(variant: variant, item: 6)
        audioTrackID = try SoakSyntheticProject.soakUUID(variant: variant, item: 7)
        videoClipIDs = try (0..<4).map {
            try SoakSyntheticProject.soakUUID(variant: variant, item: 10 + $0)
        }
    }
}
