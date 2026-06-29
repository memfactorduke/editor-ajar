// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

final class AudioEngineResidualPolishTests: XCTestCase {
    func testFRAUD003MutedOrDisabledSoloTracksDoNotSelectPlayback() throws {
        let mutedSoloID = try uuid("00000000-0000-0000-0000-000000085301")
        let disabledSoloID = try uuid("00000000-0000-0000-0000-000000085302")
        let renderedID = try uuid("00000000-0000-0000-0000-000000085303")
        let sequence = try makeSequence(tracks: [
            makeTrack(
                items: [.clip(try makeClip(mediaID: mutedSoloID, duration: time(1, 1)))],
                muted: true,
                solo: true
            ),
            makeTrack(
                items: [.clip(try makeClip(mediaID: disabledSoloID, duration: time(1, 1)))],
                enabled: false,
                solo: true
            ),
            makeTrack(items: [.clip(try makeClip(mediaID: renderedID, duration: time(1, 1)))])
        ])
        let buffer = try render(
            sequence: sequence,
            sources: [
                mutedSoloID: try audioSource(samples: [100, 100, 100, 100]),
                disabledSoloID: try audioSource(samples: [200, 200, 200, 200]),
                renderedID: try audioSource(samples: [2, 2, 2, 2])
            ]
        )

        assertSamples(buffer.samples, equal: [2, 2, 2, 2, 2, 2, 2, 2])
    }

    func testFRAUD003FloatMixBusPreservesAboveUnityHeadroom() throws {
        let firstID = try uuid("00000000-0000-0000-0000-000000085304")
        let secondID = try uuid("00000000-0000-0000-0000-000000085305")
        let sequence = try makeSequence(tracks: [
            makeTrack(items: [.clip(try makeClip(mediaID: firstID, duration: time(1, 1)))]),
            makeTrack(items: [.clip(try makeClip(mediaID: secondID, duration: time(1, 1)))])
        ])
        let buffer = try render(
            sequence: sequence,
            sources: [
                firstID: try audioSource(samples: [1, 1, 1, 1]),
                secondID: try audioSource(samples: [1, 1, 1, 1])
            ]
        )

        assertSamples(buffer.samples, equal: [2, 2, 2, 2, 2, 2, 2, 2])
    }

    func testFRAUD007RealtimeSafetyReportReflectsStorageKindContract() {
        let owned = RealtimeAudioSafetyReport(
            preparedFrameCount: 2,
            storageKind: .ownedPointer
        )
        let locking = RealtimeAudioSafetyReport(
            preparedFrameCount: 2,
            storageKind: .lockedSharedBuffer
        )
        let allocating = RealtimeAudioSafetyReport(
            preparedFrameCount: 2,
            storageKind: .allocatingCallbackBuffer
        )

        XCTAssertFalse(owned.usesLocks)
        XCTAssertFalse(owned.allocatesDuringRender)
        XCTAssertTrue(owned.isRealtimeSafe)
        XCTAssertTrue(locking.usesLocks)
        XCTAssertFalse(locking.allocatesDuringRender)
        XCTAssertFalse(locking.isRealtimeSafe)
        XCTAssertFalse(allocating.usesLocks)
        XCTAssertTrue(allocating.allocatesDuringRender)
        XCTAssertFalse(allocating.isRealtimeSafe)
    }
}
