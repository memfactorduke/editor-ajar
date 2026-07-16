// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@testable import AjarCore
@testable import AjarExport
@testable import AjarMedia

final class MediaTranscodeFrameProviderTests: XCTestCase {
    func testFRMED004DecodesFirstAndLaterFramesIntoProxyPixelBuffers() async throws {
        let directory = try temporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.mov")
        let resolution = PixelDimensions(width: 64, height: 36)
        try SyntheticMovieWriter.writeMovie(
            to: sourceURL,
            width: resolution.width,
            height: resolution.height,
            frameCount: 3,
            frameRate: 24
        )

        let provider = MediaTranscodeFrameProvider(
            mediaID: UUID(),
            sourceURL: sourceURL,
            frameRate: try FrameRate(frames: 24),
            frameCount: 3,
            outputResolution: resolution
        )

        for index in [Int64(0), Int64(2)] {
            let destination = try makePixelBuffer(resolution: resolution)
            try zero(destination)
            try await provider.provideFrame(index: index, into: destination)

            XCTAssertEqual(CVPixelBufferGetWidth(destination), resolution.width)
            XCTAssertEqual(CVPixelBufferGetHeight(destination), resolution.height)
            XCTAssertEqual(
                CVPixelBufferGetPixelFormatType(destination),
                kCVPixelFormatType_64ARGB
            )
            XCTAssertTrue(
                try containsNonzeroBytes(destination),
                "decoded frame \(index) should populate the destination buffer"
            )
        }
    }

    func testFRMED004ProductionProviderQueuePublishesPlayableProxy() async throws {
        let directory = try temporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.mov")
        let destinationURL = directory.appendingPathComponent("proxy.mov")
        let resolution = PixelDimensions(width: 64, height: 36)
        let frameRate = try FrameRate(frames: 24)
        let frameCount: Int64 = 3
        try SyntheticMovieWriter.writeMovie(
            to: sourceURL,
            width: resolution.width,
            height: resolution.height,
            frameCount: Int(frameCount),
            frameRate: 24
        )

        let request = ProxyGenerationRequest(
            mediaID: UUID(),
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            relativePath: "caches/proxies/integration.mov",
            resolution: resolution,
            frameCount: frameCount,
            frameRate: frameRate
        )
        let queue = ProxyGenerationQueue { jobID, request, onProgress in
            Self.makeProductionSession(
                jobID: jobID,
                request: request,
                onProgress: onProgress
            )
        }
        let jobID = await queue.enqueue(
            ProxyGenerationJob(
                mediaID: request.mediaID,
                displayName: "Production provider integration",
                request: request
            )
        )

        let state = try await waitForTerminalState(queue: queue, jobID: jobID)
        if state == .failed {
            let failure = await queue.snapshots().first(where: { $0.id == jobID })?.failure
            XCTFail("production proxy generation failed: \(String(describing: failure))")
        }
        XCTAssertEqual(state, .done)
        let result = await queue.result(for: jobID)
        XCTAssertEqual(result?.videoFrameCount, frameCount)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        try await assertPlayableProxy(
            at: destinationURL,
            frameCount: frameCount,
            resolution: resolution,
            directory: directory
        )
    }

    func testNFRSTAB006MissingSourceIsTypedAndLeavesNoProxyOrPartialFile() async throws {
        let directory = try temporaryDirectory()
        let sourceURL = directory.appendingPathComponent("missing.mov")
        try await assertTypedFailureAndCleanup(
            sourceURL: sourceURL,
            expectedError: .missingSource(sourceURL),
            directory: directory
        )
    }

    func testNFRSTAB006MalformedSourceIsTypedAndLeavesNoProxyOrPartialFile() async throws {
        let directory = try temporaryDirectory()
        let sourceURL = directory.appendingPathComponent("malformed.mov")
        try Data("not a movie".utf8).write(to: sourceURL)
        try await assertTypedFailureAndCleanup(
            sourceURL: sourceURL,
            expectedError: .unsupportedSource(sourceURL),
            directory: directory
        )
    }

    func testNFRSTAB006OutOfRangeFrameKeepsTypedError() async throws {
        let directory = try temporaryDirectory()
        let sourceURL = directory.appendingPathComponent("unused.mov")
        let resolution = PixelDimensions(width: 64, height: 36)
        let provider = MediaTranscodeFrameProvider(
            mediaID: UUID(),
            sourceURL: sourceURL,
            frameRate: try FrameRate(frames: 24),
            frameCount: 1,
            outputResolution: resolution
        )

        for index in [Int64(-1), Int64(1)] {
            do {
                try await provider.provideFrame(
                    index: index,
                    into: try makePixelBuffer(resolution: resolution)
                )
                XCTFail("expected an out-of-range error")
            } catch {
                XCTAssertEqual(error as? MediaTranscodeError, .frameIndexOutOfRange(index))
            }
        }
    }
}

