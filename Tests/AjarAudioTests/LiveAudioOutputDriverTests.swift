// SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio
import Darwin
import XCTest

@testable import AjarAudio

final class LiveAudioOutputDriverTests: XCTestCase {
    func testFRAUD007LiveDriverRendersPublishedPlanIntoCallerOwnedOutput() throws {
        let driver = try LiveAudioOutputDriver(format: Self.testFormat)
        try driver.publish(try plan(samples: [1, 2, 3, 4]))

        var output = [Float](repeating: -1, count: 4)
        let renderedFrames = output.withUnsafeMutableBufferPointer { pointer in
            driver.renderForTesting(into: pointer)
        }
        let report = try XCTUnwrap(driver.safetyReport())

        XCTAssertEqual(renderedFrames, 2)
        XCTAssertEqual(output, [1, 2, 3, 4])
        XCTAssertTrue(report.isRealtimeSafe)
        XCTAssertEqual(report.handoffKind, .lockFreeAtomicSlotRing)
    }

    func testFRAUD007LiveDriverRendersSilenceWhenNoPlanIsPublished() throws {
        let driver = try LiveAudioOutputDriver(format: Self.testFormat)

        var output = [Float](repeating: -1, count: 4)
        let renderedFrames = output.withUnsafeMutableBufferPointer { pointer in
            driver.renderForTesting(into: pointer)
        }

        XCTAssertEqual(renderedFrames, 0)
        XCTAssertEqual(output, [0, 0, 0, 0])
    }

    func testFRAUD007LiveDriverZeroFillsAfterShortPlanIsExhausted() throws {
        let driver = try LiveAudioOutputDriver(format: Self.testFormat)
        try driver.publish(try plan(samples: [0.25, -0.25]))

        var output = [Float](repeating: -1, count: 6)
        let renderedFrames = output.withUnsafeMutableBufferPointer { pointer in
            driver.renderForTesting(into: pointer)
        }

        XCTAssertEqual(renderedFrames, 1)
        XCTAssertEqual(output, [0.25, -0.25, 0, 0, 0, 0])
    }

    func testFRAUD007RealtimePlanRendersNonInterleavedCoreAudioOutput() throws {
        var plan = try plan(samples: [1, 2, 3, 4, 5, 6])
        var left = [Float](repeating: -1, count: 3)
        var right = [Float](repeating: -1, count: 3)
        var renderedFrames = -1
        let buffers = AudioBufferList.allocate(maximumBuffers: 2)
        defer {
            free(buffers.unsafeMutablePointer)
        }

        try left.withUnsafeMutableBufferPointer { leftPointer in
            try right.withUnsafeMutableBufferPointer { rightPointer in
                let leftBaseAddress = try XCTUnwrap(leftPointer.baseAddress)
                let rightBaseAddress = try XCTUnwrap(rightPointer.baseAddress)
                buffers[0] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(leftPointer.count * MemoryLayout<Float>.stride),
                    mData: UnsafeMutableRawPointer(leftBaseAddress)
                )
                buffers[1] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(rightPointer.count * MemoryLayout<Float>.stride),
                    mData: UnsafeMutableRawPointer(rightBaseAddress)
                )

                renderedFrames = plan.renderNonInterleaved(
                    into: buffers.unsafeMutablePointer,
                    frameCount: 3
                )
            }
        }

        XCTAssertEqual(renderedFrames, 3)
        XCTAssertEqual(left, [1, 3, 5])
        XCTAssertEqual(right, [2, 4, 6])
    }

    private static let testFormat = AudioRenderFormat(sampleRate: 48_000, channelCount: 2)

    private func plan(samples: [Float]) throws -> RealtimeAudioRenderPlan {
        RealtimeAudioRenderPlan(
            buffer: try RenderedAudioBuffer(
                format: Self.testFormat,
                frameCount: samples.count / 2,
                samples: samples
            )
        )
    }
}
