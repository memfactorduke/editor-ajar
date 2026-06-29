// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class MakeCompoundClipCommandTests: XCTestCase {
    func testFRCMP001MakeCompoundClipPreservesMultiTrackSelectionLayout() throws {
        let fixture = try makeCompoundSelectionFixture(seed: 134)
        var history = EditHistory(project: fixture.project)

        let edited = try history.apply(
            makeCompoundCommand(fixture: fixture, selectedClips: fixture.selectedClips)
        )

        let outerSequence = try requiredSequence(fixture.sequenceID, in: edited)
        let nestedSequence = try requiredSequence(fixture.compoundSequenceID, in: edited)
        let compoundClip = try requiredClip(
            fixture.compoundClipID,
            trackID: fixture.bottomVideoTrackID,
            in: edited,
            sequenceID: fixture.sequenceID
        )

        XCTAssertEqual(edited.validate(), .valid)
        XCTAssertEqual(compoundClip.source, .sequence(id: fixture.compoundSequenceID))
        try assertRange(compoundClip.sourceRange, startFrame: 0, durationFrames: 9)
        try assertRange(compoundClip.timelineRange, startFrame: 6, durationFrames: 9)
        XCTAssertEqual(try compoundClip.resolvedSourceDuration(in: edited), try editTime(9))
        XCTAssertNil(clip(fixture.bottomClipID, in: outerSequence.videoTracks[0]))
        XCTAssertNil(clip(fixture.topClipID, in: outerSequence.videoTracks[1]))
        XCTAssertNil(clip(fixture.audioClipID, in: outerSequence.audioTracks[0]))
        XCTAssertEqual(
            outerSequence.markers.map(\.id),
            [fixture.timelineMarkerID]
        )

        let nestedBottom = try XCTUnwrap(
            clip(fixture.bottomClipID, in: nestedSequence.videoTracks[0])
        )
        let nestedTop = try XCTUnwrap(
            clip(fixture.topClipID, in: nestedSequence.videoTracks[1])
        )
        let nestedAudio = try XCTUnwrap(
            clip(fixture.audioClipID, in: nestedSequence.audioTracks[0])
        )
        try assertRange(nestedBottom.timelineRange, startFrame: 0, durationFrames: 4)
        try assertRange(nestedTop.timelineRange, startFrame: 4, durationFrames: 5)
        try assertRange(nestedAudio.timelineRange, startFrame: 2, durationFrames: 6)
        XCTAssertEqual(
            nestedSequence.videoTracks.map(\.id),
            [
                fixture.bottomVideoTrackID,
                fixture.topVideoTrackID
            ]
        )
        XCTAssertEqual(nestedSequence.audioTracks.map(\.id), [fixture.audioTrackID])
        XCTAssertEqual(nestedSequence.markers.map(\.id), [fixture.clipMarkerID])
        XCTAssertEqual(nestedSequence.markers[0].time, try editTime(1))

        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
    }

    func testFRCMP001MakeCompoundClipWrapsSingleClipSelection() throws {
        let fixture = try makeEditFixture(seed: 160)
        let compoundSequenceID = try editUUID(160_901)
        let compoundClipID = try editUUID(160_902)

        let edited = try apply(
            .makeCompoundClip(
                sequenceID: fixture.sequenceID,
                compoundSequenceID: compoundSequenceID,
                compoundClipID: compoundClipID,
                selectedClips: [
                    ClipReference(trackID: fixture.videoTrackID, clipID: fixture.clipID)
                ],
                name: "FR-CMP-001 Single"
            ),
            to: fixture.project
        )

        let compoundClip = try requiredClip(
            compoundClipID,
            trackID: fixture.videoTrackID,
            in: edited,
            sequenceID: fixture.sequenceID
        )
        let nestedSequence = try requiredSequence(compoundSequenceID, in: edited)

        XCTAssertEqual(compoundClip.source, .sequence(id: compoundSequenceID))
        try assertRange(compoundClip.timelineRange, startFrame: 0, durationFrames: 10)
        XCTAssertNotNil(clip(fixture.clipID, in: nestedSequence.videoTracks[0]))
    }

    func testFRCMP001MakeCompoundClipRoundTripsThroughProjectCodec() throws {
        let fixture = try makeCompoundSelectionFixture(seed: 161)
        let edited = try apply(
            makeCompoundCommand(fixture: fixture, selectedClips: fixture.selectedClips),
            to: fixture.project
        )
        let package = try AjarProjectCodec.encode(edited)
        let loaded = try compoundEditableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )

        XCTAssertEqual(loaded, edited)
    }

    func testFRCMP001MakeCompoundClipRejectsEmptySelection() throws {
        let fixture = try makeEditFixture(seed: 162)

        XCTAssertThrowsError(
            try apply(
                .makeCompoundClip(
                    sequenceID: fixture.sequenceID,
                    compoundSequenceID: try editUUID(162_901),
                    compoundClipID: try editUUID(162_902),
                    selectedClips: [],
                    name: "FR-CMP-001 Empty"
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.compoundSelectionEmpty(sequenceID: fixture.sequenceID))
            )
        }
    }

    func testFRCMP001MakeCompoundClipRejectsDuplicateSelectionReference() throws {
        let fixture = try makeEditFixture(seed: 163)
        let reference = ClipReference(trackID: fixture.videoTrackID, clipID: fixture.clipID)

        XCTAssertThrowsError(
            try apply(
                .makeCompoundClip(
                    sequenceID: fixture.sequenceID,
                    compoundSequenceID: try editUUID(163_901),
                    compoundClipID: try editUUID(163_902),
                    selectedClips: [reference, reference],
                    name: "FR-CMP-001 Duplicate"
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .duplicateCompoundSelectionReference(
                        trackID: fixture.videoTrackID,
                        clipID: fixture.clipID
                    )
                )
            )
        }
    }

    func testFRCMP001MakeCompoundClipRejectsAudioOnlySelection() throws {
        let fixture = try makeLinkedEditFixture(seed: 164)

        XCTAssertThrowsError(
            try apply(
                .makeCompoundClip(
                    sequenceID: fixture.sequenceID,
                    compoundSequenceID: try editUUID(164_901),
                    compoundClipID: try editUUID(164_902),
                    selectedClips: [
                        ClipReference(trackID: fixture.audioTrackID, clipID: fixture.audioClipID)
                    ],
                    name: "FR-CMP-001 Audio Only"
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.compoundSelectionRequiresVideo(sequenceID: fixture.sequenceID))
            )
        }
    }

    func testFRCMP001MakeCompoundClipRejectsSelfReferenceThroughValidation() throws {
        let fixture = try makeDegenerateCompoundSelectionFixture(seed: 165)

        XCTAssertThrowsError(
            try apply(
                makeCompoundCommand(
                    fixture: fixture,
                    selectedClips: fixture.selectedClips
                ),
                to: fixture.project
            )
        ) { error in
            guard case .validationFailed(let errors) = error as? EditReducerError else {
                XCTFail("Expected validationFailed, got \(error)")
                return
            }
            XCTAssertTrue(
                errors.contains(
                    .compoundSequenceCycle(
                        sequenceID: fixture.compoundSequenceID,
                        trackID: fixture.bottomVideoTrackID,
                        clipID: fixture.bottomClipID,
                        targetID: fixture.compoundSequenceID
                    )
                )
            )
        }
    }
}

