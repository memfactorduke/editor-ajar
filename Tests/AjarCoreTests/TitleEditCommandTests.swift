// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-TXT-001 undoable title edit commands, blade/copy preservation, nested legacy decode.
final class TitleEditCommandTests: XCTestCase {
    func testFRTXT001InsertTitleClipRoutesThroughUndoableHistory() throws {
        let fixture = try makeEditFixture(seed: 8_401)
        let title = try makeSampleTitle(seed: 8_401)
        let clipID = try editUUID(8_401_200)
        var history = EditHistory(project: fixture.project)

        let edited = try history.apply(
            .insertTitleClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: clipID,
                title: title,
                timelineRange: try editRange(startFrame: 20, durationFrames: 12),
                name: "FR-TXT-001 Title"
            )
        )
        let inserted = try requiredClip(clipID, in: edited, fixture: fixture)
        guard case .title(let insertedTitle) = inserted.source else {
            return XCTFail("expected title source")
        }
        XCTAssertEqual(insertedTitle, title)
        XCTAssertEqual(inserted.kind, .video)
        XCTAssertEqual(edited.validate(), .valid)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
    }

    func testFRTXT001SetTitleTextBoxAndRemoveAreUndoable() throws {
        let fixture = try makeTitleProjectFixture(seed: 8_402)
        var history = EditHistory(project: fixture.project)
        let boxID = try editUUID(8_402_050)
        let box = TitleTextBox(
            id: boxID,
            text: "Updated",
            origin: CanvasPoint(x: RationalValue(8), y: RationalValue(8)),
            width: RationalValue(180),
            height: RationalValue(48),
            style: TitleTextStyle(fontSize: RationalValue(28), fontWeight: .semibold)
        )

        let set = try history.apply(
            .setTitleTextBox(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                box: box
            )
        )
        let setClip = try requiredClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: set,
            sequenceID: fixture.sequenceID
        )
        guard case .title(let setTitle) = setClip.source else {
            return XCTFail("expected title")
        }
        XCTAssertEqual(setTitle.boxes.first { $0.id == boxID }?.text, "Updated")

        let removed = try history.apply(
            .removeTitleTextBox(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                boxID: boxID
            )
        )
        let removedClip = try requiredClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: removed,
            sequenceID: fixture.sequenceID
        )
        guard case .title(let removedTitle) = removedClip.source else {
            return XCTFail("expected title")
        }
        XCTAssertFalse(removedTitle.boxes.contains(where: { $0.id == boxID }))
        XCTAssertEqual(history.undo(), set)
        XCTAssertEqual(history.undo(), fixture.project)
    }

    func testFRTXT001InvalidTitleEditReturnsTypedError() throws {
        let fixture = try makeTitleProjectFixture(seed: 8_403)
        let bad = TitleSource(boxes: [
            TitleTextBox(
                id: try editUUID(8_403_050),
                text: "x",
                origin: .zero,
                width: RationalValue.zero,
                height: RationalValue(10)
            )
        ])
        XCTAssertThrowsError(
            try EditReducer.apply(
                .setClipTitleSource(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.clipID,
                    title: bad
                ),
                to: fixture.project
            )
        ) { error in
            guard case .invalidEdit(let validation) = error as? EditReducerError else {
                return XCTFail("expected invalidEdit, got \(error)")
            }
            XCTAssertEqual(
                validation,
                .invalidTitleSource(
                    clipID: fixture.clipID,
                    error: .nonPositiveBoxSize(width: .zero, height: RationalValue(10))
                )
            )
        }
    }

    func testFRTXT001BladeSplitPreservesTitleSourceOnBothHalves() throws {
        let fixture = try makeTitleProjectFixture(seed: 8_404)
        let rightClipID = try editUUID(8_404_090)
        let bladed = try EditReducer.apply(
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                atTime: try editTime(4),
                rightClipID: rightClipID
            ),
            to: fixture.project
        )
        let left = try requiredClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: bladed,
            sequenceID: fixture.sequenceID
        )
        let right = try requiredClip(
            rightClipID,
            trackID: fixture.videoTrackID,
            in: bladed,
            sequenceID: fixture.sequenceID
        )
        XCTAssertEqual(left.source, .title(fixture.titleSource))
        XCTAssertEqual(right.source, .title(fixture.titleSource))
    }

    func testFRTXT001CopyingPropagatesTitleSource() throws {
        let fixture = try makeTitleProjectFixture(seed: 8_405)
        let clip = try requiredClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: fixture.project,
            sequenceID: fixture.sequenceID
        )
        let copied = EditReducer.copying(
            clip,
            timelineRange: try editRange(startFrame: 20, durationFrames: 10)
        )
        XCTAssertEqual(copied.source, clip.source)
        guard case .title = copied.source else {
            return XCTFail("expected title source on copy")
        }
    }

    func testFRTXT001NestedLegacyMediaProjectStillDecodesThroughCompoundPath() throws {
        // Nested compound path: outer sequence holds a compound clip whose inner sequence holds
        // a media clip with no title keys. This path has regressed when ClipSource grew cases.
        let fixture = try makeCompoundClipFixture(seed: 8_406)
        let package = try AjarProjectCodec.encode(fixture.project)
        // Strip any accidental title keys (none expected) and re-decode nested project JSON.
        let stripped = try projectJSONWithoutKey("title", in: package.projectJSON)
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
        let outer = try makeEditFixture(seed: 8_407)
        let title = try makeSampleTitle(seed: 8_407)
        let innerSequenceID = try editUUID(8_407_300)
        let innerTrackID = try editUUID(8_407_301)
        let titleClipID = try editUUID(8_407_302)
        let compoundClipID = try editUUID(8_407_303)
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
        let project = Project(
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
                innerSequence,
            ]
        )
        XCTAssertTrue(project.validate().isValid)
        let package = try AjarProjectCodec.encode(project)
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

    func testFRTXT001RenderGraphEmitsTitleNodeWithStableContentHash() throws {
        let fixture = try makeTitleProjectFixture(seed: 8_408)
        let sequence = try XCTUnwrap(
            fixture.project.sequences.first { $0.id == fixture.sequenceID }
        )
        let graph = try buildRenderGraph(
            for: sequence,
            at: try editTime(0),
            in: fixture.project
        )
        let titleNode = try XCTUnwrap(
            graph.nodes.first { node in
                if case .title = node.kind { return true }
                return false
            }
        )
        guard case .title(let payload) = titleNode.kind else {
            return XCTFail("expected title node")
        }
        XCTAssertEqual(payload.title, fixture.titleSource)
        XCTAssertEqual(payload.clipID, fixture.clipID)

        // Style change must change content hash (discrimination for cache + goldens).
        var boxes = fixture.titleSource.boxes
        let first = boxes[0]
        boxes[0] = TitleTextBox(
            id: first.id,
            text: first.text,
            origin: first.origin,
            width: first.width,
            height: first.height,
            style: TitleTextStyle(
                fontFamily: first.style.fontFamily,
                fontSize: RationalValue(60),
                fontWeight: first.style.fontWeight,
                color: first.style.color,
                tracking: first.style.tracking,
                leading: first.style.leading,
                alignment: first.style.alignment
            )
        )
        let edited = try EditReducer.apply(
            .setClipTitleSource(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                title: TitleSource(boxes: boxes)
            ),
            to: fixture.project
        )
        let editedSequence = try XCTUnwrap(
            edited.sequences.first { $0.id == fixture.sequenceID }
        )
        let editedGraph = try buildRenderGraph(
            for: editedSequence,
            at: try editTime(0),
            in: edited
        )
        let editedTitleNode = try XCTUnwrap(
            editedGraph.nodes.first { node in
                if case .title = node.kind { return true }
                return false
            }
        )
        XCTAssertNotEqual(titleNode.contentHash, editedTitleNode.contentHash)
        XCTAssertNotEqual(graph.outputNode?.contentHash, editedGraph.outputNode?.contentHash)
    }
}

