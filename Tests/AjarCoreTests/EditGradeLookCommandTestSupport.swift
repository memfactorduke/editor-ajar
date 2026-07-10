// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

struct AudioGradeCommandFixture {
    let project: Project
    let video: ProjectClipReference
    let audio: ProjectClipReference
    let newNodeID: UUID
}

struct GradeCommandFixture {
    let project: Project
    let source: ProjectClipReference
    let target: ProjectClipReference
    let newNodeIDs: [UUID]
}

struct NestedGradeCommandFixture {
    let project: Project
    let source: ProjectClipReference
    let target: ProjectClipReference
    let compound: ProjectClipReference
    let newNodeIDs: [UUID]
}

private struct NestedGradeCommandIdentifiers {
    let mediaID: UUID
    let outerSequenceID: UUID
    let innerSequenceID: UUID
    let sourceTrackID: UUID
    let compoundTrackID: UUID
    let innerTrackID: UUID
    let sourceClipID: UUID
    let compoundClipID: UUID
    let targetClipID: UUID

    init(base: Int) throws {
        mediaID = try editUUID(base + 1)
        outerSequenceID = try editUUID(base + 2)
        innerSequenceID = try editUUID(base + 3)
        sourceTrackID = try editUUID(base + 4)
        compoundTrackID = try editUUID(base + 5)
        innerTrackID = try editUUID(base + 6)
        sourceClipID = try editUUID(base + 7)
        compoundClipID = try editUUID(base + 8)
        targetClipID = try editUUID(base + 9)
    }
}

private struct NestedGradeCommandClips {
    let source: Clip
    let target: Clip
    let compound: Clip
}

func makeNestedGradeCommandFixture(seed: Int) throws -> NestedGradeCommandFixture {
    let base = seed * 1_000
    let ids = try NestedGradeCommandIdentifiers(base: base)
    let media = try makeEditMediaRef(id: ids.mediaID)
    let clips = try makeNestedGradeCommandClips(base: base, ids: ids)
    let sequences = try makeNestedGradeCommandSequences(ids: ids, clips: clips)

    return NestedGradeCommandFixture(
        project: Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: try gradeCommandSettings(),
            mediaPool: [media],
            sequences: [sequences.outer, sequences.inner]
        ),
        source: ProjectClipReference(
            sequenceID: ids.outerSequenceID,
            trackID: ids.sourceTrackID,
            clipID: ids.sourceClipID
        ),
        target: ProjectClipReference(
            sequenceID: ids.innerSequenceID,
            trackID: ids.innerTrackID,
            clipID: ids.targetClipID
        ),
        compound: ProjectClipReference(
            sequenceID: ids.outerSequenceID,
            trackID: ids.compoundTrackID,
            clipID: ids.compoundClipID
        ),
        newNodeIDs: try (base + 300...base + 304).map(editUUID)
    )
}

func makeAudioGradeCommandFixture(seed: Int) throws -> AudioGradeCommandFixture {
    let fixture = try makeLinkedEditFixture(seed: seed)
    let videoNode = ClipEffectNode(
        id: try editUUID(seed * 1_000 + 100),
        definition: .invert(ClipInvertParameters())
    )
    let audioNode = ClipEffectNode(
        id: try editUUID(seed * 1_000 + 101),
        definition: .invert(ClipInvertParameters())
    )
    let withVideoGrade = try apply(
        .addClipEffectNode(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.videoClipID,
            node: videoNode
        ),
        to: fixture.project
    )
    let project = try apply(
        .addClipEffectNode(
            sequenceID: fixture.sequenceID,
            trackID: fixture.audioTrackID,
            clipID: fixture.audioClipID,
            node: audioNode
        ),
        to: withVideoGrade
    )
    return AudioGradeCommandFixture(
        project: project,
        video: ProjectClipReference(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.videoClipID
        ),
        audio: ProjectClipReference(
            sequenceID: fixture.sequenceID,
            trackID: fixture.audioTrackID,
            clipID: fixture.audioClipID
        ),
        newNodeID: try editUUID(seed * 1_000 + 200)
    )
}

