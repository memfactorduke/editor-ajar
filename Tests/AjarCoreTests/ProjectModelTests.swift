// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class ProjectModelTests: XCTestCase {
    func testFRPROJ001FRPROJ003ProjectModelCodableRoundTripPreservesStableIDs() throws {
        let mediaID = try uuid(1)
        let sequenceID = try uuid(2)
        let trackID = try uuid(3)
        let markerID = try uuid(4)
        let clipID = try uuid(5)
        let media = try makeMediaRef(id: mediaID)
        let clip = try makeClip(id: clipID, source: .media(id: mediaID), startFrame: 0)
        let track = Track(id: trackID, kind: .video, items: [.clip(clip)])
        let marker = Marker(id: markerID, time: try time(12), name: "FR-PROJ marker")
        let sequence = try makeSequence(
            id: sequenceID,
            videoTracks: [track],
            markers: [marker]
        )
        let project = try makeProject(mediaPool: [media], sequences: [sequence])

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        XCTAssertEqual(decoded, project)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.mediaPool.first?.id, mediaID)
        XCTAssertEqual(decoded.sequences.first?.id, sequenceID)
        XCTAssertEqual(decoded.sequences.first?.videoTracks.first?.id, trackID)
        XCTAssertEqual(decoded.sequences.first?.markers.first?.id, markerID)
    }

    func testFRTL001FRTL002VideoTrackZeroIsBottomOfCompositeStackByModelOrder() throws {
        let mediaID = try uuid(10)
        let bottomTrackID = try uuid(11)
        let topTrackID = try uuid(12)
        let bottomTrack = Track(
            id: bottomTrackID,
            kind: .video,
            items: [
                .clip(try makeClip(id: try uuid(13), source: .media(id: mediaID), startFrame: 0))
            ]
        )
        let topTrack = Track(
            id: topTrackID,
            kind: .video,
            items: [
                .clip(try makeClip(id: try uuid(14), source: .media(id: mediaID), startFrame: 0))
            ]
        )
        let sequence = try makeSequence(videoTracks: [bottomTrack, topTrack])
        let project = try makeProject(mediaPool: [makeMediaRef(id: mediaID)], sequences: [sequence])

        XCTAssertEqual(project.validate(), .valid)
        XCTAssertEqual(project.sequences.first?.videoTracks.first?.id, bottomTrackID)
        XCTAssertEqual(project.sequences.first?.videoTracks.dropFirst().first?.id, topTrackID)
    }

    func testADR0008ValidationAcceptsSortedNonOverlappingTimelineItems() throws {
        let mediaID = try uuid(20)
        let firstClip = TimelineItem.clip(
            try makeClip(id: try uuid(22), source: .media(id: mediaID), startFrame: 0)
        )
        let gap = TimelineItem.gap(try range(startFrame: 10, durationFrames: 2))
        let transition = TimelineItem.transition(
            Transition(
                id: try uuid(23),
                timelineRange: try range(startFrame: 12, durationFrames: 1),
                kind: .video,
                name: "ADR-0008 transition"
            )
        )
        let secondClip = TimelineItem.clip(
            try makeClip(id: try uuid(24), source: .media(id: mediaID), startFrame: 13)
        )
        let track = Track(
            id: try uuid(21),
            kind: .video,
            items: [firstClip, gap, transition, secondClip]
        )
        let sequence = try makeSequence(videoTracks: [track])
        let project = try makeProject(mediaPool: [makeMediaRef(id: mediaID)], sequences: [sequence])

        XCTAssertEqual(project.validate(), .valid)
    }

    func testADR0008ValidationRejectsOverlappingItemsWithoutCrashing() throws {
        let mediaID = try uuid(30)
        let sequenceID = try uuid(31)
        let trackID = try uuid(32)
        let firstItem = TimelineItem.clip(
            try makeClip(id: try uuid(33), source: .media(id: mediaID), startFrame: 0)
        )
        let secondItem = TimelineItem.clip(
            try makeClip(id: try uuid(34), source: .media(id: mediaID), startFrame: 9)
        )
        let track = Track(
            id: trackID,
            kind: .video,
            items: [firstItem, secondItem]
        )
        let sequence = try makeSequence(id: sequenceID, videoTracks: [track])
        let project = try makeProject(mediaPool: [makeMediaRef(id: mediaID)], sequences: [sequence])

        let errors = validationErrors(from: project)

        XCTAssertTrue(
            errors.contains(
                .itemsOverlap(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    previousIndex: 0,
                    itemIndex: 1
                )
            )
        )
    }

    func testADR0008ValidationRejectsUnsortedItemsWithoutCrashing() throws {
        let mediaID = try uuid(40)
        let sequenceID = try uuid(41)
        let trackID = try uuid(42)
        let firstItem = TimelineItem.clip(
            try makeClip(id: try uuid(43), source: .media(id: mediaID), startFrame: 10)
        )
        let secondItem = TimelineItem.clip(
            try makeClip(id: try uuid(44), source: .media(id: mediaID), startFrame: 0)
        )
        let track = Track(
            id: trackID,
            kind: .video,
            items: [firstItem, secondItem]
        )
        let sequence = try makeSequence(id: sequenceID, videoTracks: [track])
        let project = try makeProject(mediaPool: [makeMediaRef(id: mediaID)], sequences: [sequence])

        let errors = validationErrors(from: project)

        XCTAssertTrue(
            errors.contains(
                .itemsNotSorted(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    previousIndex: 0,
                    itemIndex: 1
                )
            )
        )
    }

    func testFRTL001ValidationRejectsTrackAndItemKindMismatches() throws {
        let mediaID = try uuid(50)
        let sequenceID = try uuid(51)
        let misplacedTrackID = try uuid(52)
        let videoTrackID = try uuid(53)
        let misplacedTrack = Track(
            id: misplacedTrackID,
            kind: .audio,
            items: [
                .clip(
                    try makeClip(
                        id: try uuid(54),
                        source: .media(id: mediaID),
                        startFrame: 0,
                        kind: .audio
                    )
                )
            ]
        )
        let videoTrackWithAudioItem = Track(
            id: videoTrackID,
            kind: .video,
            items: [
                .clip(
                    try makeClip(
                        id: try uuid(55),
                        source: .media(id: mediaID),
                        startFrame: 10,
                        kind: .audio
                    )
                )
            ]
        )
        let sequence = try makeSequence(
            id: sequenceID,
            videoTracks: [misplacedTrack, videoTrackWithAudioItem]
        )
        let project = try makeProject(mediaPool: [makeMediaRef(id: mediaID)], sequences: [sequence])

        let errors = validationErrors(from: project)

        XCTAssertTrue(
            errors.contains(
                .trackKindMismatch(
                    sequenceID: sequenceID,
                    trackID: misplacedTrackID,
                    expected: .video,
                    actual: .audio
                )
            )
        )
        XCTAssertTrue(
            errors.contains(
                .itemKindMismatch(
                    sequenceID: sequenceID,
                    trackID: videoTrackID,
                    itemIndex: 0,
                    itemKind: .audio
                )
            )
        )
    }

    func testFRPROJ001ValidationRejectsMissingMediaReferenceWithoutCrashing() throws {
        let missingMediaID = try uuid(60)
        let sequenceID = try uuid(61)
        let trackID = try uuid(62)
        let clipID = try uuid(63)
        let track = Track(
            id: trackID,
            kind: .video,
            items: [
                .clip(try makeClip(id: clipID, source: .media(id: missingMediaID), startFrame: 0))
            ]
        )
        let sequence = try makeSequence(id: sequenceID, videoTracks: [track])
        let project = try makeProject(mediaPool: [], sequences: [sequence])

        XCTAssertEqual(
            validationErrors(from: project),
            [
                .missingMediaReference(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    mediaID: missingMediaID
                )
            ]
        )
    }
}

