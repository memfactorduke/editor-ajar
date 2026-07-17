// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarExport

final class ExportDestinationReservationTests: XCTestCase {
    func testFREXP005CanonicalKeyMatchesFilesystemAliasesAndMacPathEquivalents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-export-reservation-\(UUID().uuidString)",
            isDirectory: true
        )
        let realParent = directory.appendingPathComponent("real", isDirectory: true)
        let nested = realParent.appendingPathComponent("nested", isDirectory: true)
        let symlinkParent = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkParent, withDestinationURL: realParent)
        defer { try? FileManager.default.removeItem(at: directory) }

        let canonical = realParent.appendingPathComponent("Caf\u{00E9}.GIF")
        let throughSymlink = symlinkParent.appendingPathComponent("caf\u{0065}\u{0301}.gif")
        let throughDotComponents =
            nested
            .appendingPathComponent("..")
            .appendingPathComponent("CAF\u{00C9}.gif")

        let canonicalKey = ExportDestinationReservation.key(for: canonical)
        XCTAssertEqual(ExportDestinationReservation.key(for: throughSymlink), canonicalKey)
        XCTAssertEqual(ExportDestinationReservation.key(for: throughDotComponents), canonicalKey)

        let sharpS = realParent.appendingPathComponent("Stra\u{00DF}e.mov")
        let expandedSharpS = realParent.appendingPathComponent("STRASSE.MOV")
        XCTAssertEqual(
            ExportDestinationReservation.key(for: sharpS),
            ExportDestinationReservation.key(for: expandedSharpS)
        )
    }

    func testFREXP005FailedAndDoneJobsReleaseDestinationReservation() async throws {
        let directory = try makeDirectory(prefix: "terminal-release")
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("reusable.mp4")
        let request = try ExportQueueFixtures.makeRequest(
            destinationURL: destination,
            frameCount: 1
        )
        let failedID = UUID()
        let queue = makeFailureThenSuccessQueue(failedID: failedID)

        try await queue.enqueue(request: request, displayName: "fails", id: failedID)
        let failed = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: failedID) == .failed
        }
        XCTAssertTrue(failed)

        let firstSuccessID = try await queue.enqueue(
            request: request,
            displayName: "after-failure"
        )
        let firstCompleted = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: firstSuccessID) == .done
        }
        XCTAssertTrue(firstCompleted)

        let secondSuccessID = try await queue.enqueue(
            request: request,
            displayName: "after-completion"
        )
        let secondCompleted = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: secondSuccessID) == .done
        }
        XCTAssertTrue(secondCompleted)
    }

    func testFREXP005VacantSelectionNeedsFreshConsentAfterEarlierJobPublishes() async throws {
        let directory = try makeDirectory(prefix: "stale-consent")
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("handoff.mp4")
        let initialRequest = try ExportQueueFixtures.makeRequest(
            destinationURL: destination,
            frameCount: 1
        )
        let queue = makeFailureThenSuccessQueue(failedID: UUID())
        let initialID = try await queue.enqueue(
            request: initialRequest,
            displayName: "publishes-first"
        )
        let initialCompleted = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: initialID) == .done
        }
        XCTAssertTrue(initialCompleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        let staleSelection = try ExportQueueFixtures.makeRequest(
            destinationURL: destination,
            frameCount: 1,
            destinationCollisionPolicy: .requireVacant
        )
        do {
            _ = try await queue.enqueue(request: staleSelection, displayName: "stale-selection")
            XCTFail("a file published after selection must require fresh overwrite consent")
        } catch let error as ExportQueueError {
            XCTAssertEqual(error, .destinationRequiresOverwriteConfirmation(destination))
        }
        let snapshotsAfterRefusal = await queue.snapshots()
        XCTAssertEqual(snapshotsAfterRefusal.count, 1)

        let confirmedSelection = try ExportQueueFixtures.makeRequest(
            destinationURL: destination,
            frameCount: 1,
            destinationCollisionPolicy: .replaceExisting
        )
        let replacementID = try await queue.enqueue(
            request: confirmedSelection,
            displayName: "confirmed-replacement"
        )
        let replacementCompleted = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: replacementID) == .done
        }
        XCTAssertTrue(replacementCompleted)
    }

    func testFREXP005PublicationCollisionIsVisibleOnTheFailedQueueJob() async throws {
        let directory = try makeDirectory(prefix: "publication-collision")
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("late-file.mp4")
        let intruder = Data("published-by-another-owner".utf8)
        let request = try ExportQueueFixtures.makeRequest(
            destinationURL: destination,
            frameCount: 1,
            destinationCollisionPolicy: .requireVacant
        )
        let queue = ExportQueue { jobID, request, onProgress in
            ExportSession(
                id: jobID,
                request: request,
                frameProvider: ControllableFrameProvider(),
                writerFactory: { temporaryURL, _ in
                    LifecycleWriter(outputURL: temporaryURL)
                },
                beforePublish: {
                    try? intruder.write(to: destination)
                },
                onFrameProgress: onProgress
            )
        }

        let jobID = try await queue.enqueue(request: request, displayName: "late collision")
        let failed = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: jobID) == .failed
        }
        XCTAssertTrue(failed)

        let snapshots = await queue.snapshots()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(
            snapshot.failure,
            .destinationRequiresOverwriteConfirmation(destination)
        )
        XCTAssertEqual(try Data(contentsOf: destination), intruder)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(leftovers.contains { $0.lastPathComponent.contains(".ajar-partial") })
    }

    private func makeFailureThenSuccessQueue(failedID: UUID) -> ExportQueue {
        ExportQueue { jobID, request, onProgress in
            let provider: any ExportVideoFrameProvider =
                jobID == failedID
                ? FailingFrameProvider(
                    error: .frameRenderFailed(frameIndex: 0, reason: "expected failure")
                )
                : ControllableFrameProvider()
            return ExportSession(
                id: jobID,
                request: request,
                frameProvider: provider,
                writerFactory: { temporaryURL, _ in
                    LifecycleWriter(outputURL: temporaryURL)
                },
                onFrameProgress: onProgress
            )
        }
    }

    private func makeDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-export-reservation-\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
