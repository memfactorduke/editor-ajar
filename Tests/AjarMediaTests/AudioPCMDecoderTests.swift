// SPDX-License-Identifier: GPL-3.0-or-later
// swiftlint:disable file_length

// swiftlint:disable sorted_imports
@preconcurrency import AVFoundation
import AjarCore
import AudioToolbox
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import XCTest

@testable import AjarMedia

// swiftlint:enable sorted_imports

final class AudioPCMDecoderTests: XCTestCase {
    func testFRAUD001DecodesNativeWindowWithAbsoluteOffsetTimestampAndPadding() async throws {
        let sampleRate = 44_100
        let channelCount = 2
        let sourceSamples = PCMTestWaveWriter.interleavedRamp(
            frameCount: 64,
            channelCount: channelCount
        )
        let url = try temporaryURL(extension: "wav")
        try PCMTestWaveWriter.writeInt16Wave(
            to: url,
            sampleRate: sampleRate,
            channelCount: channelCount,
            samples: sourceSamples
        )

        // 10.5 through 12 native frames. floor/ceil gives 10..<12; explicit interpolation
        // guards expand that to 8..<13 without using a project sample rate.
        let sourceRange = try TimeRange(
            start: RationalTime(value: 21, timescale: 88_200),
            duration: RationalTime(value: 3, timescale: 88_200)
        )
        let window = try await AudioPCMDecoder().decodeWindow(
            from: url,
            sourceRange: sourceRange,
            leadingFrameCount: 2,
            trailingFrameCount: 1
        )

        XCTAssertEqual(window.sampleRate, sampleRate)
        XCTAssertEqual(window.channelCount, channelCount)
        XCTAssertEqual(window.frameOffset, 8)
        XCTAssertEqual(window.frameCount, 5)
        XCTAssertEqual(window.presentationTime, try RationalTime(value: 8, timescale: 44_100))
        XCTAssertEqual(window.samples.count, 10)

        let expected = sourceSamples[(8 * channelCount)..<(13 * channelCount)].map {
            Float($0) / 32_768
        }
        XCTAssertEqual(window.samples.count, expected.count)
        for (actual, expectedSample) in zip(window.samples, expected) {
            XCTAssertEqual(actual, expectedSample, accuracy: 0.000_001)
        }
        XCTAssertTrue(window.samples.contains { abs($0) > 0.01 })
    }

    func testNFRSTAB006MissingMalformedAndVideoOnlySourcesReturnTypedErrors() async throws {
        let decoder = AudioPCMDecoder()
        let missingURL = try temporaryURL(extension: "wav")
        let range = try TimeRange(
            start: .zero,
            duration: RationalTime(value: 1, timescale: 100)
        )

        do {
            _ = try await decoder.decodeWindow(from: missingURL, sourceRange: range)
            XCTFail("Expected a missing-source failure")
        } catch {
            XCTAssertEqual(error as? AudioPCMDecodeError, .missingSource(missingURL))
        }

        let malformedURL = try temporaryURL(extension: "wav")
        try Data("not a wave file".utf8).write(to: malformedURL)
        do {
            _ = try await decoder.decodeWindow(from: malformedURL, sourceRange: range)
            XCTFail("Expected an unsupported-source failure")
        } catch {
            XCTAssertEqual(error as? AudioPCMDecodeError, .unsupportedSource(malformedURL))
        }

        let videoOnlyURL = try temporaryURL(extension: "mov")
        try SyntheticMovieWriter.writeMovie(
            to: videoOnlyURL,
            width: 16,
            height: 16,
            frameCount: 2,
            frameRate: 24
        )
        do {
            _ = try await decoder.decodeWindow(from: videoOnlyURL, sourceRange: range)
            XCTFail("Expected a missing-audio-track failure")
        } catch {
            XCTAssertEqual(error as? AudioPCMDecodeError, .missingAudioTrack(videoOnlyURL))
        }
    }