private struct CompoundSelectionFixture {
    let project: Project
    let sequenceID: UUID
    let bottomVideoTrackID: UUID
    let topVideoTrackID: UUID
    let audioTrackID: UUID
    let bottomClipID: UUID
    let topClipID: UUID
    let audioClipID: UUID
    let timelineMarkerID: UUID
    let clipMarkerID: UUID
    let compoundSequenceID: UUID
    let compoundClipID: UUID
    let selectedClips: [ClipReference]
}

private struct CompoundSelectionIDs {
    let mediaID: UUID
    let sequenceID: UUID
    let bottomVideoTrackID: UUID
    let topVideoTrackID: UUID
    let audioTrackID: UUID
    let bottomClipID: UUID
    let topClipID: UUID
    let audioClipID: UUID
    let timelineMarkerID: UUID
    let clipMarkerID: UUID
    let compoundSequenceID: UUID
    let compoundClipID: UUID
}

private struct CompoundSelectionClips {
    let bottom: Clip
    let top: Clip
    let audio: Clip
}

private func makeCompoundSelectionFixture(seed: Int) throws -> CompoundSelectionFixture {
    try makeCompoundSelectionFixture(seed: seed, degenerateSelfReference: false)
}

private func makeDegenerateCompoundSelectionFixture(seed: Int) throws -> CompoundSelectionFixture {
    try makeCompoundSelectionFixture(seed: seed, degenerateSelfReference: true)
}

private func makeCompoundSelectionFixture(
    seed: Int,
    degenerateSelfReference: Bool
) throws -> CompoundSelectionFixture {
    let ids = try makeCompoundSelectionIDs(seed: seed)
    let media = try makeEditMediaRef(id: ids.mediaID)
    let clips = try makeCompoundSelectionClips(
        ids: ids,
        degenerateSelfReference: degenerateSelfReference
    )
    let sequence = try makeCompoundSelectionSequence(ids: ids, clips: clips)
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [media],
        sequences: [sequence]
    )

    return CompoundSelectionFixture(
        project: project,
        sequenceID: ids.sequenceID,
        bottomVideoTrackID: ids.bottomVideoTrackID,
        topVideoTrackID: ids.topVideoTrackID,
        audioTrackID: ids.audioTrackID,
        bottomClipID: ids.bottomClipID,
        topClipID: ids.topClipID,
        audioClipID: ids.audioClipID,
        timelineMarkerID: ids.timelineMarkerID,
        clipMarkerID: ids.clipMarkerID,
        compoundSequenceID: ids.compoundSequenceID,
        compoundClipID: ids.compoundClipID,
        selectedClips: makeCompoundSelectionReferences(ids: ids)
    )
}

