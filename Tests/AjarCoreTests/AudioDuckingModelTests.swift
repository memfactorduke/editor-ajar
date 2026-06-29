// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class AudioDuckingModelTests: XCTestCase {
    func testFRAUD004AudioDuckingRoundTripsThroughProjectCodec() throws {
        let fixture = try makeAudioDuckingFixture(seed: 700)
        let rule = try duckingRule(
            triggerTrackID: fixture.triggerTrackID,
            targetTrackIDs: [fixture.targetTrackID]
        )
        let project = try makeAudioDuckingProject(fixture: fixture, audioDucking: [rule])
        let package = try AjarProjectCodec.encode(project)
        let loadedProject = try editableDuckingProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let sequence = try duckingSequence(in: loadedProject, id: fixture.sequenceID)

        XCTAssertEqual(loadedProject, project)
        XCTAssertEqual(sequence.audioDucking, [rule])
    }

    func testFRPROJ005FRAUD004LegacySequenceDefaultsToNoAudioDucking() throws {
        let fixture = try makeAudioDuckingFixture(seed: 701)
        let rule = try duckingRule(
            triggerTrackID: fixture.triggerTrackID,
            targetTrackIDs: [fixture.targetTrackID]
        )
        let project = try makeAudioDuckingProject(fixture: fixture, audioDucking: [rule])
        let package = try AjarProjectCodec.encode(project)
        let legacyProjectJSON = try duckingProjectJSONWithoutAudioDucking(package.projectJSON)
        let loadedProject = try editableDuckingProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let sequence = try duckingSequence(in: loadedProject, id: fixture.sequenceID)

        XCTAssertEqual(sequence.audioDucking, [])
    }

    func testFRAUD004SetAndClearSequenceAudioDuckingRoutesThroughUndoableHistory() throws {
        let fixture = try makeAudioDuckingFixture(seed: 702)
        let rule = try duckingRule(
            triggerTrackID: fixture.triggerTrackID,
            targetTrackIDs: [fixture.targetTrackID]
        )
        var setHistory = EditHistory(project: fixture.project)
        let edited = try setHistory.apply(
            .setSequenceAudioDucking(sequenceID: fixture.sequenceID, ducking: [rule])
        )

        XCTAssertEqual(
            try duckingSequence(in: edited, id: fixture.sequenceID).audioDucking,
            [rule]
        )
        XCTAssertEqual(setHistory.undo(), fixture.project)
        XCTAssertEqual(try setHistory.redo(), edited)

        var clearHistory = EditHistory(project: edited)
        let cleared = try clearHistory.apply(
            .clearSequenceAudioDucking(sequenceID: fixture.sequenceID)
        )

        XCTAssertEqual(
            try duckingSequence(in: cleared, id: fixture.sequenceID).audioDucking,
            []
        )
        XCTAssertEqual(clearHistory.undo(), edited)
        XCTAssertEqual(try clearHistory.redo(), cleared)
    }

    func testNFRSTAB003InvalidAudioDuckingReturnsTypedCommandError() throws {
        let fixture = try makeAudioDuckingFixture(seed: 703)
        let invalidRule = try duckingRule(
            triggerTrackID: fixture.triggerTrackID,
            targetTrackIDs: [fixture.targetTrackID],
            threshold: RationalValue(-1)
        )

        XCTAssertThrowsError(
            try apply(
                .setSequenceAudioDucking(
                    sequenceID: fixture.sequenceID,
                    ducking: [invalidRule]
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .invalidAudioDucking(
                        sequenceID: fixture.sequenceID,
                        ruleIndex: 0,
                        error: .thresholdOutOfRange(
                            value: RationalValue(-1),
                            minimum: .zero,
                            maximum: RationalValue(4)
                        )
                    )
                )
            )
        }
    }

    func testFRAUD004ProjectValidationRejectsInvalidStoredAudioDucking() throws {
        let fixture = try makeAudioDuckingFixture(seed: 704)
        let missingTargetID = try editUUID(704_999)
        let invalidRule = try duckingRule(
            triggerTrackID: fixture.triggerTrackID,
            targetTrackIDs: [missingTargetID]
        )
        let project = try makeAudioDuckingProject(fixture: fixture, audioDucking: [invalidRule])

        XCTAssertEqual(
            duckingValidationErrors(from: project),
            [
                .invalidAudioDucking(
                    sequenceID: fixture.sequenceID,
                    ruleIndex: 0,
                    error: .targetTrackMissing(missingTargetID)
                )
            ]
        )
    }
}

