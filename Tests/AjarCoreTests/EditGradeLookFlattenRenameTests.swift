// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-COL-007 grade static-snapshot flatten and rename-name policy coverage.
final class EditGradeLookFlattenRenameTests: XCTestCase {
    func testFRCOL007CopyGradeFlattensAnimatedSourceToBaseConstantNodes() throws {
        let fixture = try makeAnimatedGradeFixture(seed: 9_250)
        let sourceBefore = try gradeCommandClip(fixture.source, in: fixture.project)
        let baseGrade = sourceBefore.effectStack.grade
        guard case .colorAdjust(let sourceAnim) = sourceBefore.effectStackAnimation.nodes[0]
            .definition
        else {
            return XCTFail("fixture source must keyframe colorAdjust")
        }
        XCTAssertFalse(
            sourceAnim.brightness.keyframes.isEmpty,
            "fixture must include keyframed grade animation to flatten"
        )
        XCTAssertEqual(sourceAnim.brightness.base, fixture.baseBrightness)
        XCTAssertNotEqual(fixture.baseBrightness, fixture.endBrightness)

        let copied = try apply(
            .copyClipGrade(
                source: fixture.source,
                target: fixture.target,
                newNodeIDs: fixture.newNodeIDs
            ),
            to: fixture.project
        )
        let targetAfter = try gradeCommandClip(fixture.target, in: copied)

        XCTAssertEqual(
            targetAfter.effectStack.grade.nodes.map(\.definition),
            baseGrade.nodes.map(\.definition)
        )
        XCTAssertEqual(targetAfter.effectStack.grade.nodes.map(\.id), fixture.newNodeIDs)
        XCTAssertEqual(targetAfter.effectStackAnimation, .constant(targetAfter.effectStack))
        guard case .colorAdjust(let copiedAnim) = targetAfter.effectStackAnimation.nodes[0]
            .definition
        else {
            return XCTFail("expected constant colorAdjust grade node on target")
        }
        XCTAssertTrue(
            copiedAnim.brightness.keyframes.isEmpty,
            "copied grade must be a static base-value snapshot"
        )
        XCTAssertEqual(copiedAnim.brightness.base, fixture.baseBrightness)
        XCTAssertEqual(
            targetAfter.effectStack.grade.nodes[0].definition,
            .colorAdjust(ClipColorAdjustParameters(brightness: fixture.baseBrightness))
        )
    }

    func testFRCOL007RenameLookRejectsDuplicateNameAndAllowsOwnName() throws {
        let fixture = try makeGradeCommandFixture(seed: 9_260)
        let lookA = try editUUID(9_260_900)
        let lookB = try editUUID(9_260_901)
        let withA = try apply(
            .saveLookFromClip(source: fixture.source, lookID: lookA, name: "Look A"),
            to: fixture.project
        )
        let withBoth = try apply(
            .saveLookFromClip(source: fixture.source, lookID: lookB, name: "Look B"),
            to: withA
        )

        assertGradeInvalidEdit(.duplicateLookName(" look a ")) {
            try apply(
                .renameLook(lookID: lookB, name: " look a "),
                to: withBoth
            )
        }

        let renamedToSelf = try apply(
            .renameLook(lookID: lookA, name: "Look A"),
            to: withBoth
        )
        XCTAssertEqual(renamedToSelf.looks.map(\.name), ["Look A", "Look B"])
        XCTAssertEqual(renamedToSelf.looks.map(\.id), [lookA, lookB])

        let renamedWhitespacePreserving = try apply(
            .renameLook(lookID: lookA, name: " Look A "),
            to: withBoth
        )
        XCTAssertEqual(renamedWhitespacePreserving.looks.first?.name, " Look A ")
        XCTAssertEqual(renamedWhitespacePreserving.looks.map(\.id), [lookA, lookB])
    }
}

private struct AnimatedGradeFixture {
    let project: Project
    let source: ProjectClipReference
    let target: ProjectClipReference
    let newNodeIDs: [UUID]
    let baseBrightness: RationalValue
    let endBrightness: RationalValue
}

private struct AnimatedGradeIDs {
    let mediaID: UUID
    let sequenceID: UUID
    let sourceTrackID: UUID
    let targetTrackID: UUID
    let sourceClipID: UUID
    let targetClipID: UUID
    let nodeID: UUID
    let copiedNodeID: UUID

    init(base: Int) throws {
        mediaID = try editUUID(base + 1)
        sequenceID = try editUUID(base + 2)
        sourceTrackID = try editUUID(base + 3)
        targetTrackID = try editUUID(base + 4)
        sourceClipID = try editUUID(base + 5)
        targetClipID = try editUUID(base + 6)
        nodeID = try editUUID(base + 100)
        copiedNodeID = try editUUID(base + 300)
    }
}

private func makeAnimatedGradeFixture(seed: Int) throws -> AnimatedGradeFixture {
    let ids = try AnimatedGradeIDs(base: seed * 1_000)
    let baseBrightness = try rational(1, 10)
    let endBrightness = try rational(1, 2)
    let media = try makeEditMediaRef(id: ids.mediaID)
    let sourceClip = try animatedGradeSourceClip(
        ids: ids,
        baseBrightness: baseBrightness,
        endBrightness: endBrightness
    )
    let targetClip = try gradeCommandClip(
        id: ids.targetClipID,
        mediaID: ids.mediaID,
        name: "Grade target",
        stack: .empty
    )
    let sequence = Sequence(
        id: ids.sequenceID,
        name: "Animated grade flatten",
        videoTracks: [
            Track(id: ids.sourceTrackID, kind: .video, items: [.clip(sourceClip)]),
            Track(id: ids.targetTrackID, kind: .video, items: [.clip(targetClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    return AnimatedGradeFixture(
        project: Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: try gradeCommandSettings(),
            mediaPool: [media],
            sequences: [sequence]
        ),
        source: ProjectClipReference(
            sequenceID: ids.sequenceID,
            trackID: ids.sourceTrackID,
            clipID: ids.sourceClipID
        ),
        target: ProjectClipReference(
            sequenceID: ids.sequenceID,
            trackID: ids.targetTrackID,
            clipID: ids.targetClipID
        ),
        newNodeIDs: [ids.copiedNodeID],
        baseBrightness: baseBrightness,
        endBrightness: endBrightness
    )
}

private func animatedGradeSourceClip(
    ids: AnimatedGradeIDs,
    baseBrightness: RationalValue,
    endBrightness: RationalValue
) throws -> Clip {
    let keyedBrightness = try Animatable(
        base: baseBrightness,
        keyframes: [
            Keyframe(time: try editTime(0), value: baseBrightness, interpolation: .linear),
            Keyframe(time: try editTime(8), value: endBrightness, interpolation: .linear)
        ]
    )
    let stack = ClipEffectStack(
        nodes: [
            ClipEffectNode(
                id: ids.nodeID,
                definition: .colorAdjust(ClipColorAdjustParameters(brightness: baseBrightness))
            )
        ]
    )
    return Clip(
        id: ids.sourceClipID,
        source: .media(id: ids.mediaID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Animated grade source",
        effectStack: stack,
        effectStackAnimation: AnimatableClipEffectStack(
            nodes: [
                AnimatableClipEffectNode(
                    id: ids.nodeID,
                    definition: .colorAdjust(
                        AnimatableClipColorAdjustSettings(brightness: keyedBrightness)
                    )
                )
            ]
        )
    )
}
