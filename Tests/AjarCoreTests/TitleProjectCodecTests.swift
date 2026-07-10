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

    func testFRTXT002NestedLegacyTitleDefaultsEveryAbsentStylingField() throws {
        let seed = 8_408
        let project = try makeNestedTitleCompoundProject(seed: seed)
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let stylingKeys = ["stroke", "dropShadow", "gradientFill", "backgroundBox"]
        let strippedProject = try stylingKeys.reduce(package.projectJSON) { json, key in
            try titleProjectJSONWithoutKey(key, in: json)
        }
        // Previous minor before FR-TXT-002 styling (minor 4): force decode at 3 so absent
        // stroke/shadow/gradient/backgroundBox keys default cleanly (LUT gate is 3).
        let legacyProjectJSON = try jsonSettingSchemaMinor(3, in: strippedProject)
        let legacyMediaJSON = try jsonSettingSchemaMinor(3, in: package.mediaJSON)
        let loaded = try editableTitleProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: legacyMediaJSON
            )
        )

        XCTAssertTrue(loaded.validate().isValid)
        XCTAssertEqual(loaded.schemaMinor, 3)
        let innerSequenceID = try editUUID(seed * 1_000 + 300)
        let inner = try XCTUnwrap(loaded.sequences.first { $0.id == innerSequenceID })
        guard case .clip(let titleClip) = inner.videoTracks[0].items[0],
            case .title(let title) = titleClip.source
        else {
            return XCTFail("expected nested legacy title clip")
        }
        let box = try XCTUnwrap(title.boxes.first)
        XCTAssertNil(box.style.stroke)
        XCTAssertNil(box.style.dropShadow)
        XCTAssertNil(box.style.gradientFill)
        XCTAssertNil(box.backgroundBox)
        XCTAssertEqual(box.text, "Title \(seed)")
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
        // swift-format-ignore
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

    private func jsonSettingSchemaMinor(_ minor: Int, in data: Data) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["schemaMinor"] = minor
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
