// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarExport

final class ExportQueueIdentityTests: XCTestCase {
    func testFREXP005ConcurrentDuplicateJobIDCannotReplaceActiveReservation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = ControllableFrameProvider(holdUntilRelease: true)
        let queue = makeHeldQueue(provider: provider)
        let jobID = UUID()
        let originalDestination = directory.appendingPathComponent("original.mp4")
        let originalRequest = try ExportQueueFixtures.makeRequest(
            destinationURL: originalDestination,
            frameCount: 2
        )
        try await queue.enqueue(
            request: originalRequest,
            displayName: "original",
            id: jobID
        )
        let running = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: jobID) == .running
        }
        XCTAssertTrue(running)

        let errors = try await enqueueDuplicateAttempts(
            on: queue,
            jobID: jobID,
            directory: directory
        )
        XCTAssertEqual(errors.count, 8)
        XCTAssertTrue(errors.allSatisfy { $0 == .duplicateJobID(jobID) })

        let snapshots = await queue.snapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.id, jobID)
        XCTAssertEqual(snapshots.first?.destinationURL, originalDestination)
        try await assertDestinationStillReserved(
            originalDestination,
            on: queue
        )

        provider.releaseAll()
        let completed = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: jobID) == .done
        }
        XCTAssertTrue(completed)
    }

    private func makeHeldQueue(provider: ControllableFrameProvider) -> ExportQueue {
        ExportQueue { jobID, request, onProgress in
            ExportSession(
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

    private func enqueueDuplicateAttempts(
        on queue: ExportQueue,
        jobID: UUID,
        directory: URL
    ) async throws -> [ExportQueueError?] {
        let requests = try (0..<8).map { index in
            try ExportQueueFixtures.makeRequest(
                destinationURL: directory.appendingPathComponent("duplicate-\(index).mp4"),
                frameCount: 1
            )
        }
        return await withTaskGroup(of: ExportQueueError?.self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    do {
                        _ = try await queue.enqueue(
                            request: request,
                            displayName: "duplicate-\(index)",
                            id: jobID
                        )
                        return nil
                    } catch let error as ExportQueueError {
                        return error
                    } catch {
                        return nil
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
    }

    private func assertDestinationStillReserved(
        _ destination: URL,
        on queue: ExportQueue
    ) async throws {
        let request = try ExportQueueFixtures.makeRequest(
            destinationURL: destination,
            frameCount: 1
        )
        do {
            _ = try await queue.enqueue(request: request, displayName: "colliding")
            XCTFail("the original active job must retain its destination reservation")
        } catch let error as ExportQueueError {
            XCTAssertEqual(error, .destinationAlreadyQueued(destination))
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-export-queue-duplicate-id-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
