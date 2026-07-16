// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarMedia

final class MediaSourceIdentityVerifierTests: XCTestCase {
    func testDurableIdentityHashesOffMainCachesRevisionAndRefusesReplacement() async throws {
        let root = try identityTemporaryDirectory(named: "durable")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.bin")
        let originalBytes = Data("original playable bytes".utf8)
        try originalBytes.write(to: sourceURL)
        let expectedHash = ContentHash.sha256(data: originalBytes)
        let hasher = RecordingIdentityHasher()
        let verifier = MediaSourceIdentityVerifier(hasher: hasher)
        let media = try identityMediaRef(sourceURL: sourceURL, contentHash: expectedHash)

        let first = try await verifier.verifyBeforeReading(media)
        try await verifier.verifyAfterReading(first)
        let second = try await verifier.verifyBeforeReading(media)
        try await verifier.verifyAfterReading(second)

        XCTAssertEqual(first.playableContentHash, expectedHash)
        XCTAssertEqual(second.sourceRevision, first.sourceRevision)
        XCTAssertEqual(hasher.hashCount, 1, "an unchanged revision should be hashed once")
        XCTAssertFalse(hasher.hashedOnMainThread, "playable-byte hashing must stay off-main")

        let replacementBytes = Data("different replacement bytes with a new size".utf8)
        try replacementBytes.write(to: sourceURL, options: .atomic)
        do {
            _ = try await verifier.verifyBeforeReading(media)
            XCTFail("replaced bytes must require an explicit relink or identity refresh")
        } catch let error as MediaSourceIdentityVerificationError {
            XCTAssertEqual(
                error,
                .playableContentHashMismatch(
                    url: sourceURL.standardizedFileURL,
                    expected: expectedHash,
                    actual: ContentHash.sha256(data: replacementBytes)
                )
            )
        }
    }

    func testLegacyTranscodeUsesSessionBaselineInsteadOfOriginalHash() async throws {
        let root = try identityTemporaryDirectory(named: "legacy-transcode")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("working.mov")
        let workingBytes = Data("legacy working transcode".utf8)
        try workingBytes.write(to: sourceURL)
        let originalHash = ContentHash.sha256(data: Data("unrelated original bytes".utf8))
        let verifier = MediaSourceIdentityVerifier()
        let base = try identityMediaRef(sourceURL: sourceURL, contentHash: originalHash)
        let media = MediaRef(
            id: base.id,
            sourceURL: sourceURL,
            contentHash: originalHash,
            metadata: base.metadata,
            transcodeProvenance: MediaTranscodeProvenance(
                originalSourceURL: root.appendingPathComponent("original.mkv"),
                originalContentHash: originalHash
            )
        )

        let first = try await verifier.verifyBeforeReading(media)
        XCTAssertEqual(first.playableContentHash, ContentHash.sha256(data: workingBytes))
        XCTAssertNotEqual(first.playableContentHash, originalHash)

        let replacementBytes = Data("replacement legacy working transcode is different".utf8)
        try replacementBytes.write(to: sourceURL, options: .atomic)
        do {
            _ = try await verifier.verifyBeforeReading(media)
            XCTFail("a legacy transcode may only establish one playable identity per session")
        } catch let error as MediaSourceIdentityVerificationError {
            XCTAssertEqual(
                error,
                .playableContentHashMismatch(
                    url: sourceURL.standardizedFileURL,
                    expected: ContentHash.sha256(data: workingBytes),
                    actual: ContentHash.sha256(data: replacementBytes)
                )
            )
        }
    }

    func testDurableTranscodeVerifiesPlayableHashInsteadOfOriginalHash() async throws {
        let root = try identityTemporaryDirectory(named: "durable-transcode")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("working.mov")
        let workingBytes = Data("durable working transcode".utf8)
        try workingBytes.write(to: sourceURL)
        let originalHash = ContentHash.sha256(data: Data("original container bytes".utf8))
        let playableHash = ContentHash.sha256(data: workingBytes)
        let base = try identityMediaRef(sourceURL: sourceURL, contentHash: originalHash)
        let media = MediaRef(
            id: base.id,
            sourceURL: sourceURL,
            contentHash: originalHash,
            metadata: base.metadata,
            transcodeProvenance: MediaTranscodeProvenance(
                originalSourceURL: root.appendingPathComponent("original.mkv"),
                originalContentHash: originalHash,
                playableContentHash: playableHash
            )
        )

        let verified = try await MediaSourceIdentityVerifier().verifyBeforeReading(media)

        XCTAssertEqual(verified.playableContentHash, playableHash)
        XCTAssertNotEqual(verified.playableContentHash, originalHash)
    }