private func makeNestedGradeCommandClips(
    base: Int,
    ids: NestedGradeCommandIdentifiers
) throws -> NestedGradeCommandClips {
    let source = try gradeCommandClip(
        id: ids.sourceClipID,
        mediaID: ids.mediaID,
        name: "Outer grade source",
        stack: sourceGradeStack(base: base + 100)
    )
    let target = try gradeCommandClip(
        id: ids.targetClipID,
        mediaID: ids.mediaID,
        name: "Nested target",
        stack: ClipEffectStack(
            nodes: [
                ClipEffectNode(
                    id: try editUUID(base + 200),
                    definition: .gaussianBlur(
                        ClipGaussianBlurParameters(radius: RationalValue(2))
                    )
                )
            ]
        )
    )
    let compound = Clip(
        id: ids.compoundClipID,
        source: .sequence(id: ids.innerSequenceID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Compound grade target"
    )
    return NestedGradeCommandClips(source: source, target: target, compound: compound)
}

private func makeNestedGradeCommandSequences(
    ids: NestedGradeCommandIdentifiers,
    clips: NestedGradeCommandClips
) throws -> (outer: Sequence, inner: Sequence) {
    let outer = Sequence(
        id: ids.outerSequenceID,
        name: "Outer",
        videoTracks: [
            Track(id: ids.compoundTrackID, kind: .video, items: [.clip(clips.compound)]),
            Track(id: ids.sourceTrackID, kind: .video, items: [.clip(clips.source)])
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let inner = Sequence(
        id: ids.innerSequenceID,
        name: "Inner",
        videoTracks: [Track(id: ids.innerTrackID, kind: .video, items: [.clip(clips.target)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    return (outer, inner)
}

func sourceGradeStack(base: Int) throws -> ClipEffectStack {
    ClipEffectStack(
        nodes: [
            ClipEffectNode(
                id: try editUUID(base + 1),
                definition: .gaussianBlur(ClipGaussianBlurParameters(radius: RationalValue(2)))
            ),
            ClipEffectNode(
                id: try editUUID(base + 2),
                definition: .colorAdjust(
                    ClipColorAdjustParameters(brightness: try rational(1, 10))
                )
            ),
            ClipEffectNode(
                id: try editUUID(base + 3),
                definition: .vignette(
                    ClipVignetteParameters(
                        amount: try rational(1, 2),
                        radius: try rational(3, 4),
                        softness: try rational(1, 4)
                    )
                )
            ),
            ClipEffectNode(
                id: try editUUID(base + 4),
                definition: .curves(
                    ClipCurvesEffectParameters(rgb: .rgbSCurve, strength: .one)
                )
            ),
            ClipEffectNode(
                id: try editUUID(base + 5),
                definition: .lut(
                    ClipLUTEffectParameters(table: .identityOneD, strength: .one)
                )
            ),
            ClipEffectNode(
                id: try editUUID(base + 6),
                definition: .posterize(ClipPosterizeParameters(levels: RationalValue(8)))
            ),
            ClipEffectNode(
                id: try editUUID(base + 7),
                enabled: false,
                definition: .invert(ClipInvertParameters())
            )
        ]
    )
}

func targetMixedStack(base: Int) throws -> ClipEffectStack {
    ClipEffectStack(
        nodes: [
            ClipEffectNode(
                id: try editUUID(base + 1),
                definition: .mosaic(ClipMosaicParameters(cellSize: RationalValue(8)))
            ),
            ClipEffectNode(
                id: try editUUID(base + 2),
                definition: .invert(ClipInvertParameters())
            ),
            ClipEffectNode(
                id: try editUUID(base + 3),
                definition: .sharpen(ClipSharpenParameters(amount: try rational(1, 2)))
            ),
            ClipEffectNode(
                id: try editUUID(base + 4),
                definition: .colorAdjust(ClipColorAdjustParameters())
            ),
            ClipEffectNode(
                id: try editUUID(base + 5),
                definition: .glow(
                    ClipGlowParameters(radius: RationalValue(2), amount: try rational(1, 4))
                )
            )
        ]
    )
}

func gradeCommandClip(
    id: UUID,
    mediaID: UUID,
    name: String,
    stack: ClipEffectStack
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: name,
        effectStack: stack
    )
}

func gradeCommandClip(
    _ reference: ProjectClipReference,
    in project: Project
) throws -> Clip {
    let sequence = try XCTUnwrap(
        project.sequences.first(where: { $0.id == reference.sequenceID })
    )
    let track = try XCTUnwrap(
        (sequence.videoTracks + sequence.audioTracks).first(where: {
            $0.id == reference.trackID
        })
    )
    return try XCTUnwrap(
        track.items.compactMap { item -> Clip? in
            guard case .clip(let clip) = item, clip.id == reference.clipID else {
                return nil
            }
            return clip
        }.first
    )
}

func gradeCommandSettings() throws -> ProjectSettings {
    ProjectSettings(
        frameRate: try FrameRate(frames: 24),
        resolution: PixelDimensions(width: 1_920, height: 1_080),
        colorSpace: .rec709,
        audioSampleRate: 48_000
    )
}

func assertGradeInvalidEdit(
    _ expected: EditCommandValidationError,
    operation: () throws -> Project
) {
    XCTAssertThrowsError(try operation()) { error in
        XCTAssertEqual(error as? EditReducerError, .invalidEdit(expected))
    }
}

func makeGradeCommandFixture(seed: Int) throws -> GradeCommandFixture {
    let base = seed * 1_000
    let mediaID = try editUUID(base + 1)
    let sequenceID = try editUUID(base + 2)
    let sourceTrackID = try editUUID(base + 3)
    let targetTrackID = try editUUID(base + 4)
    let sourceClipID = try editUUID(base + 5)
    let targetClipID = try editUUID(base + 6)
    let media = try makeEditMediaRef(id: mediaID)
    let sourceClip = try gradeCommandClip(
        id: sourceClipID,
        mediaID: mediaID,
        name: "Grade source",
        stack: sourceGradeStack(base: base + 100)
    )
    let targetClip = try gradeCommandClip(
        id: targetClipID,
        mediaID: mediaID,
        name: "Grade target",
        stack: targetMixedStack(base: base + 200)
    )
    let sequence = Sequence(
        id: sequenceID,
        name: "Grade commands",
        videoTracks: [
            Track(id: sourceTrackID, kind: .video, items: [.clip(sourceClip)]),
            Track(id: targetTrackID, kind: .video, items: [.clip(targetClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    return GradeCommandFixture(
        project: Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: try gradeCommandSettings(),
            mediaPool: [media],
            sequences: [sequence]
        ),
        source: ProjectClipReference(
            sequenceID: sequenceID,
            trackID: sourceTrackID,
            clipID: sourceClipID
        ),
        target: ProjectClipReference(
            sequenceID: sequenceID,
            trackID: targetTrackID,
            clipID: targetClipID
        ),
        newNodeIDs: try (base + 300...base + 304).map(editUUID)
    )
}
