// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-CMP-001 collapse semantics for FR-AUD-004 sidechain ducking rules.
///
/// Rules whose referenced audio tracks are all fully collapsed transplant into the nested
/// sequence; rules that reference no participating track stay outer untouched; rules that span
/// the collapse boundary reject the edit with a typed error instead of silently severing the
/// sidechain.
final class MakeCompoundClipDuckingTests: XCTestCase {
    func testFRCMP001MakeCompoundTransplantsFullyCollapsedDuckingRule() throws {
        let fixture = try makeDuckingFixture(seed: 170, ruleFrom: .trigger, to: .target)
        var history = EditHistory(project: fixture.project)

        let edited = try history.apply(fixture.collapseAllCommand)

        let outerSequence = try XCTUnwrap(
            edited.sequences.first { $0.id == fixture.ids.sequenceID }
        )
        let nestedSequence = try XCTUnwrap(
            edited.sequences.first { $0.id == fixture.ids.compoundSequenceID }
        )
        XCTAssertEqual(edited.validate(), .valid)
        XCTAssertEqual(outerSequence.audioDucking, [])
        XCTAssertEqual(nestedSequence.audioDucking, [fixture.rule])
        XCTAssertEqual(
            nestedSequence.audioTracks.map(\.id),
            [fixture.ids.triggerTrackID, fixture.ids.targetTrackID]
        )
    }

    func testFRCMP001MakeCompoundDuckingUndoRestoresExactConfiguration() throws {
        let fixture = try makeDuckingFixture(seed: 171, ruleFrom: .trigger, to: .target)
        var history = EditHistory(project: fixture.project)

        let edited = try history.apply(fixture.collapseAllCommand)

        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
    }

    func testFRCMP001MakeCompoundKeepsOuterOnlyDuckingRule() throws {
        let fixture = try makeDuckingFixture(seed: 172, ruleFrom: .outer, to: .secondOuter)

        let edited = try apply(fixture.collapseAllCommand, to: fixture.project)

        let outerSequence = try XCTUnwrap(
            edited.sequences.first { $0.id == fixture.ids.sequenceID }
        )
        let nestedSequence = try XCTUnwrap(
            edited.sequences.first { $0.id == fixture.ids.compoundSequenceID }
        )
        XCTAssertEqual(edited.validate(), .valid)
        XCTAssertEqual(outerSequence.audioDucking, [fixture.rule])
        XCTAssertEqual(nestedSequence.audioDucking, [])
    }

    func testFRCMP001MakeCompoundRejectsBoundarySpanningDuckingRule() throws {
        let fixture = try makeDuckingFixture(seed: 173, ruleFrom: .trigger, to: .outer)

        XCTAssertThrowsError(
            try apply(fixture.collapseAllCommand, to: fixture.project)
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .compoundSelectionSeversAudioDucking(
                        sequenceID: fixture.ids.sequenceID,
                        ruleIndex: 0
                    )
                )
            )
        }
    }

    func testFRCMP001FRCMP004CollapseDecomposeRoundTripRestoresDuckingRules() throws {
        let fixture = try makeDuckingFixture(seed: 175, ruleFrom: .trigger, to: .target)
        let collapsed = try apply(fixture.collapseAllCommand, to: fixture.project)

        let decomposed = try apply(
            .decomposeCompoundClip(
                sequenceID: fixture.ids.sequenceID,
                trackID: fixture.ids.videoTrackID,
                clipID: fixture.ids.compoundClipID
            ),
            to: collapsed
        )

        // Command-level inverse: the parent sequence — including its ducking configuration —
        // is restored exactly, not merely via history undo.
        let parentSequence = try XCTUnwrap(
            decomposed.sequences.first { $0.id == fixture.ids.sequenceID }
        )
        XCTAssertEqual(parentSequence, fixture.project.sequences[0])
        // The retained nested sequence keeps its transplanted rule for other instances, like
        // it keeps its clips and markers.
        let nestedSequence = try XCTUnwrap(
            decomposed.sequences.first { $0.id == fixture.ids.compoundSequenceID }
        )
        XCTAssertEqual(nestedSequence.audioDucking, [fixture.rule])
        XCTAssertEqual(decomposed.validate(), .valid)
    }

    func testFRCMP001MakeCompoundRejectsPartiallyCollapsedDuckingTrack() throws {
        let fixture = try makeDuckingFixture(seed: 174, ruleFrom: .outer, to: .secondOuter)
        // Selecting only the first of the outer trigger track's two clips leaves the rule's
        // trigger track partially collapsed, which would sever its sidechain.
        let command = fixture.command(
            selecting: [
                ClipReference(
                    trackID: fixture.ids.videoTrackID,
                    clipID: fixture.ids.videoClipID
                ),
                ClipReference(
                    trackID: fixture.ids.outerTrackID,
                    clipID: fixture.ids.firstOuterClipID
                )
            ]
        )

        XCTAssertThrowsError(try apply(command, to: fixture.project)) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .compoundSelectionSeversAudioDucking(
                        sequenceID: fixture.ids.sequenceID,
                        ruleIndex: 0
                    )
                )
            )
        }
    }
}

private enum DuckingFixtureTrack {
    case trigger
    case target
    case outer
    case secondOuter
}

private struct DuckingFixtureIDs {
    let mediaID: UUID
    let sequenceID: UUID
    let videoTrackID: UUID
    let triggerTrackID: UUID
    let targetTrackID: UUID
    let outerTrackID: UUID
    let secondOuterTrackID: UUID
    let videoClipID: UUID
    let triggerClipID: UUID
    let targetClipID: UUID
    let firstOuterClipID: UUID
    let secondOuterClipID: UUID
    let secondOuterTrackClipID: UUID
    let compoundSequenceID: UUID
    let compoundClipID: UUID