    func testFRAUD001OptionalTrailingGuardMayStopAtHealthySourceEnd() async throws {
        let sampleRate = 8_000
        let sourceFrameCount = 8
        let sourceURL = try temporaryURL(extension: "wav")
        try PCMTestWaveWriter.writeInt16Wave(
            to: sourceURL,
            sampleRate: sampleRate,
            channelCount: 1,
            samples: PCMTestWaveWriter.interleavedRamp(
                frameCount: sourceFrameCount,
                channelCount: 1
            )
        )
        let sourceRange = try TimeRange(
            start: RationalTime(value: 6, timescale: Int64(sampleRate)),
            duration: RationalTime(value: 2, timescale: Int64(sampleRate))
        )

        let window = try await AudioPCMDecoder().decodeWindow(
            from: sourceURL,
            sourceRange: sourceRange,
            trailingFrameCount: 2
        )

        XCTAssertEqual(window.frameOffset, 6)
        XCTAssertEqual(window.frameCount, 2)
    }

    func testFRAUD001MuxedAssetZeroFillsOutsideOffsetAudioTrackTimeRange() async throws {
        let sampleRate = 8_000
        let audioFrameCount = sampleRate
        let sourceURL = try temporaryURL(extension: "mov")
        try OffsetAudioMovieWriter.writeMovie(
            to: sourceURL,
            audioSampleRate: sampleRate,
            audioStartFrame: sampleRate,
            audioSamples: [Float](repeating: 0.25, count: audioFrameCount)
        )

        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.load(.tracks)
        let audioTrack = try XCTUnwrap(tracks.first(where: { $0.mediaType == .audio }))
        let audioTimeRange = try await audioTrack.load(.timeRange)
        let audioSegments = try await audioTrack.load(.segments)
        XCTAssertEqual(audioTimeRange.start, CMTime(value: 0, timescale: 1))
        XCTAssertEqual(audioTimeRange.duration, CMTime(value: 2, timescale: 1))
        let emptySegment = try XCTUnwrap(audioSegments.first(where: \.isEmpty))
        XCTAssertEqual(emptySegment.timeMapping.target.start, .zero)
        XCTAssertEqual(emptySegment.timeMapping.target.duration, CMTime(value: 1, timescale: 1))
        let contentSegment = try XCTUnwrap(audioSegments.first(where: { !$0.isEmpty }))
        XCTAssertEqual(contentSegment.timeMapping.target.start, CMTime(value: 1, timescale: 1))
        XCTAssertEqual(contentSegment.timeMapping.target.duration, CMTime(value: 1, timescale: 1))

        let requestedFrameCount = sampleRate * 3
        let window = try await AudioPCMDecoder().decodeWindow(
            from: sourceURL,
            sourceRange: try TimeRange(
                start: .zero,
                duration: RationalTime(
                    value: Int64(requestedFrameCount),
                    timescale: Int64(sampleRate)
                )
            )
        )

        XCTAssertEqual(window.sampleRate, sampleRate)
        XCTAssertEqual(window.channelCount, 1)
        XCTAssertEqual(window.frameOffset, 0)
        XCTAssertEqual(window.frameCount, requestedFrameCount)
        XCTAssertTrue(window.samples[..<sampleRate].allSatisfy { $0 == 0 })
        for sample in window.samples[sampleRate..<(sampleRate * 2)] {
            XCTAssertEqual(sample, 0.25, accuracy: 0.000_001)
        }
        XCTAssertTrue(window.samples[(sampleRate * 2)...].allSatisfy { $0 == 0 })
    }

