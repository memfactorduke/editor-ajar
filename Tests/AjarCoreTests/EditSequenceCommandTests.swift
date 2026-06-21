// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class EditSequenceCommandTests: XCTestCase {
    func testFRTL011SequenceLifecycleCommandsRouteThroughEditHistory() throws {
        let fixture = try makeEditFixture(seed: 400)
        let addedSequence = try makeEmptyEditSequence(
            id: try editUUID(400_050),
            name: "Added Sequence"
        )
        let duplicatedSequence = try makeEmptyEditSequence(
            id: try editUUID(400_051),
            name: "Duplicated Sequence"
        )
        var history = EditHistory(project: fixture.project)

        let addedProject = try history.apply(.addSequence(addedSequence))
        XCTAssertEqual(
            addedProject.sequences.map(\.id),
            [fixture.sequenceID, addedSequence.id]
        )
        XCTAssertEqual(addedProject.validate(), .valid)

        let duplicatedProject = try history.apply(
            .duplicateSequence(
                sourceSequenceID: fixture.sequenceID,
                duplicate: duplicatedSequence
            )
        )
        XCTAssertEqual(
            duplicatedProject.sequences.map(\.id),
            [fixture.sequenceID, duplicatedSequence.id, addedSequence.id]
        )
        XCTAssertEqual(duplicatedProject.validate(), .valid)

        let removedProject = try history.apply(.removeSequence(sequenceID: addedSequence.id))
        XCTAssertEqual(
            removedProject.sequences.map(\.id),
            [fixture.sequenceID, duplicatedSequence.id]
        )

        XCTAssertEqual(history.undo(), duplicatedProject)
        XCTAssertEqual(try history.redo(), removedProject)
    }

    func testFRTL011RemovingLastSequenceReturnsTypedError() throws {
        let fixture = try makeEditFixture(seed: 410)

        XCTAssertThrowsError(
            try apply(.removeSequence(sequenceID: fixture.sequenceID), to: fixture.project)
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .cannotRemoveLastSequence(fixture.sequenceID)
            )
        }
    }

    func testFRTL011DuplicateSequenceIDReturnsTypedError() throws {
        let fixture = try makeEditFixture(seed: 420)
        let duplicateIDSequence = try makeEmptyEditSequence(
            id: fixture.sequenceID,
            name: "Duplicate ID"
        )

        XCTAssertThrowsError(
            try apply(.addSequence(duplicateIDSequence), to: fixture.project)
        ) { error in
            XCTAssertEqual(error as? EditReducerError, .duplicateSequenceID(fixture.sequenceID))
        }

        XCTAssertThrowsError(
            try apply(
                .duplicateSequence(
                    sourceSequenceID: fixture.sequenceID,
                    duplicate: duplicateIDSequence
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(error as? EditReducerError, .duplicateSequenceID(fixture.sequenceID))
        }
    }
}