final class ProjectValidationTests: XCTestCase {
    func testFRCMP005ClipSourceCanRepresentFutureSequenceReference() throws {
        let sourceSequenceID = try uuid(70)
        let targetSequenceID = try uuid(71)
        let track = Track(
            id: try uuid(72),
            kind: .video,
            items: [
                .clip(
                    try makeClip(
                        id: try uuid(73),
                        source: .sequence(id: targetSequenceID),
                        startFrame: 0
                    )
                )
            ]
        )
        let sourceSequence = try makeSequence(id: sourceSequenceID, videoTracks: [track])
        let targetSequence = try makeSequence(id: targetSequenceID)
        let project = try makeProject(mediaPool: [], sequences: [sourceSequence, targetSequence])

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        XCTAssertEqual(decoded, project)
        XCTAssertEqual(decoded.validate(), .valid)
    }

    func testADR0008ValidationRejectsMissingSequenceReferenceWithoutCrashing() throws {
        let missingSequenceID = try uuid(80)
        let sequenceID = try uuid(81)
        let trackID = try uuid(82)
        let clipID = try uuid(83)
        let track = Track(
            id: trackID,
            kind: .video,
            items: [
                .clip(
                    try makeClip(
                        id: clipID,
                        source: .sequence(id: missingSequenceID),
                        startFrame: 0
                    )
                )
            ]
        )
        let sequence = try makeSequence(id: sequenceID, videoTracks: [track])
        let project = try makeProject(mediaPool: [], sequences: [sequence])

        XCTAssertEqual(
            validationErrors(from: project),
            [
                .missingSequenceReference(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    targetID: missingSequenceID
                )
            ]
        )
    }