    func testNilHashOrdinarySourceDeliberatelyRemainsRevisionOnly() async throws {
        let root = try identityTemporaryDirectory(named: "nil-hash")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("unidentified.bin")
        try Data("first bytes".utf8).write(to: sourceURL)
        let hasher = RecordingIdentityHasher()
        let verifier = MediaSourceIdentityVerifier(hasher: hasher)
        let media = try identityMediaRef(sourceURL: sourceURL, contentHash: nil)

        let first = try await verifier.verifyBeforeReading(media)
        XCTAssertNil(first.playableContentHash)
        try Data("replacement bytes with another size".utf8).write(
            to: sourceURL,
            options: .atomic
        )
        let second = try await verifier.verifyBeforeReading(media)

        XCTAssertNil(second.playableContentHash)
        XCTAssertNotEqual(second.sourceRevision, first.sourceRevision)
        XCTAssertEqual(hasher.hashCount, 0, "there is no durable identity to compare")
    }

    func testAfterReadVerificationRejectsMidReadRevisionChange() async throws {
        let root = try identityTemporaryDirectory(named: "mid-read")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.bin")
        let bytes = Data("stable source".utf8)
        try bytes.write(to: sourceURL)
        let verifier = MediaSourceIdentityVerifier()
        let media = try identityMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )
        let verified = try await verifier.verifyBeforeReading(media)

        try Data("changed while reader was active".utf8).write(to: sourceURL, options: .atomic)

        do {
            try await verifier.verifyAfterReading(verified)
            XCTFail("reader results from a changed revision must be discarded")
        } catch let error as MediaSourceIdentityVerificationError {
            XCTAssertEqual(
                error,
                .sourceChangedDuringRead(sourceURL.standardizedFileURL)
            )
        }
    }

    func testCancellationStopsDetachedStreamingHash() async throws {
        let root = try identityTemporaryDirectory(named: "cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.bin")
        let bytes = Data("cancel me".utf8)
        try bytes.write(to: sourceURL)
        let hasher = CancellationObservingIdentityHasher()
        let verifier = MediaSourceIdentityVerifier(hasher: hasher)
        let media = try identityMediaRef(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: bytes)
        )

        let verification = Task {
            try await verifier.verifyBeforeReading(media)
        }
        XCTAssertEqual(hasher.started.wait(timeout: .now() + 2), .success)
        verification.cancel()

        do {
            _ = try await verification.value
            XCTFail("cancelled verification must not produce trusted identity")
        } catch is CancellationError {
            XCTAssertTrue(hasher.observedCancellation)
        }
    }
}

private final class RecordingIdentityHasher: MediaFileHashing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedHashCount = 0
    private var storedHashedOnMainThread = false

    var hashCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedHashCount
    }

    var hashedOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedHashedOnMainThread
    }

    func contentHash(of fileURL: URL) throws -> ContentHash {
        try contentHash(of: fileURL, isCancelled: { false })
    }

    func contentHash(
        of fileURL: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> ContentHash {
        if isCancelled() { throw CancellationError() }
        let bytes = try Data(contentsOf: fileURL)
        lock.lock()
        storedHashCount += 1
        storedHashedOnMainThread = storedHashedOnMainThread || Thread.isMainThread
        lock.unlock()
        if isCancelled() { throw CancellationError() }
        return ContentHash.sha256(data: bytes)
    }
}

private final class CancellationObservingIdentityHasher: MediaFileHashing, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedObservedCancellation = false

    var observedCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedObservedCancellation
    }

    func contentHash(of fileURL: URL) throws -> ContentHash {
        try contentHash(of: fileURL, isCancelled: { false })
    }

    func contentHash(
        of _: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> ContentHash {
        started.signal()
        while !isCancelled() {
            Thread.sleep(forTimeInterval: 0.001)
        }
        lock.lock()
        storedObservedCancellation = true
        lock.unlock()
        throw CancellationError()
    }
}

private func identityTemporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("editor-ajar-identity-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func identityMediaRef(sourceURL: URL, contentHash: ContentHash?) throws -> MediaRef {
    MediaRef(
        id: UUID(),
        sourceURL: sourceURL,
        contentHash: contentHash,
        metadata: MediaMetadata(
            codecID: "test",
            pixelDimensions: nil,
            frameRate: nil,
            duration: try RationalTime(value: 1, timescale: 1),
            colorSpace: .unspecified,
            audioChannelLayout: AudioChannelLayout(channelCount: 1),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}