private func makeCompoundSelectionIDs(seed: Int) throws -> CompoundSelectionIDs {
    let base = seed * 1_000
    return CompoundSelectionIDs(
        mediaID: try editUUID(base + 1),
        sequenceID: try editUUID(base + 2),
        bottomVideoTrackID: try editUUID(base + 3),
        topVideoTrackID: try editUUID(base + 4),
        audioTrackID: try editUUID(base + 5),
        bottomClipID: try editUUID(base + 6),
        topClipID: try editUUID(base + 7),
        audioClipID: try editUUID(base + 8),
        timelineMarkerID: try editUUID(base + 9),
        clipMarkerID: try editUUID(base + 10),
        compoundSequenceID: try editUUID(base + 11),
        compoundClipID: try editUUID(base + 12)
    )
}

private func makeCompoundSelectionClips(
    ids: CompoundSelectionIDs,
    degenerateSelfReference: Bool
) throws -> CompoundSelectionClips {
    CompoundSelectionClips(
        bottom: try makeSelectionClip(
            id: ids.bottomClipID,
            source: compoundBottomClipSource(ids: ids, degenerateSelfReference),
            startFrame: 6,
            durationFrames: 4,
            kind: .video
        ),
        top: try makeSelectionClip(
            id: ids.topClipID,
            source: .media(id: ids.mediaID),
            startFrame: 10,
            durationFrames: 5,
            kind: .video
        ),
        audio: try makeSelectionClip(
            id: ids.audioClipID,
            source: .media(id: ids.mediaID),
            startFrame: 8,
            durationFrames: 6,
            kind: .audio
        )
    )
}

private func compoundBottomClipSource(
    ids: CompoundSelectionIDs,
    _ degenerateSelfReference: Bool
) -> ClipSource {
    degenerateSelfReference ? .sequence(id: ids.compoundSequenceID) : .media(id: ids.mediaID)
}

private func makeCompoundSelectionSequence(
    ids: CompoundSelectionIDs,
    clips: CompoundSelectionClips
) throws -> Sequence {
    Sequence(
        id: ids.sequenceID,
        name: "FR-CMP-001 Source",
        videoTracks: [
            Track(id: ids.bottomVideoTrackID, kind: .video, items: [.clip(clips.bottom)]),
            Track(id: ids.topVideoTrackID, kind: .video, items: [.clip(clips.top)])
        ],
        audioTracks: [
            Track(id: ids.audioTrackID, kind: .audio, items: [.clip(clips.audio)])
        ],
        markers: try makeCompoundSelectionMarkers(ids: ids),
        timebase: try FrameRate(frames: 24)
    )
}

private func makeCompoundSelectionMarkers(ids: CompoundSelectionIDs) throws -> [Marker] {
    [
        Marker(
            id: ids.timelineMarkerID,
            time: try editTime(7),
            name: "Outer timeline marker",
            anchor: .timeline
        ),
        Marker(
            id: ids.clipMarkerID,
            time: try editTime(7),
            name: "Selected clip marker",
            anchor: .clip(trackID: ids.bottomVideoTrackID, clipID: ids.bottomClipID)
        )
    ]
}

private func makeCompoundSelectionReferences(
    ids: CompoundSelectionIDs
) -> [ClipReference] {
    [
        ClipReference(trackID: ids.bottomVideoTrackID, clipID: ids.bottomClipID),
        ClipReference(trackID: ids.topVideoTrackID, clipID: ids.topClipID),
        ClipReference(trackID: ids.audioTrackID, clipID: ids.audioClipID)
    ]
}

private func makeSelectionClip(
    id: UUID,
    source: ClipSource,
    startFrame: Int64,
    durationFrames: Int64,
    kind: TrackKind
) throws -> Clip {
    Clip(
        id: id,
        source: source,
        sourceRange: try editRange(startFrame: 0, durationFrames: durationFrames),
        timelineRange: try editRange(startFrame: startFrame, durationFrames: durationFrames),
        kind: kind,
        name: "Selection \(id.uuidString)"
    )
}

private func makeCompoundCommand(
    fixture: CompoundSelectionFixture,
    selectedClips: [ClipReference]
) -> EditCommand {
    .makeCompoundClip(
        sequenceID: fixture.sequenceID,
        compoundSequenceID: fixture.compoundSequenceID,
        compoundClipID: fixture.compoundClipID,
        selectedClips: selectedClips,
        name: "FR-CMP-001 Compound"
    )
}

private func requiredSequence(_ sequenceID: UUID, in project: Project) throws -> Sequence {
    try XCTUnwrap(project.sequences.first { $0.id == sequenceID })
}