private struct TitleProjectFixture {
    let project: Project
    let sequenceID: UUID
    let videoTrackID: UUID
    let clipID: UUID
    let titleSource: TitleSource
}

private func makeTitleProjectFixture(seed: Int) throws -> TitleProjectFixture {
    let base = try makeEditFixture(seed: seed)
    let title = try makeSampleTitle(seed: seed)
    let clip = Clip(
        id: base.clipID,
        source: .title(title),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Title \(seed)"
    )
    let project = try replacingVideoItems([.clip(clip)], in: base)
    return TitleProjectFixture(
        project: project,
        sequenceID: base.sequenceID,
        videoTrackID: base.videoTrackID,
        clipID: base.clipID,
        titleSource: title
    )
}

private func makeSampleTitle(seed: Int) throws -> TitleSource {
    TitleSource(boxes: [
        TitleTextBox(
            id: try editUUID(seed * 1_000 + 50),
            text: "Title \(seed)",
            origin: CanvasPoint(x: RationalValue(16), y: RationalValue(16)),
            width: RationalValue(200),
            height: RationalValue(48),
            style: TitleTextStyle(
                fontFamily: TitleSource.deterministicFontFamily,
                fontSize: RationalValue(32),
                fontWeight: .bold,
                color: ClipRGBColor(red: .one, green: .one, blue: .one),
                alignment: .left
            )
        )
    ])
}

private func editableTitleProject(from result: AjarProjectLoadResult) throws -> Project {
    switch result {
    case .editable(let project):
        return project
    case .readOnly:
        XCTFail("Expected editable project")
        throw AjarProjectCodecError.malformedProjectJSON("unexpected read-only result")
    }
}

private func projectJSONWithoutKey(_ key: String, in data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    let stripped = try strippingKey(key, from: object)
    return try JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
}

private func strippingKey(_ key: String, from value: Any) throws -> Any {
    if var dictionary = value as? [String: Any] {
        dictionary.removeValue(forKey: key)
        for (nestedKey, nested) in dictionary {
            dictionary[nestedKey] = try strippingKey(key, from: nested)
        }
        return dictionary
    }
    if let array = value as? [Any] {
        return try array.map { try strippingKey(key, from: $0) }
    }
    return value
}
