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

    func testFREXP005FailedJobReleasesAndDoneJobRetainsDestinationReservation() async throws {
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

        // Models a Save panel that selected this path before the first success published. Even if
        // actor scheduling delays enqueue until after completion, the stale selection must not be
        // allowed to overwrite the just-published result without fresh user consent.
        do {
            _ = try await queue.enqueue(
                request: request,
                displayName: "stale-selection-after-completion"
            )
            XCTFail("a completed output must retain its reservation")
        } catch let error as ExportQueueError {
            XCTAssertEqual(error, .destinationAlreadyQueued(destination))
        }
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
