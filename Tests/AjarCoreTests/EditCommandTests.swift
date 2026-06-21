// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class EditCommandUndoTests: XCTestCase {
    func testFRTL012NFRSTAB007UndoDoIdentityForEveryCommandKindOverGeneratedProjects() throws {
        for seed in 0..<12 {
            for commandCase in try makeValidCommandCases(seed: seed) {
                var history = EditHistory(project: commandCase.project)
                let before = history.currentProject
                let after = try history.apply(commandCase.command)

                XCTAssertEqual(after.validate(), .valid)
                XCTAssertEqual(history.undo(), before)
                XCTAssertEqual(history.currentProject, before)
                XCTAssertEqual(try history.redo(), after)
                XCTAssertEqual(history.currentProject, after)
            }
        }
    }

    func testFRTL012RedoAfterUndoReproducesExactPostCommandValue() throws {
        let fixture = try makeEditFixture(seed: 100)
        let command = EditCommand.renameSequence(
            sequenceID: fixture.sequenceID,
            name: "Renamed sequence"
        )
        var history = EditHistory(project: fixture.project)
        let after = try history.apply(command)

        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), after)
        XCTAssertEqual(history.currentProject, after)
    }

    func testFRTL012RedoHistoryClearsAfterNewCommand() throws {
        let fixture = try makeEditFixture(seed: 110)
        var history = EditHistory(project: fixture.project)
        try history.apply(.renameSequence(sequenceID: fixture.sequenceID, name: "First"))

        XCTAssertNotNil(history.undo())
        XCTAssertEqual(history.redoCount, 1)

        try history.apply(.renameSequence(sequenceID: fixture.sequenceID, name: "Second"))

        XCTAssertEqual(history.redoCount, 0)
        XCTAssertNil(try history.redo())
    }

    func testNFRSTAB007UnboundedUndoDepthWithLongCommandSequence() throws {
        let fixture = try makeEditFixture(seed: 120)
        var history = EditHistory(project: fixture.project)
        var expectedFinalProject = fixture.project

        for index in 0..<250 {
            let command = EditCommand.renameSequence(
                sequenceID: fixture.sequenceID,
                name: "Edit \(index)"
            )
            expectedFinalProject = try apply(command, to: expectedFinalProject)
            try history.apply(command)
        }

        XCTAssertEqual(history.undoCount, 250)
        XCTAssertEqual(history.currentProject, expectedFinalProject)

        for _ in 0..<250 {
            XCTAssertNotNil(history.undo())
        }

        XCTAssertEqual(history.currentProject, fixture.project)
        XCTAssertEqual(history.redoCount, 250)

        for _ in 0..<250 {
            XCTAssertNotNil(try history.redo())
        }

        XCTAssertEqual(history.currentProject, expectedFinalProject)
    }
}

final class EditReducerInvariantTests: XCTestCase {
    func testADR0008EditReducerIsDeterministicForSameProjectAndCommand() throws {
        let fixture = try makeEditFixture(seed: 200)
        let command = EditCommand.moveClip(
            sequenceID: fixture.sequenceID,
            sourceTrackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            destinationTrackID: fixture.videoTrackID,
            timelineRange: try editRange(startFrame: 16, durationFrames: 8)
        )

        let first = try apply(command, to: fixture.project)
        let second = try apply(command, to: fixture.project)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.validate(), .valid)
    }

    func testADR0008ReducerPreservesInvariantsOrReturnsTypedError() throws {
        let fixture = try makeEditFixture(seed: 210)
        let validCommand = EditCommand.addClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clip: try makeEditClip(
                id: try editUUID(211_000),
                mediaID: fixture.mediaID,
                startFrame: 20
            )
        )
        let overlappingCommand = EditCommand.addClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clip: try makeEditClip(
                id: try editUUID(211_001),
                mediaID: fixture.mediaID,
                startFrame: 5
            )
        )
        let wrongKindCommand = EditCommand.addClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clip: try makeEditClip(
                id: try editUUID(211_002),
                mediaID: fixture.mediaID,
                startFrame: 20,
                kind: .audio
            )
        )

        try assertValidOrTypedError(validCommand, project: fixture.project)
        try assertValidOrTypedError(overlappingCommand, project: fixture.project)
        try assertValidOrTypedError(wrongKindCommand, project: fixture.project)
    }

    func testFRTL012ReducerReturnsTypedLookupErrorsWithoutCrashing() throws {
        let fixture = try makeEditFixture(seed: 220)
        let missingSequenceID = try editUUID(220_900)
        let missingTrackID = try editUUID(220_901)
        let missingClipID = try editUUID(220_902)

        XCTAssertThrowsError(
            try apply(
                .renameSequence(sequenceID: missingSequenceID, name: "Missing"),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(error as? EditReducerError, .sequenceNotFound(missingSequenceID))
        }

        XCTAssertThrowsError(
            try apply(
                .removeTrack(sequenceID: fixture.sequenceID, trackID: missingTrackID),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .trackNotFound(sequenceID: fixture.sequenceID, trackID: missingTrackID)
            )
        }

        XCTAssertThrowsError(
            try apply(
                .removeClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: missingClipID
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .clipNotFound(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: missingClipID
                )
            )
        }
    }
}

private struct EditFixture {
    let project: Project
    let sequenceID: UUID
    let videoTrackID: UUID
    let audioTrackID: UUID
    let clipID: UUID
    let mediaID: UUID
}

