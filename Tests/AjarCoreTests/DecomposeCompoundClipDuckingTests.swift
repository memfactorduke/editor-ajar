// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-CMP-004 decompose semantics for nested FR-AUD-004 ducking rules, mirroring the
/// FR-CMP-001 collapse transplant: fully-expanded rules restore onto the parent (deduplicated),
/// rules referencing only non-expanded nested content stay with the retained nested sequence,
/// and boundary-spanning rules reject the decompose with a typed error.
final class DecomposeCompoundClipDuckingTests: XCTestCase {
    func testFRCMP001FRCMP004DecomposeRestoresFullyExpandedNestedDuckingRule() throws {
        let fixture = try makeDecomposeDuckingFixture(
            seed: 180,
            nestedRuleFrom: .insideTrigger,
            to: .insideTarget
        )

        let decomposed = try apply(fixture.decomposeCommand, to: fixture.project)

        let parentSequence = try XCTUnwrap(
            decomposed.sequences.first { $0.id == fixture.ids.parentSequenceID }
        )
        let nestedSequence = try XCTUnwrap(
            decomposed.sequences.first { $0.id == fixture.ids.nestedSequenceID }
        )
        XCTAssertEqual(decomposed.validate(), .valid)
        XCTAssertEqual(parentSequence.audioDucking, [fixture.nestedRule])
        XCTAssertEqual(nestedSequence.audioDucking, [fixture.nestedRule])
    }

    func testFRCMP001FRCMP004DecomposeLeavesNonExpandedNestedDuckingRule() throws {
        // Both referenced tracks hold only clips outside the compound's source window, so
        // nothing of them expands; the rule stays with the retained nested sequence.
        let fixture = try makeDecomposeDuckingFixture(
            seed: 181,
            nestedRuleFrom: .outsideTrigger,
            to: .outsideTarget
        )

        let decomposed = try apply(fixture.decomposeCommand, to: fixture.project)

        let parentSequence = try XCTUnwrap(
            decomposed.sequences.first { $0.id == fixture.ids.parentSequenceID }
        )
        let nestedSequence = try XCTUnwrap(
            decomposed.sequences.first { $0.id == fixture.ids.nestedSequenceID }
        )
        XCTAssertEqual(decomposed.validate(), .valid)
        XCTAssertEqual(parentSequence.audioDucking, [])
        XCTAssertEqual(nestedSequence.audioDucking, [fixture.nestedRule])
    }

    func testFRCMP001FRCMP004DecomposeRejectsBoundarySpanningNestedDuckingRule() throws {
        // The trigger track expands fully but the target track's clip lies outside the window,
        // so restoring the rule would silently sever its sidechain.
        let fixture = try makeDecomposeDuckingFixture(
            seed: 182,
            nestedRuleFrom: .insideTrigger,
            to: .outsideTarget
        )

        XCTAssertThrowsError(
            try apply(fixture.decomposeCommand, to: fixture.project)
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .compoundDecomposeSeversAudioDucking(
                        sequenceID: fixture.ids.nestedSequenceID,
                        ruleIndex: 0
                    )
                )
            )
        }
    }

    func testFRCMP001FRCMP004DecomposeDeduplicatesAlreadyRestoredDuckingRule() throws {
        // A sibling decompose of the same nested sequence already restored the identical rule
        // onto the parent; decomposing again must not duplicate it.
        let fixture = try makeDecomposeDuckingFixture(
            seed: 183,
            nestedRuleFrom: .insideTrigger,
            to: .insideTarget,
            parentAlreadyHasRule: true
        )

        let decomposed = try apply(fixture.decomposeCommand, to: fixture.project)

        let parentSequence = try XCTUnwrap(
            decomposed.sequences.first { $0.id == fixture.ids.parentSequenceID }
        )
        XCTAssertEqual(decomposed.validate(), .valid)
        XCTAssertEqual(parentSequence.audioDucking, [fixture.nestedRule])
    }
}

private enum DecomposeDuckingTrack {
    case insideTrigger
    case insideTarget
    case outsideTrigger
    case outsideTarget
}

private struct DecomposeDuckingIDs {
    let mediaID: UUID
    let parentSequenceID: UUID
    let parentVideoTrackID: UUID
    let compoundClipID: UUID
    let nestedSequenceID: UUID
    let insideTriggerTrackID: UUID
    let insideTargetTrackID: UUID
    let outsideTriggerTrackID: UUID
    let outsideTargetTrackID: UUID

