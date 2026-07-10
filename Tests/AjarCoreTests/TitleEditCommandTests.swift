// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-TXT-001 undoable title edit commands and blade/copy preservation.
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

    func testFRTXT001SetTitleTextBoxIsUndoable() throws {
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
        let setClip = try titleClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: set,
            sequenceID: fixture.sequenceID
        )
        guard case .title(let setTitle) = setClip.source else {
            return XCTFail("expected title")
        }
        XCTAssertEqual(setTitle.boxes.first { $0.id == boxID }?.text, "Updated")
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), set)
    }

    func testFRTXT003LiveTitleTextEditsCoalesceIntoOneUndoStep() throws {
        let fixture = try makeTitleProjectFixture(seed: 8_413)
        let originalBox = try XCTUnwrap(fixture.titleSource.boxes.first)
        var history = EditHistory(project: fixture.project)

        let intermediateBox = copying(originalBox, text: "Live")
        _ = try history.apply(
            .setTitleTextBox(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                box: intermediateBox
            )
        )
        let finalBox = copying(originalBox, text: "Live title edit")
        let edited = try history.applyCoalescingWithPrevious(
            .setTitleTextBox(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                box: finalBox
            )
        )

        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(
            try titleBox(
                originalBox.id,
                clipID: fixture.clipID,
                trackID: fixture.videoTrackID,
                sequenceID: fixture.sequenceID,
                project: edited
            ).text,
            "Live title edit"
        )
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
    }

    func testFRTXT001RemoveTitleTextBoxIsUndoable() throws {
        let fixture = try makeTitleProjectFixture(seed: 8_412)
        var history = EditHistory(project: fixture.project)
        let boxID = try XCTUnwrap(fixture.titleSource.boxes.first?.id)

        let removed = try history.apply(
            .removeTitleTextBox(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                boxID: boxID
            )
        )
        let removedClip = try titleClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: removed,
            sequenceID: fixture.sequenceID
        )
        guard case .title(let removedTitle) = removedClip.source else {
            return XCTFail("expected title")
        }
        XCTAssertFalse(removedTitle.boxes.contains(where: { $0.id == boxID }))
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), removed)
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

    func testFRTXT001FRTXT002BladeSplitPreservesStyledTitleSourceOnBothHalves() throws {
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
        let left = try titleClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: bladed,
            sequenceID: fixture.sequenceID
        )
        let right = try titleClip(
            rightClipID,
            trackID: fixture.videoTrackID,
            in: bladed,
            sequenceID: fixture.sequenceID
        )
        let style = try XCTUnwrap(fixture.titleSource.boxes.first)
        XCTAssertNotNil(style.style.stroke)
        XCTAssertNotNil(style.style.dropShadow)
        XCTAssertNotNil(style.style.gradientFill)
        XCTAssertNotNil(style.backgroundBox)
        XCTAssertEqual(left.source, .title(fixture.titleSource))
        XCTAssertEqual(right.source, .title(fixture.titleSource))
    }

    func testFRTXT001FRTXT002CopyingPropagatesStyledTitleSource() throws {
        let fixture = try makeTitleProjectFixture(seed: 8_405)
        let clip = try titleClip(
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
        guard case .title(let copiedTitle) = copied.source else {
            return XCTFail("expected title source on copy")
        }
        let copiedBox = try XCTUnwrap(copiedTitle.boxes.first)
        XCTAssertNotNil(copiedBox.style.stroke)
        XCTAssertNotNil(copiedBox.style.dropShadow)
        XCTAssertNotNil(copiedBox.style.gradientFill)
        XCTAssertNotNil(copiedBox.backgroundBox)
    }

    private func copying(_ box: TitleTextBox, text: String) -> TitleTextBox {
        TitleTextBox(
            id: box.id,
            text: text,
            origin: box.origin,
            width: box.width,
            height: box.height,
            style: box.style,
            backgroundBox: box.backgroundBox
        )
    }

    private func titleBox(
        _ boxID: UUID,
        clipID: UUID,
        trackID: UUID,
        sequenceID: UUID,
        project: Project
    ) throws -> TitleTextBox {
        let clip = try titleClip(
            clipID,
            trackID: trackID,
            in: project,
            sequenceID: sequenceID
        )
        guard case .title(let title) = clip.source else {
            throw TitleEditCommandTestError.expectedTitle
        }
        return try XCTUnwrap(title.boxes.first { $0.id == boxID })
    }
}

private enum TitleEditCommandTestError: Error {
    case expectedTitle
}