private extension MediaTranscodeFrameProviderTests {
    private func assertTypedFailureAndCleanup(
        sourceURL: URL,
        expectedError: MediaTranscodeError,
        directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let resolution = PixelDimensions(width: 64, height: 36)
        let frameRate = try FrameRate(frames: 24)
        try await assertDirectTypedFailure(
            sourceURL: sourceURL,
            expectedError: expectedError,
            resolution: resolution,
            frameRate: frameRate
        )

        let outputDirectory = directory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let destinationURL = outputDirectory.appendingPathComponent("failed-proxy.mov")
        let request = ProxyGenerationRequest(
            mediaID: UUID(),
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            relativePath: "caches/proxies/failed.mov",
            resolution: resolution,
            frameCount: 1,
            frameRate: frameRate
        )
        let queue = ProxyGenerationQueue { jobID, request, onProgress in
            Self.makeProductionSession(
                jobID: jobID,
                request: request,
                onProgress: onProgress
            )
        }
        let jobID = await queue.enqueue(
            ProxyGenerationJob(
                mediaID: request.mediaID,
                displayName: "Expected source failure",
                request: request
            )
        )
        let state = try await waitForTerminalState(queue: queue, jobID: jobID)
        XCTAssertEqual(state, .failed, file: file, line: line)
        let snapshots = await queue.snapshots()
        let failure = snapshots.first(where: { $0.id == jobID })?.failure
        XCTAssertEqual(
            failure,
            .writerFailed(expectedError.description),
            file: file,
            line: line
        )

        try assertNoPublishedOutput(
            at: destinationURL,
            in: outputDirectory,
            file: file,
            line: line
        )
    }

    private func assertDirectTypedFailure(
        sourceURL: URL,
        expectedError: MediaTranscodeError,
        resolution: PixelDimensions,
        frameRate: FrameRate
    ) async throws {
        let provider = MediaTranscodeFrameProvider(
            mediaID: UUID(),
            sourceURL: sourceURL,
            frameRate: frameRate,
            frameCount: 1,
            outputResolution: resolution
        )
        do {
            try await provider.provideFrame(
                index: 0,
                into: try makePixelBuffer(resolution: resolution)
            )
            XCTFail("expected typed media source failure")
        } catch {
            XCTAssertEqual(error as? MediaTranscodeError, expectedError)
        }
    }

    private func assertNoPublishedOutput(
        at destinationURL: URL,
        in outputDirectory: URL,
        file: StaticString,
        line: UInt
    ) throws {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destinationURL.path),
            file: file,
            line: line
        )
        let partials = try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".ajar-partial") }
        XCTAssertTrue(
            partials.isEmpty,
            "unexpected partial files: \(partials)",
            file: file,
            line: line
        )
    }

    private func assertPlayableProxy(
        at destinationURL: URL,
        frameCount: Int64,
        resolution: PixelDimensions,
        directory: URL
    ) async throws {
        let proxyAsset = AVURLAsset(url: destinationURL)
        let isPlayable = try await proxyAsset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
        let proxyTracks = try await proxyAsset.loadTracks(withMediaType: .video)
        let proxyTrack = try XCTUnwrap(proxyTracks.first)
        let formatDescriptions = try await proxyTrack.load(.formatDescriptions)
        let formatDescription = try XCTUnwrap(formatDescriptions.first)
        XCTAssertEqual(
            CMFormatDescriptionGetMediaSubType(formatDescription),
            kCMVideoCodecType_AppleProRes422Proxy
        )
        let decodedFrames = try await ExportMovieDecoder.decodeBGRA8Frames(from: destinationURL)
        XCTAssertEqual(decodedFrames.count, Int(frameCount))
        XCTAssertTrue(
            decodedFrames.allSatisfy {
                $0.width == resolution.width && $0.height == resolution.height
            }
        )
        let partials = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".ajar-partial") }
        XCTAssertTrue(partials.isEmpty)
    }

    private static func makeProductionSession(
        jobID: UUID,
        request: ProxyGenerationRequest,
        onProgress: @escaping @Sendable (ExportProgress) -> Void
    ) -> ProxyGenerationSession {
        let mediaProvider = MediaTranscodeFrameProvider(
            mediaID: request.mediaID,
            sourceURL: request.sourceURL,
            frameRate: request.frameRate,
            frameCount: request.frameCount,
            outputResolution: request.resolution
        )
        let adapter = ClosureProxySourceFrameProvider { index, buffer in
            try await mediaProvider.provideFrame(index: index, into: buffer)
        }
        return ProxyGenerationSession(
            id: jobID,
            request: request,
            frameProvider: adapter,
            onFrameProgress: onProgress
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-media-transcode-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makePixelBuffer(resolution: PixelDimensions) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            resolution.width,
            resolution.height,
            kCVPixelFormatType_64ARGB,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw MediaTranscodeProviderTestError.pixelBufferCreationFailed(status)
        }
        return pixelBuffer
    }

    private func zero(_ pixelBuffer: CVPixelBuffer) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw MediaTranscodeProviderTestError.pixelBufferLockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw MediaTranscodeProviderTestError.missingBaseAddress
        }
        memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
    }

    private func containsNonzeroBytes(_ pixelBuffer: CVPixelBuffer) throws -> Bool {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw MediaTranscodeProviderTestError.pixelBufferLockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw MediaTranscodeProviderTestError.missingBaseAddress
        }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        return (0..<CVPixelBufferGetDataSize(pixelBuffer)).contains { bytes[$0] != 0 }
    }

    private func waitForTerminalState(
        queue: ProxyGenerationQueue,
        jobID: UUID,
        timeout: TimeInterval = 60
    ) async throws -> ExportJobState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = await queue.state(for: jobID) {
                switch state {
                case .done, .failed, .cancelled:
                    return state
                case .pending, .running, .pausedWillRestart:
                    break
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw MediaTranscodeProviderTestError.proxyJobTimedOut(jobID)
    }
}

private enum MediaTranscodeProviderTestError: Error {
    case pixelBufferCreationFailed(CVReturn)
    case pixelBufferLockFailed(CVReturn)
    case missingBaseAddress
    case proxyJobTimedOut(UUID)
}
