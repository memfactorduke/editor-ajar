// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal
import XCTest

@testable import AjarCore
@testable import AjarMedia

final class VideoFrameDecoderConcurrencyTests: XCTestCase {
    func testNFRSTAB001ConcurrentDecodesExceedCooperativePoolWidthWithoutDeadlock() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this runner")
        }

        let url = try temporaryMovieURL()
        try SyntheticMovieWriter.writeMovie(
            to: url,
            width: 16,
            height: 16,
            frameCount: 3,
            frameRate: 24
        )

        let decodeCount = ProcessInfo.processInfo.activeProcessorCount + 1
        let completion = expectation(description: "all concurrent decodes complete")
        let failures = DecodeFailureCollector()

        Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<decodeCount {
                    group.addTask {
                        do {
                            let decoder = try VideoFrameDecoder(device: device)
                            _ = try await decoder.decodeFrame(
                                from: url,
                                at: try RationalTime(value: 0, timescale: 24)
                            )
                        } catch {
                            failures.append(error)
                        }
                    }
                }
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 30)
        XCTAssertTrue(failures.errors.isEmpty, "Decode failures: \(failures.errors)")
    }

    private func temporaryMovieURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-media-concurrency-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("synthetic.mov")
    }
}

private final class DecodeFailureCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedErrors: [String] = []

    var errors: [String] {
        lock.withLock { storedErrors }
    }

    func append(_ error: Error) {
        lock.withLock {
            storedErrors.append(String(describing: error))
        }
    }
}
