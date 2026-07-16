// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
class MuxedMediaPlacementTestCase: XCTestCase {
    struct Fixture {
        let project: Project
        let muxedMediaID: UUID
        let videoOnlyMediaID: UUID
        let audioOnlyMediaID: UUID
    }

    var frameRate: FrameRate {
        get throws { try FrameRate(frames: 30) }
    }

    func makeFixture(
        videoItems: [TimelineItem],
        audioItems: [TimelineItem],
        videoLocked: Bool = false,
        audioLocked: Bool = false,
        includeAudioTrack: Bool = true,
        additionalVideoTracks: [Track] = [],
        additionalAudioTracks: [Track] = []
    ) throws -> Fixture {
        let muxed = try media(name: "muxed", duration: 5, video: true, audio: true)
        let videoOnly = try media(
            name: "video-only",
            duration: 5,
            video: true,
            audio: false
        )
        let audioOnly = try media(
            name: "audio-only",
            duration: 5,
            video: false,
            audio: true
        )
        let original = try media(
            id: Self.originalMediaID,
            name: "original",
            duration: 120,
            video: true,
            audio: true
        )
        let sequence = try makeSequence(
            videoItems: videoItems,
            audioItems: audioItems,
            videoLocked: videoLocked,
            audioLocked: audioLocked,
            includeAudioTrack: includeAudioTrack,
            additionalVideoTracks: additionalVideoTracks,
            additionalAudioTracks: additionalAudioTracks
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: try frameRate,
                resolution: PixelDimensions(width: 1_920, height: 1_080),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [muxed, videoOnly, audioOnly, original],
            sequences: [sequence]
        )
        return Fixture(
            project: project,
            muxedMediaID: muxed.id,
            videoOnlyMediaID: videoOnly.id,
            audioOnlyMediaID: audioOnly.id
        )
    }

    private func makeSequence(
        videoItems: [TimelineItem],
        audioItems: [TimelineItem],
        videoLocked: Bool,
        audioLocked: Bool,
        includeAudioTrack: Bool,
        additionalVideoTracks: [Track],
        additionalAudioTracks: [Track]
    ) throws -> Sequence {
        Sequence(
            id: UUID(),
            name: "Muxed placement",
            videoTracks: [
                Track(
                    id: UUID(),
                    kind: .video,
                    items: videoItems,
                    locked: videoLocked
                )
            ] + additionalVideoTracks,
            audioTracks: includeAudioTrack
                ? [
                    Track(
                        id: UUID(),
                        kind: .audio,
                        items: audioItems,
                        locked: audioLocked
                    )
                ] + additionalAudioTracks
                : additionalAudioTracks,
            markers: [],
            timebase: try frameRate
        )
    }

    func media(
        id: UUID = UUID(),
        name: String,
        duration: Int64,
        video: Bool,
        audio: Bool
    ) throws -> MediaRef {
        MediaRef(
            id: id,
            sourceURL: URL(fileURLWithPath: "/tmp/\(name).mov"),
            contentHash: .sha256(data: Data(name.utf8)),
            metadata: MediaMetadata(
                codecID: video ? "h264" : "pcm_s16le",
                pixelDimensions: video
                    ? PixelDimensions(width: 1_920, height: 1_080)
                    : nil,
                frameRate: video ? try frameRate : nil,
                duration: try frameRate.duration(ofFrames: duration),
                colorSpace: video ? .rec709 : .unspecified,
                audioChannelLayout: audio
                    ? AudioChannelLayout(channelCount: 2, layoutTag: "stereo")
                    : nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
    }

    func originalClip(
        kind: TrackKind,
        duration: Int64,
        linkGroupID: UUID?
    ) throws -> Clip {
        try makeClip(
            kind: kind,
            start: 0,
            duration: duration,
            name: "Original \(kind.rawValue)",
            linkGroupID: linkGroupID
        )
    }

    func tailClip(
        kind: TrackKind,
        start: Int64,
        duration: Int64,
        name: String? = nil
    ) throws -> Clip {
        try makeClip(
            kind: kind,
            start: start,
            duration: duration,
            name: name ?? "Tail \(kind.rawValue)",
            linkGroupID: nil
        )
    }

    func makeClip(
        kind: TrackKind,
        start: Int64,
        duration: Int64,
        name: String,
        linkGroupID: UUID?
    ) throws -> Clip {
        let durationTime = try frameRate.duration(ofFrames: duration)
        return Clip(
            id: UUID(),
            source: .media(id: Self.originalMediaID),
            sourceRange: try TimeRange(start: .zero, duration: durationTime),
            timelineRange: try TimeRange(
                start: try RationalTime.atFrame(start, frameRate: frameRate),
                duration: durationTime
            ),
            kind: kind,
            name: name,
            linkGroupID: linkGroupID
        )
    }

    func makeModel(project: Project) -> EditorAjarAppModel {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            automaticallyResolvesMediaReferences: false
        )
        model.replaceProjectSessionForTesting(project, documentURL: nil)
        return model
    }

    func clips(in track: Track) -> [Clip] {
        track.items.compactMap { item in
            guard case .clip(let clip) = item else { return nil }
            return clip
        }
    }

    func clip(mediaID: UUID, in track: Track) throws -> Clip {
        try XCTUnwrap(clips(in: track).first { $0.source == .media(id: mediaID) })
    }

    func clip(named name: String, in track: Track) throws -> Clip {
        try XCTUnwrap(clips(in: track).first { $0.name == name })
    }

    func assertRange(
        _ range: TimeRange,
        start: Int64,
        duration: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try range.start.frameIndex(at: frameRate, rounding: .nearestOrAwayFromZero),
            start,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try range.duration.frameIndex(at: frameRate, rounding: .nearestOrAwayFromZero),
            duration,
            file: file,
            line: line
        )
    }

    /// Fixture clips are built before `makeFixture`; this shared identity is inserted into every
    /// fixture media pool so the intermediate project always validates.
    private static let originalMediaID = UUID()
}