private struct EditCommandCase {
    let project: Project
    let command: EditCommand
}

private func assertValidOrTypedError(_ command: EditCommand, project: Project) throws {
    do {
        let edited = try apply(command, to: project)
        XCTAssertEqual(edited.validate(), .valid)
    } catch let error as EditReducerError {
        guard case .validationFailed(let errors) = error else {
            XCTFail("Expected validationFailed, got \(error)")
            return
        }
        XCTAssertFalse(errors.isEmpty)
    }
}

private func makeValidCommandCases(seed: Int) throws -> [EditCommandCase] {
    let fixture = try makeEditFixture(seed: seed)
    let addTrackID = try editUUID(seed * 1_000 + 20)
    let addClipID = try editUUID(seed * 1_000 + 21)
    let addClip = try makeEditClip(id: addClipID, mediaID: fixture.mediaID, startFrame: 20)

    return try makeClipCommandCases(fixture: fixture, addClip: addClip)
        + makeTrackCommandCases(fixture: fixture, addTrackID: addTrackID)
        + makeProjectCommandCases(fixture: fixture, seed: seed)
}

private func makeClipCommandCases(
    fixture: EditFixture,
    addClip: Clip
) throws -> [EditCommandCase] {
    var cases: [EditCommandCase] = []
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .addClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: addClip
            )
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .removeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID
            )
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .moveClip(
                sequenceID: fixture.sequenceID,
                sourceTrackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                destinationTrackID: fixture.videoTrackID,
                timelineRange: try editRange(startFrame: 12, durationFrames: 6)
            )
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .trimClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                sourceRange: try editRange(startFrame: 2, durationFrames: 5),
                timelineRange: try editRange(startFrame: 0, durationFrames: 5)
            )
        )
    )
    return cases
}

private func makeTrackCommandCases(
    fixture: EditFixture,
    addTrackID: UUID
) -> [EditCommandCase] {
    var cases: [EditCommandCase] = []
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .addTrack(
                sequenceID: fixture.sequenceID,
                track: Track(id: addTrackID, kind: .video, items: [])
            )
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .removeTrack(sequenceID: fixture.sequenceID, trackID: fixture.audioTrackID)
        )
    )
    return cases
}

private func makeProjectCommandCases(
    fixture: EditFixture,
    seed: Int
) throws -> [EditCommandCase] {
    let settings = ProjectSettings(
        frameRate: try FrameRate(frames: 30),
        resolution: PixelDimensions(width: 1_280, height: 720),
        colorSpace: .sRGB,
        audioSampleRate: 44_100
    )

    var cases: [EditCommandCase] = []
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .renameSequence(
                sequenceID: fixture.sequenceID,
                name: "Generated \(seed)"
            )
        )
    )
    cases.append(
        EditCommandCase(project: fixture.project, command: .setProjectSettings(settings))
    )
    return cases
}

private func makeEditFixture(seed: Int) throws -> EditFixture {
    let base = seed * 1_000
    let mediaID = try editUUID(base + 1)
    let sequenceID = try editUUID(base + 2)
    let videoTrackID = try editUUID(base + 3)
    let audioTrackID = try editUUID(base + 4)
    let clipID = try editUUID(base + 5)
    let media = try makeEditMediaRef(id: mediaID)
    let clip = try makeEditClip(id: clipID, mediaID: mediaID, startFrame: 0)
    let videoTrack = Track(id: videoTrackID, kind: .video, items: [.clip(clip)])
    let audioTrack = Track(id: audioTrackID, kind: .audio, items: [])
    let sequence = Sequence(
        id: sequenceID,
        name: "Sequence \(seed)",
        videoTracks: [videoTrack],
        audioTracks: [audioTrack],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = Project(
        schemaVersion: 1,
        settings: try makeEditSettings(),
        mediaPool: [media],
        sequences: [sequence]
    )

    return EditFixture(
        project: project,
        sequenceID: sequenceID,
        videoTrackID: videoTrackID,
        audioTrackID: audioTrackID,
        clipID: clipID,
        mediaID: mediaID
    )
}

private func makeEditSettings() throws -> ProjectSettings {
    ProjectSettings(
        frameRate: try FrameRate(frames: 24),
        resolution: PixelDimensions(width: 1_920, height: 1_080),
        colorSpace: .rec709,
        audioSampleRate: 48_000
    )
}

private func makeEditMediaRef(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 24),
            duration: try editTime(240),
            colorSpace: .rec709,
            audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func makeEditClip(
    id: UUID,
    mediaID: UUID,
    startFrame: Int64,
    durationFrames: Int64 = 10,
    kind: TrackKind = .video
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try editRange(startFrame: 0, durationFrames: durationFrames),
        timelineRange: try editRange(startFrame: startFrame, durationFrames: durationFrames),
        kind: kind,
        name: "Clip \(id.uuidString)"
    )
}

private func editRange(startFrame: Int64, durationFrames: Int64) throws -> TimeRange {
    try TimeRange(start: editTime(startFrame), duration: editTime(durationFrames))
}

private func editTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

private func editUUID(_ value: Int) throws -> UUID {
    let uuidString = String(format: "00000000-0000-0000-0000-%012d", value)
    return try XCTUnwrap(UUID(uuidString: uuidString))
}
