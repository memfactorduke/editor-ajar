// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-TXT-001 project codec paths: nested legacy decode and title-in-compound round-trip.
final class TitleProjectCodecTests: XCTestCase {
    func testFRTXT001NestedLegacyMediaProjectStillDecodesThroughCompoundPath() throws {
        // Nested compound path: outer sequence holds a compound clip whose inner sequence holds
        // a media clip with no title keys. This path has regressed when ClipSource grew cases.
        let fixture = try makeCompoundClipFixture(seed: 8_406)
        let package = try AjarProjectCodec.encodeNewDocument(fixture.project)
        let stripped = try titleProjectJSONWithoutKey("title", in: package.projectJSON)
        let loaded = try editableTitleProject(
            from: AjarProjectCodec.decode(
                projectJSON: stripped,
                mediaJSON: package.mediaJSON
            )
        )
        XCTAssertEqual(loaded, fixture.project)
        XCTAssertTrue(loaded.validate().isValid)
        let nestedClip = try requiredCompoundClip(in: loaded, fixture: fixture)
        guard case .sequence = nestedClip.source else {
            return XCTFail("expected compound sequence source")
        }
    }

    func testFRTXT001TitleInsideNestedCompoundRoundTripsThroughProjectCodec() throws {
        let project = try makeNestedTitleCompoundProject(seed: 8_407)
        let title = try makeSampleTitle(seed: 8_407)
        let innerSequenceID = try editUUID(8_407_300)
        XCTAssertTrue(project.validate().isValid)
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let loaded = try editableTitleProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        XCTAssertEqual(loaded, project)
        let loadedInner = try XCTUnwrap(
            loaded.sequences.first(where: { $0.id == innerSequenceID })
        )
        guard case .clip(let loadedTitleClip) = loadedInner.videoTracks[0].items[0],
            case .title(let loadedTitle) = loadedTitleClip.source
        else {
            return XCTFail("expected nested title clip")
        }
        XCTAssertEqual(loadedTitle, title)
    }

    private func makeNestedTitleCompoundProject(seed: Int) throws -> Project {
        let outer = try makeEditFixture(seed: seed)
        let title = try makeSampleTitle(seed: seed)
        let innerSequenceID = try editUUID(seed * 1_000 + 300)
        let innerTrackID = try editUUID(seed * 1_000 + 301)
        let titleClipID = try editUUID(seed * 1_000 + 302)
        let compoundClipID = try editUUID(seed * 1_000 + 303)
        let titleClip = Clip(
            id: titleClipID,
            source: .title(title),
            sourceRange: try editRange(startFrame: 0, durationFrames: 10),
            timelineRange: try editRange(startFrame: 0, durationFrames: 10),
            kind: .video,
            name: "Nested title"
        )
        let innerSequence = Sequence(
            id: innerSequenceID,
            name: "Inner title sequence",
            videoTracks: [
                Track(id: innerTrackID, kind: .video, items: [.clip(titleClip)])
            ],
            audioTracks: [],
            markers: [],
            timebase: try FrameRate(frames: 24)
        )
        let compoundClip = Clip(
            id: compoundClipID,
            source: .sequence(id: innerSequenceID),
            sourceRange: try editRange(startFrame: 0, durationFrames: 10),
            timelineRange: try editRange(startFrame: 0, durationFrames: 10),
            kind: .video,
            name: "Compound with title"
        )
        let outerSequence = try XCTUnwrap(
            outer.project.sequences.first { $0.id == outer.sequenceID }
        )
        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: outer.project.settings,
            mediaPool: outer.project.mediaPool,
            sequences: [
                Sequence(
                    id: outerSequence.id,
                    name: outerSequence.name,
                    videoTracks: [
                        Track(
                            id: outer.videoTrackID,
                            kind: .video,
                            items: [.clip(compoundClip)]
                        )
                    ],
                    audioTracks: outerSequence.audioTracks,
                    markers: [],
                    timebase: outerSequence.timebase
                ),
                innerSequence
            ]
        )
    }
}
