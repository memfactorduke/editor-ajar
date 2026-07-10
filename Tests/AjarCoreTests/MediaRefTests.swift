// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class MediaRefTests: XCTestCase {
    func testFRPROJ004PreservesStableIDAcrossCodableRoundTrip() throws {
        let media = try makeMediaRef(sourceURL: URL(fileURLWithPath: "/original/interview.mov"))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(media)
        let decoded = try decoder.decode(MediaRef.self, from: data)

        XCTAssertEqual(decoded.id, media.id)
        XCTAssertEqual(decoded.sourceURL, media.sourceURL)
        XCTAssertEqual(decoded.contentHash, media.contentHash)
        XCTAssertEqual(decoded.metadata, media.metadata)
    }

    func testFRMED007RelinkMatchesMovedMediaByContentHash() throws {
        let original = try makeMediaRef(sourceURL: URL(fileURLWithPath: "/old/interview.mov"))
        let bookmark = Data([0xAA, 0xBB])
        let candidate = MediaRelinkCandidate(
            sourceURL: URL(fileURLWithPath: "/new/renamed.mov"),
            contentHash: original.contentHash,
            bookmark: bookmark
        )

        XCTAssertEqual(original.relinkMatch(for: candidate), .contentHash)

        let relinked = original.relinked(to: candidate)
        XCTAssertEqual(relinked.id, original.id)
        XCTAssertEqual(relinked.sourceURL, candidate.sourceURL)
        XCTAssertEqual(relinked.bookmark, bookmark)
        XCTAssertFalse(relinked.isOffline)
    }

    func testFRMED007HashMismatchReturnsWarningUntilCallerExplicitlyOverrides() throws {
        let original = try makeMediaRef(sourceURL: URL(fileURLWithPath: "/old/interview.mov"))
        let candidateHash = ContentHash.sha256(data: Data("different media".utf8))
        let candidate = MediaRelinkCandidate(
            sourceURL: URL(fileURLWithPath: "/new/interview.mov"),
            contentHash: candidateHash,
            bookmark: Data([0x10])
        )

        let warned = original.relinkDecision(for: candidate, mismatchPolicy: .warn)
        XCTAssertEqual(
            warned,
            .warning(
                MediaRelinkWarning(
                    mediaID: original.id,
                    candidateURL: candidate.sourceURL,
                    reason: .contentHashMismatch(
                        expected: try XCTUnwrap(original.contentHash),
                        actual: candidateHash
                    )
                )
            )
        )

        guard
            case .relinked(let overridden, let match) = original.relinkDecision(
                for: candidate,
                mismatchPolicy: .override
            )
        else {
            return XCTFail("expected explicit override to prepare replacement")
        }
        XCTAssertEqual(match, .overriddenContentHash)
        XCTAssertEqual(overridden.id, original.id)
        XCTAssertEqual(overridden.contentHash, candidateHash)
        XCTAssertEqual(overridden.sourceURL, candidate.sourceURL)
        XCTAssertEqual(overridden.bookmark, candidate.bookmark)
        XCTAssertEqual(overridden.availability, .available)
    }

    func testFRMED007MatchingFilenameNeverOverridesConflictingHashes() throws {
        let original = try makeMediaRef(sourceURL: URL(fileURLWithPath: "/old/interview.mov"))
        let candidate = MediaRelinkCandidate(
            sourceURL: URL(fileURLWithPath: "/new/interview.mov"),
            contentHash: ContentHash.sha256(data: Data("replacement".utf8))
        )

        XCTAssertNil(original.relinkMatch(for: candidate))
    }

    func testFRMED007RelinkFallsBackToFilenameWhenHashIsMissing() throws {
        let original = try makeMediaRef(
            sourceURL: URL(fileURLWithPath: "/old/interview.mov"),
            contentHash: nil
        )
        let candidate = MediaRelinkCandidate(
            sourceURL: URL(fileURLWithPath: "/new/interview.mov"),
            contentHash: nil
        )

        XCTAssertEqual(original.relinkMatch(for: candidate), .filename)
    }

    func testFRMED007OfflineMediaReferenceIsValidTypedState() throws {
        let offline = try makeMediaRef(
            sourceURL: URL(fileURLWithPath: "/missing/interview.mov"),
            availability: .offline
        )

        XCTAssertTrue(offline.isOffline)
        XCTAssertEqual(offline.sourceURL?.lastPathComponent, "interview.mov")
        XCTAssertNil(
            offline.relinkMatch(
                for: MediaRelinkCandidate(
                    sourceURL: URL(fileURLWithPath: "/candidate/other.mov"),
                    contentHash: nil
                )
            )
        )
    }

    func testFRMED007OfflineStateMachineTransitionsWithoutChangingStableIdentity() throws {
        let available = try makeMediaRef(
            sourceURL: URL(fileURLWithPath: "/missing/interview.mov")
        )
        let offline = available.withAvailability(.offline)
        let restored = offline.withAvailability(.available)

        XCTAssertEqual(offline.id, available.id)
        XCTAssertEqual(offline.availability, .offline)
        XCTAssertTrue(offline.isOffline)
        XCTAssertEqual(restored.id, available.id)
        XCTAssertEqual(restored.availability, .available)
        XCTAssertFalse(restored.isOffline)
    }

    func testFRMED007LegacyReferenceWithoutAvailabilityDefaultsAvailable() throws {
        let media = try makeMediaRef(sourceURL: URL(fileURLWithPath: "/media/interview.mov"))
        let encoded = try JSONEncoder().encode(media)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "availability")
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let decoded = try JSONDecoder().decode(MediaRef.self, from: legacy)

        XCTAssertEqual(decoded.id, media.id)
        XCTAssertEqual(decoded.availability, .available)
        XCTAssertFalse(decoded.isOffline)
    }

    func testFRMED010RepresentsVariableFrameRateConformedTimebase() throws {
        let metadata = try makeMetadata(isVariableFrameRate: true)

        XCTAssertTrue(metadata.isVariableFrameRate)
        XCTAssertEqual(metadata.frameRate, try FrameRate(frames: 30_000, per: 1_001))
        XCTAssertEqual(metadata.conformedFrameRate, try FrameRate(frames: 30))
        XCTAssertEqual(metadata.duration, try RationalTime(value: 42, timescale: 1))
    }

    func testFRMED008StoresReferenceAndBookmarkWithoutEmbeddingMediaBytes() throws {
        let bookmark = Data([0x01, 0x02, 0x03])
        let media = try makeMediaRef(
            sourceURL: URL(fileURLWithPath: "/media/original.mov"),
            bookmark: bookmark
        )

        XCTAssertEqual(media.sourceURL?.path, "/media/original.mov")
        XCTAssertEqual(media.bookmark, bookmark)
    }

    func testContentHashSHA256IsStableForKnownBytes() throws {
        let hash = ContentHash.sha256(data: Data("abc".utf8))

        XCTAssertEqual(
            hash,
            try ContentHash(
                digest: "ba7816bf8f01cfea414140de5dae2223"
                    + "b00361a396177a9cb410ff61f20015ad"
            )
        )
    }

    func testContentHashRejectsMalformedDigestWithoutCrashing() {
        XCTAssertThrowsError(try ContentHash(digest: "not-a-sha256")) { error in
            XCTAssertEqual(
                error as? ContentHashError,
                .invalidDigest(algorithm: .sha256, digest: "not-a-sha256")
            )
        }
    }

    func testContentHashRejectsMalformedDecodedDigestWithoutCrashing() throws {
        let data = Data(#"{"algorithm":"sha256","digest":"not-a-sha256"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ContentHash.self, from: data))
    }

    private func makeMediaRef(
        sourceURL: URL?,
        bookmark: Data? = nil,
        contentHash: ContentHash? = ContentHash.sha256(data: Data("media".utf8)),
        availability: MediaAvailability = .available
    ) throws -> MediaRef {
        MediaRef(
            id: try XCTUnwrap(UUID(uuidString: "4F4B8B2D-9E95-49DA-8D66-80D7E57F02B5")),
            sourceURL: sourceURL,
            bookmark: bookmark,
            contentHash: contentHash,
            metadata: try makeMetadata(),
            availability: availability
        )
    }

    private func makeMetadata(
        isVariableFrameRate: Bool = false
    ) throws -> MediaMetadata {
        MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 30_000, per: 1_001),
            duration: try RationalTime(value: 42, timescale: 1),
            colorSpace: .rec709,
            audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
            isVariableFrameRate: isVariableFrameRate,
            conformedFrameRate: try FrameRate(frames: 30)
        )
    }
}