private struct AudioDuckingFixture {
    let project: Project
    let sequenceID: UUID
    let triggerTrackID: UUID
    let targetTrackID: UUID
}

private enum AudioDuckingTestError: Error {
    case expectedEditableProject
    case expectedInvalidProject
}

private func makeAudioDuckingFixture(seed: Int) throws -> AudioDuckingFixture {
    let base = seed * 1_000
    let sequenceID = try editUUID(base + 1)
    let triggerTrackID = try editUUID(base + 2)
    let targetTrackID = try editUUID(base + 3)
    let triggerTrack = Track(id: triggerTrackID, kind: .audio, items: [])
    let targetTrack = Track(id: targetTrackID, kind: .audio, items: [])
    let project = try makeAudioDuckingProject(
        sequenceID: sequenceID,
        audioTracks: [triggerTrack, targetTrack],
        audioDucking: []
    )

    return AudioDuckingFixture(
        project: project,
        sequenceID: sequenceID,
        triggerTrackID: triggerTrackID,
        targetTrackID: targetTrackID
    )
}

private func makeAudioDuckingProject(
    fixture: AudioDuckingFixture,
    audioDucking: [AudioDuckingRule]
) throws -> Project {
    let sequence = try duckingSequence(in: fixture.project, id: fixture.sequenceID)
    return try makeAudioDuckingProject(
        sequenceID: fixture.sequenceID,
        audioTracks: sequence.audioTracks,
        audioDucking: audioDucking
    )
}

private func makeAudioDuckingProject(
    sequenceID: UUID,
    audioTracks: [Track],
    audioDucking: [AudioDuckingRule]
) throws -> Project {
    let sequence = Sequence(
        id: sequenceID,
        name: "Audio Ducking",
        videoTracks: [],
        audioTracks: audioTracks,
        markers: [],
        audioDucking: audioDucking,
        timebase: try FrameRate(frames: 24)
    )
    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 1_920, height: 1_080),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [],
        sequences: [sequence]
    )
}

private func duckingRule(
    triggerTrackID: UUID,
    targetTrackIDs: [UUID],
    threshold: RationalValue? = nil
) throws -> AudioDuckingRule {
    let resolvedThreshold: RationalValue
    if let threshold {
        resolvedThreshold = threshold
    } else {
        resolvedThreshold = try RationalValue(numerator: 1, denominator: 2)
    }
    return AudioDuckingRule(
        triggerTrackID: triggerTrackID,
        targetTrackIDs: targetTrackIDs,
        threshold: resolvedThreshold,
        reductionGain: try RationalValue(numerator: 1, denominator: 4),
        attack: .zero,
        release: .zero,
        hold: .zero
    )
}

private func duckingSequence(in project: Project, id: UUID) throws -> Sequence {
    try XCTUnwrap(project.sequences.first { $0.id == id })
}

private func editableDuckingProject(from result: AjarProjectLoadResult) throws -> Project {
    guard case .editable(let project) = result else {
        XCTFail("Expected editable project")
        throw AudioDuckingTestError.expectedEditableProject
    }
    return project
}

private func duckingValidationErrors(from project: Project) -> [ProjectValidationError] {
    switch project.validate() {
    case .valid:
        XCTFail("Expected invalid project")
        return []
    case .invalid(let errors):
        return errors
    }
}

private func duckingProjectJSONWithoutAudioDucking(_ projectJSON: Data) throws -> Data {
    var document = try XCTUnwrap(
        JSONSerialization.jsonObject(with: projectJSON) as? [String: Any]
    )
    var sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
    var sequence = try XCTUnwrap(sequences.first)

    sequence.removeValue(forKey: "audioDucking")
    sequences[0] = sequence
    document["sequences"] = sequences
    document["schemaVersion"] = 1

    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}
