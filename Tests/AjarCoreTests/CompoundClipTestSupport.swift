// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

struct CompoundClipFixture {
    let project: Project
    let outerSequenceID: UUID
    let outerTrackID: UUID
    let compoundClipID: UUID
    let innerSequenceID: UUID
    let innerTrackID: UUID
    let mediaID: UUID
}

struct SelfCycleFixture {
    let project: Project
    let sequenceID: UUID
    let trackID: UUID
    let clipID: UUID
}

struct TransitiveCycleFixture {
    let project: Project
    let firstSequenceID: UUID
    let firstTrackID: UUID
    let firstClipID: UUID
    let secondSequenceID: UUID
    let secondTrackID: UUID
    let secondClipID: UUID
}

struct ThreeNodeCycleFixture {
    let project: Project
    let firstSequenceID: UUID
    let firstTrackID: UUID
    let firstClipID: UUID
    let secondSequenceID: UUID
    let secondTrackID: UUID
    let secondClipID: UUID
    let thirdSequenceID: UUID
    let thirdTrackID: UUID
    let thirdClipID: UUID
}

struct CompoundInsertFixture {
    let project: Project
    let outerSequenceID: UUID
    let outerTrackID: UUID
    let compoundClipID: UUID
    let innerSequenceID: UUID
}

struct CompoundInsertCycleFixture {
    let project: Project
    let sourceSequenceID: UUID
    let sourceTrackID: UUID
    let sourceClipID: UUID
    let targetSequenceID: UUID
    let targetTrackID: UUID
    let insertedClipID: UUID
}

struct InnerSequenceSpec {
    let id: UUID
    let trackID: UUID
    let clipID: UUID
    let mediaID: UUID
    let durationFrames: Int64
    let timebase: FrameRate
}

func makeCompoundClipFixture(seed: Int) throws -> CompoundClipFixture {
    let base = seed * 1_000
    let mediaID = try editUUID(base + 1)
    let outerSequenceID = try editUUID(base + 2)
    let outerTrackID = try editUUID(base + 3)
    let compoundClipID = try editUUID(base + 4)
    let innerSequenceID = try editUUID(base + 5)
    let innerTrackID = try editUUID(base + 6)
    let media = try makeEditMediaRef(id: mediaID)
    let innerSequence = try makeInnerSequence(
        InnerSequenceSpec(
            id: innerSequenceID,
            trackID: innerTrackID,
            clipID: try editUUID(base + 7),
            mediaID: mediaID,
            durationFrames: 12,
            timebase: FrameRate(frames: 30)
        )
    )
    let compoundClip = try makeCompoundClip(
        id: compoundClipID,
        targetSequenceID: innerSequenceID,
        startFrame: 3,
        durationFrames: 12
    )
    let outerTrack = Track(id: outerTrackID, kind: .video, items: [.clip(compoundClip)])
    let outerSequence = Sequence(
        id: outerSequenceID,
        name: "Outer Compound Sequence",
        videoTracks: [outerTrack],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [media],
        sequences: [outerSequence, innerSequence]
    )

    return CompoundClipFixture(
        project: project,
        outerSequenceID: outerSequenceID,
        outerTrackID: outerTrackID,
        compoundClipID: compoundClipID,
        innerSequenceID: innerSequenceID,
        innerTrackID: innerTrackID,
        mediaID: mediaID
    )
}