    func testNFRSTAB006PartialWindowWithinDeclaredBoundsReturnsTypedUnderDelivery() async throws {
        let sampleRate = 8_000
        let sourceFrameCount = 8
        let declaredFrameCount = 16
        let sourceURL = try temporaryURL(extension: "wav")
        try PCMTestWaveWriter.writeInt16Wave(
            to: sourceURL,
            sampleRate: sampleRate,
            channelCount: 1,
            samples: PCMTestWaveWriter.interleavedRamp(
                frameCount: sourceFrameCount,
                channelCount: 1
            )
        )
        let declaredDuration = try RationalTime(
            value: Int64(declaredFrameCount),
            timescale: Int64(sampleRate)
        )
        let media = MediaRef(
            id: UUID(),
            sourceURL: sourceURL,
            contentHash: nil,
            metadata: MediaMetadata(
                codecID: "pcm_s16le",
                pixelDimensions: nil,
                frameRate: nil,
                duration: declaredDuration,
                colorSpace: .unspecified,
                audioChannelLayout: AudioChannelLayout(channelCount: 1),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        let sourceRange = try TimeRange(start: .zero, duration: declaredDuration)

        do {
            _ = try await AudioPCMDecoder().decodeWindow(
                from: media,
                sourceRange: sourceRange
            )
            XCTFail("Expected partial native PCM delivery to fail")
        } catch {
            XCTAssertEqual(
                error as? AudioPCMDecodeError,
                .windowUnderDelivered(
                    sourceURL,
                    expectedFrameRange: 0..<declaredFrameCount,
                    actualFrameRange: 0..<sourceFrameCount
                )
            )
        }
    }

}

extension AudioPCMDecoderTests {

    func testNFRSTAB001OversizedWindowFailsBeforePCMAllocation() async throws {
        let sampleRate = 48_000
        let sourceURL = try temporaryURL(extension: "wav")
        try PCMTestWaveWriter.writeInt16Wave(
            to: sourceURL,
            sampleRate: sampleRate,
            channelCount: 2,
            samples: PCMTestWaveWriter.interleavedRamp(frameCount: 8, channelCount: 2)
        )
        let frameCount = (AudioPCMDecoder.maximumWindowSampleBytes / (2 * 4)) + 1
        let sourceRange = try TimeRange(
            start: .zero,
            duration: RationalTime(value: Int64(frameCount), timescale: Int64(sampleRate))
        )

        do {
            _ = try await AudioPCMDecoder().decodeWindow(
                from: sourceURL,
                sourceRange: sourceRange
            )
            XCTFail("Expected the oversized window to fail before decode allocation")
        } catch {
            XCTAssertEqual(
                error as? AudioPCMDecodeError,
                .windowTooLarge(
                    sourceURL,
                    frameCount: frameCount,
                    channelCount: 2,
                    maximumSampleBytes: AudioPCMDecoder.maximumWindowSampleBytes
                )
            )
        }
    }

    func testNFRSTAB001ConcurrentDecodeUsesBalancedSecurityScopes() async throws {
        let sourceURL = try temporaryURL(extension: "wav")
        try PCMTestWaveWriter.writeInt16Wave(
            to: sourceURL,
            sampleRate: 8_000,
            channelCount: 1,
            samples: PCMTestWaveWriter.interleavedRamp(frameCount: 80, channelCount: 1)
        )
        let range = try TimeRange(
            start: RationalTime(value: 10, timescale: 8_000),
            duration: RationalTime(value: 20, timescale: 8_000)
        )
        let securityScope = SecurityScopeSpy(startsAccess: true)
        let decoder = AudioPCMDecoder(securityScope: securityScope)
        let decodeCount = max(4, ProcessInfo.processInfo.activeProcessorCount + 1)
        XCTAssertEqual(AudioPCMDecoder.maximumConcurrentAudioDecodes, 4)

        let windows = try await withThrowingTaskGroup(
            of: DecodedAudioWindow.self,
            returning: [DecodedAudioWindow].self
        ) { group in
            for _ in 0..<decodeCount {
                group.addTask {
                    try await decoder.decodeWindow(from: sourceURL, sourceRange: range)
                }
            }
            var decoded: [DecodedAudioWindow] = []
            for try await window in group {
                decoded.append(window)
            }
            return decoded
        }

        XCTAssertEqual(windows.count, decodeCount)
        XCTAssertTrue(windows.allSatisfy { $0.frameOffset == 10 && $0.frameCount == 20 })
        XCTAssertEqual(securityScope.counts.starts, decodeCount)
        XCTAssertEqual(securityScope.counts.stops, decodeCount)
    }

    func testNFRSTAB004QueuedDecodeCancellationCompletesBeforeActiveWorkerExits() async throws {
        let executor = BoundedAudioDecodeExecutor(
            label: "org.editorajar.audio-pcm-decode.tests",
            maximumConcurrentOperationCount: 1
        )
        let activeWorkerStarted = DispatchSemaphore(value: 0)
        let releaseActiveWorker = DispatchSemaphore(value: 0)
        let activeDecode = Task {
            try await executor.run(cancellation: AudioPCMDecodeCancellation()) {
                activeWorkerStarted.signal()
                releaseActiveWorker.wait()
                return 1
            }
        }
        defer {
            releaseActiveWorker.signal()
            activeDecode.cancel()
        }
        XCTAssertEqual(activeWorkerStarted.wait(timeout: .now() + 2), .success)

        let queuedWorkStarted = LockedBoolean()
        let queuedDecode = Task {
            try await executor.run(cancellation: AudioPCMDecodeCancellation()) {
                queuedWorkStarted.setTrue()
                return 2
            }
        }
        let submissionDeadline = Date().addingTimeInterval(2)
        while executor.operationCountForTesting < 2, Date() < submissionDeadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(
            executor.operationCountForTesting,
            2,
            "the second decode must be queued behind the saturated worker before cancellation"
        )

        queuedDecode.cancel()
        let cancellationCompleted = expectation(description: "queued decode cancellation")
        Task {
            do {
                _ = try await queuedDecode.value
                XCTFail("Expected the queued decode to be cancelled")
            } catch is CancellationError {
                // Expected: the queued continuation resumes without waiting for the active reader.
            } catch {
                XCTFail("Expected CancellationError, received \(error)")
            }
            cancellationCompleted.fulfill()
        }
        await fulfillment(of: [cancellationCompleted], timeout: 1)
        XCTAssertFalse(queuedWorkStarted.value)

        releaseActiveWorker.signal()
        let activeResult = try await activeDecode.value
        XCTAssertEqual(activeResult, 1)
    }

    func testNFRSTAB004CancellationBalancesSecurityScopeAndStopsDecode() async throws {
        let sourceURL = try temporaryURL(extension: "wav")
        try PCMTestWaveWriter.writeInt16Wave(
            to: sourceURL,
            sampleRate: 8_000,
            channelCount: 1,
            samples: PCMTestWaveWriter.interleavedRamp(frameCount: 80, channelCount: 1)
        )
        let range = try TimeRange(
            start: .zero,
            duration: RationalTime(value: 80, timescale: 8_000)
        )
        let securityScope = BlockingScopeSpy()
        let decoder = AudioPCMDecoder(securityScope: securityScope)
        let decode = Task {
            try await decoder.decodeWindow(from: sourceURL, sourceRange: range)
        }

        XCTAssertEqual(
            securityScope.waitUntilStarted(timeout: .now() + 2),
            .success,
            "decode should enter its security-scoped lifetime before cancellation"
        )
        decode.cancel()
        securityScope.resume()

        do {
            _ = try await decode.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation must escape instead of becoming silence or a typed media error.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        XCTAssertEqual(securityScope.counts.starts, 1)
        XCTAssertEqual(securityScope.counts.stops, 1)
    }

    func testNFRSTAB006SecurityScopeStopsOnFailureAndOnlyWhenStarted() async throws {
        let missingURL = try temporaryURL(extension: "wav")
        let range = try TimeRange(
            start: .zero,
            duration: RationalTime(value: 1, timescale: 100)
        )

        let startedScope = SecurityScopeSpy(startsAccess: true)
        do {
            _ = try await AudioPCMDecoder(securityScope: startedScope).decodeWindow(
                from: missingURL,
                sourceRange: range
            )
        } catch {
            XCTAssertEqual(error as? AudioPCMDecodeError, .missingSource(missingURL))
        }
        XCTAssertEqual(startedScope.counts.starts, 1)
        XCTAssertEqual(startedScope.counts.stops, 1)

        let ordinaryScope = SecurityScopeSpy(startsAccess: false)
        do {
            _ = try await AudioPCMDecoder(securityScope: ordinaryScope).decodeWindow(
                from: missingURL,
                sourceRange: range
            )
        } catch {
            XCTAssertEqual(error as? AudioPCMDecodeError, .missingSource(missingURL))
        }
        XCTAssertEqual(ordinaryScope.counts.starts, 1)
        XCTAssertEqual(ordinaryScope.counts.stops, 0)
    }

    func testFRAUD001RejectsNegativePaddingAndSourceTimeBeforeOpeningReader() async throws {
        let url = try temporaryURL(extension: "wav")
        let decoder = AudioPCMDecoder()
        let validRange = try TimeRange(
            start: .zero,
            duration: RationalTime(value: 1, timescale: 100)
        )
        do {
            _ = try await decoder.decodeWindow(
                from: url,
                sourceRange: validRange,
                leadingFrameCount: -1
            )
            XCTFail("Expected invalid padding")
        } catch {
            XCTAssertEqual(
                error as? AudioPCMDecodeError,
                .invalidFramePadding(leading: -1, trailing: 0)
            )
        }

        let negativeRange = try TimeRange(
            start: RationalTime(value: -1, timescale: 100),
            duration: RationalTime(value: 1, timescale: 100)
        )
        do {
            _ = try await decoder.decodeWindow(from: url, sourceRange: negativeRange)
            XCTFail("Expected invalid source range")
        } catch {
            XCTAssertEqual(error as? AudioPCMDecodeError, .invalidSourceRange(negativeRange))
        }
    }

    private func temporaryURL(extension pathExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-audio-pcm-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("source").appendingPathExtension(pathExtension)
    }
}

private final class SecurityScopeSpy: AudioPCMDecoderSecurityScopeAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private let startsAccess: Bool
    private var startCount = 0
    private var stopCount = 0

    init(startsAccess: Bool) {
        self.startsAccess = startsAccess
    }

    var counts: (starts: Int, stops: Int) {
        lock.withLock { (startCount, stopCount) }
    }

    func startAccessing(_ sourceURL: URL) -> Bool {
        _ = sourceURL
        lock.withLock {
            startCount += 1
        }
        return startsAccess
    }

    func stopAccessing(_ sourceURL: URL) {
        _ = sourceURL
        lock.withLock {
            stopCount += 1
        }
    }
}

private final class BlockingScopeSpy: AudioPCMDecoderSecurityScopeAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private let didStart = DispatchSemaphore(value: 0)
    private let mayContinue = DispatchSemaphore(value: 0)
    private var startCount = 0
    private var stopCount = 0

    var counts: (starts: Int, stops: Int) {
        lock.withLock { (startCount, stopCount) }
    }

    func startAccessing(_ sourceURL: URL) -> Bool {
        _ = sourceURL
        lock.withLock {
            startCount += 1
        }
        didStart.signal()
        mayContinue.wait()
        return true
    }

    func stopAccessing(_ sourceURL: URL) {
        _ = sourceURL
        lock.withLock {
            stopCount += 1
        }
    }

    func waitUntilStarted(timeout: DispatchTime) -> DispatchTimeoutResult {
        didStart.wait(timeout: timeout)
    }

    func resume() {
        mayContinue.signal()
    }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.withLock { storedValue }
    }