    init(seed: Int) throws {
        let base = seed * 1_000
        mediaID = try editUUID(base + 1)
        sequenceID = try editUUID(base + 2)
        videoTrackID = try editUUID(base + 3)
        triggerTrackID = try editUUID(base + 4)
        targetTrackID = try editUUID(base + 5)
        outerTrackID = try editUUID(base + 6)
        secondOuterTrackID = try editUUID(base + 7)
        videoClipID = try editUUID(base + 8)
        triggerClipID = try editUUID(base + 9)
        targetClipID = try editUUID(base + 10)
        firstOuterClipID = try editUUID(base + 11)
        secondOuterClipID = try editUUID(base + 12)
        secondOuterTrackClipID = try editUUID(base + 13)
        compoundSequenceID = try editUUID(base + 14)
        compoundClipID = try editUUID(base + 15)
    }

    func trackID(for track: DuckingFixtureTrack) -> UUID {
        switch track {
        case .trigger:
            return triggerTrackID
        case .target:
            return targetTrackID
        case .outer:
            return outerTrackID
        case .secondOuter:
            return secondOuterTrackID
        }
    }
}

private struct DuckingSelectionFixture {
    let project: Project
    let ids: DuckingFixtureIDs
    let rule: AudioDuckingRule

    var collapseAllCommand: EditCommand {
        command(
            selecting: [
                ClipReference(trackID: ids.videoTrackID, clipID: ids.videoClipID),
                ClipReference(trackID: ids.triggerTrackID, clipID: ids.triggerClipID),
                ClipReference(trackID: ids.targetTrackID, clipID: ids.targetClipID)
            ]
        )
    }

    func command(selecting selectedClips: [ClipReference]) -> EditCommand {
        .makeCompoundClip(
            sequenceID: ids.sequenceID,
            compoundSequenceID: ids.compoundSequenceID,
            compoundClipID: ids.compoundClipID,
            selectedClips: selectedClips,
            name: "FR-CMP-001 Ducking Compound"
        )
    }
}

private func makeDuckingFixture(
    seed: Int,
    ruleFrom triggerTrack: DuckingFixtureTrack,
    to targetTrack: DuckingFixtureTrack
) throws -> DuckingSelectionFixture {
    let ids = try DuckingFixtureIDs(seed: seed)
    let rule = AudioDuckingRule(
        triggerTrackID: ids.trackID(for: triggerTrack),
        targetTrackIDs: [ids.trackID(for: targetTrack)],
        threshold: try RationalValue(numerator: 1, denominator: 2),
        reductionGain: try RationalValue(numerator: 1, denominator: 4),
        attack: .zero,
        release: .zero
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [try makeEditMediaRef(id: ids.mediaID)],
        sequences: [try makeDuckingSequence(ids: ids, rule: rule)]
    )
    return DuckingSelectionFixture(project: project, ids: ids, rule: rule)
}

private func makeDuckingSequence(
    ids: DuckingFixtureIDs,
    rule: AudioDuckingRule
) throws -> Sequence {
    Sequence(
        id: ids.sequenceID,
        name: "FR-CMP-001 Ducking Source",
        videoTracks: [
            Track(
                id: ids.videoTrackID,
                kind: .video,
                items: [
                    .clip(
                        try makeEditClip(
                            id: ids.videoClipID,
                            mediaID: ids.mediaID,
                            startFrame: 0,
                            durationFrames: 8
                        )
                    )
                ]
            )
        ],
        audioTracks: [
            try makeDuckingAudioTrack(id: ids.triggerTrackID, mediaID: ids.mediaID, clips: [
                DuckingClipSpec(id: ids.triggerClipID, startFrame: 0, durationFrames: 8)
            ]),
            try makeDuckingAudioTrack(id: ids.targetTrackID, mediaID: ids.mediaID, clips: [
                DuckingClipSpec(id: ids.targetClipID, startFrame: 0, durationFrames: 8)
            ]),
            try makeDuckingAudioTrack(id: ids.outerTrackID, mediaID: ids.mediaID, clips: [
                DuckingClipSpec(id: ids.firstOuterClipID, startFrame: 0, durationFrames: 4),
                DuckingClipSpec(id: ids.secondOuterClipID, startFrame: 4, durationFrames: 4)
            ]),
            try makeDuckingAudioTrack(id: ids.secondOuterTrackID, mediaID: ids.mediaID, clips: [
                DuckingClipSpec(
                    id: ids.secondOuterTrackClipID,
                    startFrame: 0,
                    durationFrames: 8
                )
            ])
        ],
        markers: [],
        audioDucking: [rule],
        timebase: try FrameRate(frames: 24)
    )
}

private struct DuckingClipSpec {
    let id: UUID
    let startFrame: Int64
    let durationFrames: Int64
}

private func makeDuckingAudioTrack(
    id: UUID,
    mediaID: UUID,
    clips: [DuckingClipSpec]
) throws -> Track {
    Track(
        id: id,
        kind: .audio,
        items: try clips.map { clip in
            .clip(
                try makeEditClip(
                    id: clip.id,
                    mediaID: mediaID,
                    startFrame: clip.startFrame,
                    durationFrames: clip.durationFrames,
                    kind: .audio
                )
            )
        }
    )
}