    init(seed: Int) throws {
        let base = seed * 1_000
        mediaID = try editUUID(base + 1)
        parentSequenceID = try editUUID(base + 2)
        parentVideoTrackID = try editUUID(base + 3)
        compoundClipID = try editUUID(base + 4)
        nestedSequenceID = try editUUID(base + 5)
        insideTriggerTrackID = try editUUID(base + 6)
        insideTargetTrackID = try editUUID(base + 7)
        outsideTriggerTrackID = try editUUID(base + 8)
        outsideTargetTrackID = try editUUID(base + 9)
    }

    func trackID(for track: DecomposeDuckingTrack) -> UUID {
        switch track {
        case .insideTrigger:
            return insideTriggerTrackID
        case .insideTarget:
            return insideTargetTrackID
        case .outsideTrigger:
            return outsideTriggerTrackID
        case .outsideTarget:
            return outsideTargetTrackID
        }
    }
}

private struct DecomposeDuckingFixture {
    let project: Project
    let ids: DecomposeDuckingIDs
    let nestedRule: AudioDuckingRule

    var decomposeCommand: EditCommand {
        .decomposeCompoundClip(
            sequenceID: ids.parentSequenceID,
            trackID: ids.parentVideoTrackID,
            clipID: ids.compoundClipID
        )
    }
}

/// The compound clip windows the nested sequence to frames 0..<4: `inside*` tracks hold one
/// clip inside that window (fully expanded), `outside*` tracks hold one clip at frames 4..<8
/// (dropped by the window, never expanded).
private func makeDecomposeDuckingFixture(
    seed: Int,
    nestedRuleFrom triggerTrack: DecomposeDuckingTrack,
    to targetTrack: DecomposeDuckingTrack,
    parentAlreadyHasRule: Bool = false
) throws -> DecomposeDuckingFixture {
    let ids = try DecomposeDuckingIDs(seed: seed)
    let rule = AudioDuckingRule(
        triggerTrackID: ids.trackID(for: triggerTrack),
        targetTrackIDs: [ids.trackID(for: targetTrack)],
        threshold: try RationalValue(numerator: 1, denominator: 2),
        reductionGain: try RationalValue(numerator: 1, denominator: 4),
        attack: .zero,
        release: .zero
    )
    let parentSequence = Sequence(
        id: ids.parentSequenceID,
        name: "FR-CMP-004 Ducking Parent",
        videoTracks: [
            Track(
                id: ids.parentVideoTrackID,
                kind: .video,
                items: [
                    .clip(
                        try makeCompoundClip(
                            id: ids.compoundClipID,
                            targetSequenceID: ids.nestedSequenceID,
                            startFrame: 0,
                            durationFrames: 4
                        )
                    )
                ]
            )
        ],
        audioTracks: [],
        markers: [],
        audioDucking: parentAlreadyHasRule ? [rule] : [],
        timebase: try FrameRate(frames: 24)
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [try makeEditMediaRef(id: ids.mediaID)],
        sequences: [
            parentSequence,
            try makeDecomposeNestedSequence(ids: ids, rule: rule, seed: seed)
        ]
    )
    return DecomposeDuckingFixture(project: project, ids: ids, nestedRule: rule)
}

private func makeDecomposeNestedSequence(
    ids: DecomposeDuckingIDs,
    rule: AudioDuckingRule,
    seed: Int
) throws -> Sequence {
    let base = seed * 1_000
    return Sequence(
        id: ids.nestedSequenceID,
        name: "FR-CMP-004 Ducking Nested",
        videoTracks: [],
        audioTracks: [
            try decomposeAudioTrack(
                id: ids.insideTriggerTrackID,
                mediaID: ids.mediaID,
                clipID: try editUUID(base + 10),
                startFrame: 0
            ),
            try decomposeAudioTrack(
                id: ids.insideTargetTrackID,
                mediaID: ids.mediaID,
                clipID: try editUUID(base + 11),
                startFrame: 0
            ),
            try decomposeAudioTrack(
                id: ids.outsideTriggerTrackID,
                mediaID: ids.mediaID,
                clipID: try editUUID(base + 12),
                startFrame: 4
            ),
            try decomposeAudioTrack(
                id: ids.outsideTargetTrackID,
                mediaID: ids.mediaID,
                clipID: try editUUID(base + 13),
                startFrame: 4
            )
        ],
        markers: [],
        audioDucking: [rule],
        timebase: try FrameRate(frames: 24)
    )
}

private func decomposeAudioTrack(
    id: UUID,
    mediaID: UUID,
    clipID: UUID,
    startFrame: Int64
) throws -> Track {
    Track(
        id: id,
        kind: .audio,
        items: [
            .clip(
                try makeEditClip(
                    id: clipID,
                    mediaID: mediaID,
                    startFrame: startFrame,
                    durationFrames: 4,
                    kind: .audio
                )
            )
        ]
    )
}