    func setTrue() {
        lock.withLock {
            storedValue = true
        }
    }
}

private enum PCMTestWaveWriter {
    static func interleavedRamp(frameCount: Int, channelCount: Int) -> [Int16] {
        var samples: [Int16] = []
        samples.reserveCapacity(frameCount * channelCount)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let magnitude = Int16((frame + 1) * 200)
                samples.append(channel.isMultiple(of: 2) ? magnitude : -magnitude)
            }
        }
        return samples
    }

    static func writeInt16Wave(
        to url: URL,
        sampleRate: Int,
        channelCount: Int,
        samples: [Int16]
    ) throws {
        precondition(sampleRate > 0)
        precondition(channelCount > 0)
        precondition(samples.count.isMultiple(of: channelCount))

        let byteCount = samples.count * MemoryLayout<Int16>.size
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + byteCount), to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(channelCount), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * channelCount * MemoryLayout<Int16>.size), to: &data)
        append(UInt16(channelCount * MemoryLayout<Int16>.size), to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        append(UInt32(byteCount), to: &data)
        for sample in samples {
            append(sample, to: &data)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

private enum OffsetAudioMovieWriter {
    private static let videoWidth = 16
    private static let videoHeight = 16
    private static let videoFrameCount = 4

    // swiftlint:disable:next function_body_length
    static func writeMovie(
        to url: URL,
        audioSampleRate: Int,
        audioStartFrame: Int,
        audioSamples: [Float]
    ) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        let videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw OffsetAudioMovieWriterError.cannotAddInput
        }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw OffsetAudioMovieWriterError.writerFailed(errorDescription(for: writer))
        }
        writer.startSession(atSourceTime: .zero)

        do {
            for frameIndex in 0..<videoFrameCount {
                try waitUntilReady(videoInput, writer: writer)
                let pixelBuffer = try makePixelBuffer(frameIndex: frameIndex)
                guard
                    videoAdaptor.append(
                        pixelBuffer,
                        withPresentationTime: CMTime(value: Int64(frameIndex), timescale: 1)
                    )
                else {
                    throw OffsetAudioMovieWriterError.writerFailed(errorDescription(for: writer))
                }
            }
            try waitUntilReady(audioInput, writer: writer)
            let audioBuffer = try makeAudioSampleBuffer(
                samples: audioSamples,
                sampleRate: audioSampleRate,
                presentationFrame: audioStartFrame
            )
            guard audioInput.append(audioBuffer) else {
                throw OffsetAudioMovieWriterError.writerFailed(errorDescription(for: writer))
            }
        } catch {
            writer.cancelWriting()
            throw error
        }

        videoInput.markAsFinished()
        audioInput.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw OffsetAudioMovieWriterError.writerFailed(errorDescription(for: writer))
        }
    }

    private static func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) throws {
        let deadline = Date().addingTimeInterval(5)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, Date() < deadline else {
                throw OffsetAudioMovieWriterError.writerFailed(errorDescription(for: writer))
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private static func errorDescription(for writer: AVAssetWriter) -> String {
        writer.error.map(String.init(describing:)) ?? "unknown writer error"
    }

    private static func makePixelBuffer(frameIndex: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            videoWidth,
            videoHeight,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw OffsetAudioMovieWriterError.pixelBufferCreationFailed(status)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw OffsetAudioMovieWriterError.missingPixelBufferStorage
        }
        memset(
            baseAddress,
            Int32(frameIndex + 1),
            CVPixelBufferGetBytesPerRow(pixelBuffer) * videoHeight
        )
        return pixelBuffer
    }

    // swiftlint:disable:next function_body_length
    private static func makeAudioSampleBuffer(
        samples: [Float],
        sampleRate: Int,
        presentationFrame: Int
    ) throws -> CMSampleBuffer {
        let bytesPerFrame = MemoryLayout<Float>.size
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw OffsetAudioMovieWriterError.audioSampleBufferFailed(status)
        }

        let byteCount = samples.count * bytesPerFrame
        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw OffsetAudioMovieWriterError.audioSampleBufferFailed(status)
        }
        status = samples.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return OSStatus(kCMBlockBufferBadLengthParameterErr)
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw OffsetAudioMovieWriterError.audioSampleBufferFailed(status)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(
                value: Int64(presentationFrame),
                timescale: Int32(sampleRate)
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: samples.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw OffsetAudioMovieWriterError.audioSampleBufferFailed(status)
        }
        return sampleBuffer
    }
}

private enum OffsetAudioMovieWriterError: Error {
    case cannotAddInput
    case writerFailed(String)
    case pixelBufferCreationFailed(CVReturn)
    case missingPixelBufferStorage
    case audioSampleBufferFailed(OSStatus)
}
