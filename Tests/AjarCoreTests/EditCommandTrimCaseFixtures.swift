// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@testable import AjarCore

func makeTrimClipCommandCases(
    fixture: EditFixture,
    seed: Int
) throws -> [EditCommandCase] {
    let laterClipID = try editUUID(seed * 1_000 + 30)
    let rightClipID = try editUUID(seed * 1_000 + 31)
    let slideClipID = try editUUID(seed * 1_000 + 32)
    let nextClipID = try editUUID(seed * 1_000 + 33)
    let laterClip = try makeEditClip(
        id: laterClipID,
        mediaID: fixture.mediaID,
        startFrame: 10,
        durationFrames: 5
    )
    let rightClip = try makeEditClip(
        id: rightClipID,
        mediaID: fixture.mediaID,
        startFrame: 10,
        durationFrames: 10
    )
    let slideClip = try makeEditClip(
        id: slideClipID,
        mediaID: fixture.mediaID,
        startFrame: 10,
        durationFrames: 5
    )
    let nextClip = try makeEditClip(
        id: nextClipID,
        mediaID: fixture.mediaID,
        startFrame: 15,
        durationFrames: 10
    )
    let projectWithLater = try applyingAddClip(laterClip, fixture: fixture)
    let projectWithRight = try applyingAddClip(rightClip, fixture: fixture)
    let projectForSlide = try replacingVideoItems(
        [
            .clip(try requiredClip(fixture.clipID, in: fixture.project, fixture: fixture)),
            .clip(slideClip),
            .clip(nextClip)
        ],
        in: fixture
    )

    return try [
        makeBladeCommandCase(fixture: fixture, seed: seed),
        makeRippleTrimCommandCase(fixture: fixture, project: projectWithLater),
        makeRollCommandCase(fixture: fixture, project: projectWithRight, rightClipID: rightClipID),
        makeSlipCommandCase(fixture: fixture),
        makeSlideCommandCase(
            fixture: fixture,
            project: projectForSlide,
            slideClipID: slideClipID
        ),
        makeRippleDeleteCommandCase(fixture: fixture, project: projectWithLater),
        makeLiftCommandCase(fixture: fixture, project: projectWithLater)
    ]
}

private func makeBladeCommandCase(fixture: EditFixture, seed: Int) throws -> EditCommandCase {
    EditCommandCase(
        project: fixture.project,
        command: .bladeClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            atTime: try editTime(4),
            rightClipID: try editUUID(seed * 1_000 + 34)
        )
    )
}

private func makeRippleTrimCommandCase(
    fixture: EditFixture,
    project: Project
) throws -> EditCommandCase {
    EditCommandCase(
        project: project,
        command: .rippleTrimClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            sourceRange: try editRange(startFrame: 0, durationFrames: 6),
            timelineRange: try editRange(startFrame: 0, durationFrames: 6)
        )
    )
}

private func makeRollCommandCase(
    fixture: EditFixture,
    project: Project,
    rightClipID: UUID
) throws -> EditCommandCase {
    EditCommandCase(
        project: project,
        command: .rollEdit(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            leftClipID: fixture.clipID,
            rightClipID: rightClipID,
            editTime: try editTime(12)
        )
    )
}

private func makeSlipCommandCase(fixture: EditFixture) throws -> EditCommandCase {
    EditCommandCase(
        project: fixture.project,
        command: .slipClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            sourceRange: try editRange(startFrame: 3, durationFrames: 10)
        )
    )
}

private func makeSlideCommandCase(
    fixture: EditFixture,
    project: Project,
    slideClipID: UUID
) throws -> EditCommandCase {
    EditCommandCase(
        project: project,
        command: .slideClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: slideClipID,
            timelineRange: try editRange(startFrame: 12, durationFrames: 5)
        )
    )
}

private func makeRippleDeleteCommandCase(
    fixture: EditFixture,
    project: Project
) -> EditCommandCase {
    EditCommandCase(
        project: project,
        command: .rippleDeleteClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID
        )
    )
}

private func makeLiftCommandCase(
    fixture: EditFixture,
    project: Project
) -> EditCommandCase {
    EditCommandCase(
        project: project,
        command: .liftClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID
        )
    )
}
