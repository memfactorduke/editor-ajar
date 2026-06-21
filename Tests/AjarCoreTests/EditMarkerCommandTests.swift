// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class EditMarkerCommandTests: XCTestCase {
    func testFRTL008MarkerCommandsKeepMarkersSortedByTime() throws {
        let fixture = try makeEditFixture(seed: 230)
        let laterMarker = Marker(
            id: try editUUID(230_900),
            time: try editTime(18),
            name: "Later",
            color: .purple,
            note: "Second marker"
        )
        let earlierMarker = Marker(
            id: try editUUID(230_901),
            time: try editTime(6),
            name: "Earlier",
            color: .yellow,
            note: "First marker"
        )

        let withLaterMarker = try apply(
            .addMarker(sequenceID: fixture.sequenceID, marker: laterMarker),
            to: fixture.project
        )
        let withBothMarkers = try apply(
            .addMarker(sequenceID: fixture.sequenceID, marker: earlierMarker),
            to: withLaterMarker
        )
        XCTAssertEqual(
            withBothMarkers.sequences.first?.markers.map(\.id),
            [
                earlierMarker.id,
                laterMarker.id
            ]
        )

        let movedLaterMarker = Marker(
            id: laterMarker.id,
            time: try editTime(3),
            name: "Moved",
            color: .green,
            note: "Moved before the first marker"
        )
        let withMovedMarker = try apply(
            .updateMarker(sequenceID: fixture.sequenceID, marker: movedLaterMarker),
            to: withBothMarkers
        )
        XCTAssertEqual(
            withMovedMarker.sequences.first?.markers.map(\.id),
            [
                laterMarker.id,
                earlierMarker.id
            ]
        )

        let afterRemoval = try apply(
            .removeMarker(sequenceID: fixture.sequenceID, markerID: laterMarker.id),
            to: withMovedMarker
        )
        XCTAssertEqual(
            afterRemoval.sequences.first?.markers.map(\.id),
            [earlierMarker.id]
        )
    }

    func testFRTL008MarkerCommandsReturnTypedMarkerErrors() throws {
        let fixture = try makeEditFixture(seed: 240)
        let marker = Marker(
            id: try editUUID(240_900),
            time: try editTime(6),
            name: "Marker"
        )
        let projectWithMarker = try replacingMarkers([marker], in: fixture)
        let missingMarkerID = try editUUID(240_901)

        XCTAssertThrowsError(
            try apply(
                .addMarker(sequenceID: fixture.sequenceID, marker: marker),
                to: projectWithMarker
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .duplicateMarkerID(sequenceID: fixture.sequenceID, markerID: marker.id)
            )
        }

        XCTAssertThrowsError(
            try apply(
                .removeMarker(sequenceID: fixture.sequenceID, markerID: missingMarkerID),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .markerNotFound(sequenceID: fixture.sequenceID, markerID: missingMarkerID)
            )
        }

        XCTAssertThrowsError(
            try apply(
                .updateMarker(
                    sequenceID: fixture.sequenceID,
                    marker: Marker(id: missingMarkerID, time: try editTime(7), name: "Missing")
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .markerNotFound(sequenceID: fixture.sequenceID, markerID: missingMarkerID)
            )
        }
    }

    func testFRTL008ClipAnchoredMarkersRequireExistingClipReference() throws {
        let fixture = try makeEditFixture(seed: 250)
        let missingClipID = try editUUID(250_900)
        let marker = Marker(
            id: try editUUID(250_901),
            time: try editTime(6),
            name: "Bad anchor",
            anchor: .clip(trackID: fixture.videoTrackID, clipID: missingClipID)
        )

        XCTAssertThrowsError(
            try apply(
                .addMarker(sequenceID: fixture.sequenceID, marker: marker),
                to: fixture.project
            )
        ) { error in
            guard case .validationFailed(let errors) = error as? EditReducerError else {
                XCTFail("Expected validationFailed, got \(error)")
                return
            }
            XCTAssertTrue(errors.containsMissingMarkerClipReference)
        }
    }
}

final class MarkerNavigationTests: XCTestCase {
    func testFRPLAY002NextAndPreviousMarkerNavigationUsesExactTime() throws {
        let fixture = try makeEditFixture(seed: 260)
        let firstMarker = Marker(
            id: try editUUID(260_900),
            time: try editTime(6),
            name: "First"
        )
        let secondMarker = Marker(
            id: try editUUID(260_901),
            time: try editTime(18),
            name: "Second"
        )
        let project = try replacingMarkers([secondMarker, firstMarker], in: fixture)
        let sequence = try XCTUnwrap(project.sequences.first)

        XCTAssertEqual(
            MarkerNavigation.nextMarker(in: sequence, after: try editTime(0))?.id,
            firstMarker.id
        )
        XCTAssertEqual(
            MarkerNavigation.nextMarker(in: sequence, after: try editTime(6))?.id,
            secondMarker.id
        )
        XCTAssertNil(MarkerNavigation.nextMarker(in: sequence, after: try editTime(18)))
        XCTAssertEqual(
            MarkerNavigation.previousMarker(in: sequence, before: try editTime(18))?.id,
            firstMarker.id
        )
        XCTAssertNil(MarkerNavigation.previousMarker(in: sequence, before: try editTime(6)))
    }
}

func makeMarkerCommandCases(
    fixture: EditFixture,
    seed: Int
) throws -> [EditCommandCase] {
    let markerID = try editUUID(seed * 1_000 + 26)
    let marker = Marker(
        id: markerID,
        time: try editTime(6),
        name: "Generated marker \(seed)",
        color: .red,
        note: "Undoable marker"
    )
    let projectWithMarker = try replacingMarkers([marker], in: fixture)
    let updatedMarker = Marker(
        id: markerID,
        time: try editTime(8),
        name: "Updated marker \(seed)",
        color: .green,
        note: "Undoable marker update",
        anchor: .clip(trackID: fixture.videoTrackID, clipID: fixture.clipID)
    )

    return [
        EditCommandCase(
            project: fixture.project,
            command: .addMarker(sequenceID: fixture.sequenceID, marker: marker)
        ),
        EditCommandCase(
            project: projectWithMarker,
            command: .removeMarker(sequenceID: fixture.sequenceID, markerID: markerID)
        ),
        EditCommandCase(
            project: projectWithMarker,
            command: .updateMarker(sequenceID: fixture.sequenceID, marker: updatedMarker)
        )
    ]
}
