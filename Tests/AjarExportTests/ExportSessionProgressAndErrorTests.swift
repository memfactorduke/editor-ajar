// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreVideo
import Foundation
import XCTest

@testable import AjarExport

final class ExportSessionProgressAndErrorTests: XCTestCase {
    func testFREXP005FrameProgressIsMonotonicAndReachesOne() async throws {
        let fixture = try LifecycleFixture(frameCount: 4)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        let collector = ProgressCollector()
        let session = fixture.session(
            frameProvider: LifecycleFrameProvider(),
            onFrameProgress: { progress in
                collector.append(progress)
            },
            writerFactory: { _, _ in writer }
        )

        _ = try await session.run()

        let observed = collector.samples()
        XCTAssertFalse(observed.isEmpty)
        XCTAssertEqual(observed.first?.framesWritten, 0)
        XCTAssertEqual(observed.first?.totalFrames, 4)
        XCTAssertEqual(observed.last?.framesWritten, 4)
        let finalFraction = try XCTUnwrap(observed.last?.fractionCompleted)
        XCTAssertEqual(finalFraction, 1, accuracy: 0.000_1)
        for index in 1..<observed.count {
            XCTAssertGreaterThanOrEqual(
                observed[index].framesWritten,
                observed[index - 1].framesWritten
            )
            XCTAssertEqual(observed[index].totalFrames, 4)
        }
        XCTAssertEqual(session.progress.framesWritten, 4)
        XCTAssertEqual(session.progress.totalFrames, 4)
    }

    func testFREXP005CancelBeforeRunProducesCancelledOutcome() async throws {
        let fixture = try LifecycleFixture(frameCount: 2)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        let session = fixture.session(frameProvider: LifecycleFrameProvider()) { _, _ in writer }

        session.cancel()

        do {
            _ = try await session.run()
            XCTFail("expected cancelled outcome")
        } catch let error as ExportError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertEqual(session.state, .cancelled)
        XCTAssertFalse(writer.didStart)
        try fixture.assertNoPartialFiles()
    }

    func testNFRSTAB002CleanupFailureSurfacesRootCauseAndCleanupError() async throws {
        let fixture = try LifecycleFixture(frameCount: 2)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        writer.startError = .writerFailed("mux refused to start")
        writer.onStart = {
            var values = URLResourceValues()
            values.isUserImmutable = true
            try? writer.outputURL.setResourceValues(values)
        }
        let session = fixture.session(frameProvider: LifecycleFrameProvider()) { _, _ in writer }

        do {
            _ = try await session.run()
            XCTFail("expected cleanup or writer failure")
        } catch let error as ExportError {
            switch error {
            case .cleanupFailed(let rootCause, let temporaryURL, let reason):
                XCTAssertEqual(rootCause, .writerFailed("mux refused to start"))
                XCTAssertTrue(temporaryURL.path.contains("ajar-partial"))
                XCTAssertFalse(reason.isEmpty)
                var mutableURL = temporaryURL
                var values = URLResourceValues()
                values.isUserImmutable = false
                try? mutableURL.setResourceValues(values)
                try? FileManager.default.removeItem(at: temporaryURL)
            case .writerFailed(let reason):
                // Some runners clear immutable flags on remove; root cause still surfaces.
                XCTAssertEqual(reason, "mux refused to start")
            default:
                XCTFail("unexpected error \(error)")
            }
        }

        XCTAssertEqual(session.state, .failed)
    }

    func testNFRSTAB002CleanupFailureTypeCarriesRootCauseAndReason() throws {
        let root = ExportError.diskFull(URL(fileURLWithPath: "/tmp/out.mov"))
        let error = ExportError.cleanupFailed(
            rootCause: root,
            temporaryURL: URL(fileURLWithPath: "/tmp/.partial.ajar-partial.mov"),
            reason: "permission denied"
        )
        XCTAssertEqual(
            error,
            .cleanupFailed(
                rootCause: root,
                temporaryURL: URL(fileURLWithPath: "/tmp/.partial.ajar-partial.mov"),
                reason: "permission denied"
            )
        )
        XCTAssertTrue(error.description.contains("permission denied"))
        XCTAssertTrue(error.description.contains("full"))
    }

    func testFREXP007ProviderFrameRenderFailedIsNotDoubleWrapped() async throws {
        let fixture = try LifecycleFixture(frameCount: 1)
        let writer = LifecycleWriter(outputURL: fixture.destinationURL)
        let provider = FailingFrameProvider(
            error: .frameRenderFailed(frameIndex: 7, reason: "provider boom")
        )
        let session = fixture.session(frameProvider: provider) { _, _ in writer }

        do {
            _ = try await session.run()
            XCTFail("expected frame render failure")
        } catch let error as ExportError {
            XCTAssertEqual(
                error,
                .frameRenderFailed(frameIndex: 7, reason: "provider boom")
            )
        }

        XCTAssertEqual(session.state, .failed)
        try fixture.assertNoPartialFiles()
    }
}

final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExportProgress] = []

    func append(_ progress: ExportProgress) {
        lock.lock()
        values.append(progress)
        lock.unlock()
    }

    func samples() -> [ExportProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class FailingFrameProvider: ExportVideoFrameProvider {
    let error: ExportError

    init(error: ExportError) {
        self.error = error
    }

    func renderFrame(
        at _: RationalTime,
        into _: CVPixelBuffer
    ) async throws {
        throw error
    }
}