    func testADR0008ValidationPropertyAcceptsGeneratedSortedNonOverlappingClips() throws {
        let mediaID = try uuid(90)
        let media = try makeMediaRef(id: mediaID)

        for clipCount in 0...12 {
            var items: [TimelineItem] = []
            var cursor = Int64(0)

            for index in 0..<clipCount {
                let duration = Int64((index % 3) + 1)
                items.append(
                    .clip(
                        try makeClip(
                            id: try uuid(1_000 + clipCount * 100 + index),
                            source: .media(id: mediaID),
                            startFrame: cursor,
                            durationFrames: duration
                        )
                    )
                )
                cursor += duration + Int64(index % 2)
            }

            let track = Track(id: try uuid(2_000 + clipCount), kind: .video, items: items)
            let sequence = try makeSequence(id: try uuid(3_000 + clipCount), videoTracks: [track])
            let project = try makeProject(mediaPool: [media], sequences: [sequence])

            XCTAssertEqual(project.validate(), .valid)
        }
    }
}

private func validationErrors(from project: Project) -> [ProjectValidationError] {
    switch project.validate() {
    case .valid:
        XCTFail("Expected invalid project")
        return []
    case .invalid(let errors):
        return errors
    }
}

private func makeProject(mediaPool: [MediaRef], sequences: [Sequence]) throws -> Project {
    Project(
        schemaVersion: 1,
        settings: try makeSettings(),
        mediaPool: mediaPool,
        sequences: sequences
    )
}

private func makeSettings() throws -> ProjectSettings {
    ProjectSettings(
        frameRate: try FrameRate(frames: 24),
        resolution: PixelDimensions(width: 1_920, height: 1_080),
        colorSpace: .rec709,
        audioSampleRate: 48_000
    )
}

private func makeSequence(
    id: UUID? = nil,
    videoTracks: [Track] = [],
    audioTracks: [Track] = [],
    markers: [Marker] = []
) throws -> Sequence {
    Sequence(
        id: try id ?? uuid(900),
        name: "Timeline",
        videoTracks: videoTracks,
        audioTracks: audioTracks,
        markers: markers,
        timebase: try FrameRate(frames: 24)
    )
}

private func makeMediaRef(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 24),
            duration: try time(240),
            colorSpace: .rec709,
            audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func makeClip(
    id: UUID,
    source: ClipSource,
    startFrame: Int64,
    durationFrames: Int64 = 10,
    kind: TrackKind = .video
) throws -> Clip {
    Clip(
        id: id,
        source: source,
        sourceRange: try range(startFrame: 0, durationFrames: durationFrames),
        timelineRange: try range(startFrame: startFrame, durationFrames: durationFrames),
        kind: kind,
        name: "Clip \(id.uuidString)"
    )
}

private func range(startFrame: Int64, durationFrames: Int64) throws -> TimeRange {
    try TimeRange(start: time(startFrame), duration: time(durationFrames))
}

private func time(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

private func uuid(_ value: Int) throws -> UUID {
    let uuidString = String(format: "00000000-0000-0000-0000-%012d", value)
    return try XCTUnwrap(UUID(uuidString: uuidString))
}