func makeCompoundInsertFixture(seed: Int) throws -> CompoundInsertFixture {
    let base = seed * 1_000
    let mediaID = try editUUID(base + 1)
    let outerSequenceID = try editUUID(base + 2)
    let outerTrackID = try editUUID(base + 3)
    let innerSequenceID = try editUUID(base + 4)
    let innerTrackID = try editUUID(base + 5)
    let media = try makeEditMediaRef(id: mediaID)
    let outerSequence = Sequence(
        id: outerSequenceID,
        name: "Outer Insert Sequence",
        videoTracks: [Track(id: outerTrackID, kind: .video, items: [])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let innerSequence = try makeInnerSequence(
        InnerSequenceSpec(
            id: innerSequenceID,
            trackID: innerTrackID,
            clipID: try editUUID(base + 6),
            mediaID: mediaID,
            durationFrames: 12,
            timebase: FrameRate(frames: 24)
        )
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [media],
        sequences: [outerSequence, innerSequence]
    )

    return CompoundInsertFixture(
        project: project,
        outerSequenceID: outerSequenceID,
        outerTrackID: outerTrackID,
        compoundClipID: try editUUID(base + 7),
        innerSequenceID: innerSequenceID
    )
}

func makeSelfReferencingCompoundProject(seed: Int) throws -> SelfCycleFixture {
    let base = seed * 1_000
    let sequenceID = try editUUID(base + 1)
    let trackID = try editUUID(base + 2)
    let clipID = try editUUID(base + 3)
    let clip = try makeCompoundClip(
        id: clipID,
        targetSequenceID: sequenceID,
        startFrame: 0,
        durationFrames: 8
    )
    let sequence = Sequence(
        id: sequenceID,
        name: "Self Cycle",
        videoTracks: [Track(id: trackID, kind: .video, items: [.clip(clip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [],
        sequences: [sequence]
    )

    return SelfCycleFixture(
        project: project,
        sequenceID: sequenceID,
        trackID: trackID,
        clipID: clipID
    )
}

func makeTransitiveCompoundCycleProject(seed: Int) throws -> TransitiveCycleFixture {
    let base = seed * 1_000
    let firstSequenceID = try editUUID(base + 1)
    let firstTrackID = try editUUID(base + 2)
    let firstClipID = try editUUID(base + 3)
    let secondSequenceID = try editUUID(base + 4)
    let secondTrackID = try editUUID(base + 5)
    let secondClipID = try editUUID(base + 6)
    let firstClip = try makeCompoundClip(
        id: firstClipID,
        targetSequenceID: secondSequenceID,
        startFrame: 0,
        durationFrames: 8
    )
    let secondClip = try makeCompoundClip(
        id: secondClipID,
        targetSequenceID: firstSequenceID,
        startFrame: 0,
        durationFrames: 8
    )
    let firstSequence = Sequence(
        id: firstSequenceID,
        name: "Cycle A",
        videoTracks: [Track(id: firstTrackID, kind: .video, items: [.clip(firstClip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let secondSequence = Sequence(
        id: secondSequenceID,
        name: "Cycle B",
        videoTracks: [Track(id: secondTrackID, kind: .video, items: [.clip(secondClip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [],
        sequences: [firstSequence, secondSequence]
    )

    return TransitiveCycleFixture(
        project: project,
        firstSequenceID: firstSequenceID,
        firstTrackID: firstTrackID,
        firstClipID: firstClipID,
        secondSequenceID: secondSequenceID,
        secondTrackID: secondTrackID,
        secondClipID: secondClipID
    )
}

func makeThreeNodeCompoundCycleProject(seed: Int) throws -> ThreeNodeCycleFixture {
    let base = seed * 1_000
    let firstSequenceID = try editUUID(base + 1)
    let firstTrackID = try editUUID(base + 2)
    let firstClipID = try editUUID(base + 3)
    let secondSequenceID = try editUUID(base + 4)
    let secondTrackID = try editUUID(base + 5)
    let secondClipID = try editUUID(base + 6)
    let thirdSequenceID = try editUUID(base + 7)
    let thirdTrackID = try editUUID(base + 8)
    let thirdClipID = try editUUID(base + 9)
    let firstSequence = try makeCompoundReferenceSequence(
        id: firstSequenceID,
        name: "Cycle A",
        trackID: firstTrackID,
        clipID: firstClipID,
        targetSequenceID: secondSequenceID
    )
    let secondSequence = try makeCompoundReferenceSequence(
        id: secondSequenceID,
        name: "Cycle B",
        trackID: secondTrackID,
        clipID: secondClipID,
        targetSequenceID: thirdSequenceID
    )
    let thirdSequence = try makeCompoundReferenceSequence(
        id: thirdSequenceID,
        name: "Cycle C",
        trackID: thirdTrackID,
        clipID: thirdClipID,
        targetSequenceID: firstSequenceID
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [],
        sequences: [firstSequence, secondSequence, thirdSequence]
    )

    return ThreeNodeCycleFixture(
        project: project,
        firstSequenceID: firstSequenceID,
        firstTrackID: firstTrackID,
        firstClipID: firstClipID,
        secondSequenceID: secondSequenceID,
        secondTrackID: secondTrackID,
        secondClipID: secondClipID,
        thirdSequenceID: thirdSequenceID,
        thirdTrackID: thirdTrackID,
        thirdClipID: thirdClipID
    )
}

func makeCompoundReferenceSequence(
    id: UUID,
    name: String,
    trackID: UUID,
    clipID: UUID,
    targetSequenceID: UUID
) throws -> Sequence {
    let clip = try makeCompoundClip(
        id: clipID,
        targetSequenceID: targetSequenceID,
        startFrame: 0,
        durationFrames: 8
    )
    return Sequence(
        id: id,
        name: name,
        videoTracks: [Track(id: trackID, kind: .video, items: [.clip(clip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

func makeCompoundInsertCycleFixture(seed: Int) throws -> CompoundInsertCycleFixture {
    let base = seed * 1_000
    let sourceSequenceID = try editUUID(base + 1)
    let sourceTrackID = try editUUID(base + 2)
    let sourceClipID = try editUUID(base + 3)
    let targetSequenceID = try editUUID(base + 4)
    let targetTrackID = try editUUID(base + 5)
    let sourceClip = try makeCompoundClip(
        id: sourceClipID,
        targetSequenceID: targetSequenceID,
        startFrame: 0,
        durationFrames: 8
    )
    let sourceSequence = Sequence(
        id: sourceSequenceID,
        name: "Cycle Insert Source",
        videoTracks: [Track(id: sourceTrackID, kind: .video, items: [.clip(sourceClip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let targetSequence = Sequence(
        id: targetSequenceID,
        name: "Cycle Insert Target",
        videoTracks: [Track(id: targetTrackID, kind: .video, items: [])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [],
        sequences: [sourceSequence, targetSequence]
    )

    return CompoundInsertCycleFixture(
        project: project,
        sourceSequenceID: sourceSequenceID,
        sourceTrackID: sourceTrackID,
        sourceClipID: sourceClipID,
        targetSequenceID: targetSequenceID,
        targetTrackID: targetTrackID,
        insertedClipID: try editUUID(base + 6)
    )
}

func makeInnerSequence(_ spec: InnerSequenceSpec) throws -> Sequence {
    let clip = try makeEditClip(
        id: spec.clipID,
        mediaID: spec.mediaID,
        startFrame: 0,
        durationFrames: spec.durationFrames
    )
    return Sequence(
        id: spec.id,
        name: "Inner Compound Sequence",
        videoTracks: [Track(id: spec.trackID, kind: .video, items: [.clip(clip)])],
        audioTracks: [],
        markers: [],
        timebase: spec.timebase
    )
}

func makeCompoundClip(
    id: UUID,
    targetSequenceID: UUID,
    startFrame: Int64,
    durationFrames: Int64
) throws -> Clip {
    Clip(
        id: id,
        source: .sequence(id: targetSequenceID),
        sourceRange: try editRange(startFrame: 0, durationFrames: durationFrames),
        timelineRange: try editRange(startFrame: startFrame, durationFrames: durationFrames),
        kind: .video,
        name: "Compound \(id.uuidString)"
    )
}

func replacingInnerSequenceDuration(
    in project: Project,
    fixture: CompoundClipFixture,
    durationFrames: Int64
) throws -> Project {
    let replacement = try makeInnerSequence(
        InnerSequenceSpec(
            id: fixture.innerSequenceID,
            trackID: fixture.innerTrackID,
            clipID: try editUUID(122_999),
            mediaID: fixture.mediaID,
            durationFrames: durationFrames,
            timebase: FrameRate(frames: 30)
        )
    )

    return Project(
        schemaVersion: project.schemaVersion,
        settings: project.settings,
        mediaPool: project.mediaPool,
        sequences: project.sequences.map { sequence in
            sequence.id == fixture.innerSequenceID ? replacement : sequence
        }
    )
}

func requiredCompoundClip(
    in project: Project,
    fixture: CompoundClipFixture
) throws -> Clip {
    try requiredClip(
        fixture.compoundClipID,
        trackID: fixture.outerTrackID,
        in: project,
        sequenceID: fixture.outerSequenceID
    )
}

func compoundValidationErrors(from project: Project) -> [ProjectValidationError] {
    switch project.validate() {
    case .valid:
        XCTFail("Expected invalid project")
        return []
    case .invalid(let errors):
        return errors
    }
}

func compoundEditableProject(from result: AjarProjectLoadResult) throws -> Project {
    switch result {
    case .editable(let project):
        return project
    case .readOnly:
        XCTFail("Expected editable project")
        throw AjarProjectCodecError.malformedProjectJSON("unexpected read-only result")
    }
}

func compoundTestEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}

func compoundSettings() throws -> ProjectSettings {
    ProjectSettings(
        frameRate: try FrameRate(frames: 24),
        resolution: PixelDimensions(width: 1_920, height: 1_080),
        colorSpace: .rec709,
        audioSampleRate: 48_000
    )
}
