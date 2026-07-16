// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import XCTest

@testable import AjarExport

final class AnimatedGIFExportTests: XCTestCase {
    func testFREXP006SettingsAcceptOddRasterAndRejectUnrepresentableRate() throws {
        let invalidRate = try FrameRate(frames: 101)
        let valid = try AnimatedGIFExportSettings(
            resolution: PixelDimensions(width: 63, height: 37),
            frameRate: FrameRate(frames: 100),
            sourceColorSpace: .rec709,
            loopPolicy: .forever
        )
        XCTAssertEqual(valid.resolution, PixelDimensions(width: 63, height: 37))

        XCTAssertThrowsError(
            try AnimatedGIFExportSettings(
                resolution: PixelDimensions(width: 63, height: 37),
                frameRate: invalidRate
            )
        ) { error in
            XCTAssertEqual(
                error as? AnimatedGIFExportSettingsValidationError,
                .frameRateOutOfRange(invalidRate)
            )
        }
        XCTAssertThrowsError(
            try AnimatedGIFExportSettings(
                resolution: PixelDimensions(width: 0, height: 37),
                frameRate: FrameRate(frames: 30)
            )
        ) { error in
            XCTAssertEqual(
                error as? AnimatedGIFExportSettingsValidationError,
                .resolutionOutOfRange(PixelDimensions(width: 0, height: 37))
            )
        }
    }

    func testFREXP006RequestUsesExactRangeTimesAndCumulativeCentisecondTiming() throws {
        let fixture = try AnimatedGIFFixture(
            frameCount: 3,
            rangeStartFrame: 5,
            resolution: PixelDimensions(width: 63, height: 37)
        )
        let request = fixture.request

        XCTAssertEqual(try request.frameCount(), 3)
        XCTAssertEqual(
            try (0..<3).map { try request.timelineTime(forFrame: Int64($0)) },
            try (5..<8).map { try RationalTime.atFrame(Int64($0), frameRate: fixture.frameRate) }
        )
        XCTAssertEqual(
            try (0..<3).map { try request.delayCentiseconds(forFrame: Int64($0)) },
            [3, 4, 3]
        )
    }

    func testFREXP006FractionalRateTimingDoesNotAccumulateDrift() throws {
        let rate = try FrameRate(frames: 30_000, per: 1_001)
        let fixture = try AnimatedGIFFixture(frameCount: 3, frameRate: rate)
        XCTAssertEqual(
            try (0..<3).map { try fixture.request.delayCentiseconds(forFrame: Int64($0)) },
            [3, 4, 3]
        )
        let total = try (0..<3).reduce(0) { partial, index in
            partial + (try fixture.request.delayCentiseconds(forFrame: Int64(index)))
        }
        XCTAssertEqual(total, 10)
    }

    func testFREXP006ImageIOWriterProducesOrderedOddRasterFramesAndLoopMetadata() throws {
        let directory = try makeTemporaryDirectory(prefix: "ajar-gif-writer")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ordered.gif")
        let writer = try ImageIOAnimatedGIFWriter(
            url: url,
            expectedFrameCount: 3,
            loopPolicy: .forever
        )
        let colors: [TestRGB] = [
            TestRGB(b: 0, g: 0, r: 255),
            TestRGB(b: 0, g: 255, r: 0),
            TestRGB(b: 255, g: 0, r: 0)
        ]
        let delays = [3, 4, 3]
        for index in colors.indices {
            try writer.append(
                pixelBuffer: makeSolidBGRABuffer(
                    width: 63,
                    height: 37,
                    color: colors[index]
                ),
                sourceColorSpace: .rec709,
                colorConversionPolicy: .convertToSRGB,
                delayCentiseconds: delays[index]
            )
        }
        try writer.finalize()

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        let global = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = global?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual((gif?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 0)

        for index in 0..<3 {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(image.width, 63)
            XCTAssertEqual(image.height, 37)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any]
            let frameGIF = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = try XCTUnwrap(
                (frameGIF?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                    ?? (frameGIF?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            )
            XCTAssertEqual(delay, Double(delays[index]) / 100, accuracy: 0.000_1)
            let decoded = try decodeTopLeftBGRA(image)
            XCTAssertLessThanOrEqual(abs(Int(decoded.b) - Int(colors[index].b)), 12)
            XCTAssertLessThanOrEqual(abs(Int(decoded.g) - Int(colors[index].g)), 12)
            XCTAssertLessThanOrEqual(abs(Int(decoded.r) - Int(colors[index].r)), 12)
            XCTAssertEqual(decoded.a, 255)
        }
    }

    func testFREXP006PlayOnceDecodesAsOneIteration() throws {
        let directory = try makeTemporaryDirectory(prefix: "ajar-gif-play-once")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("once.gif")
        let writer = try ImageIOAnimatedGIFWriter(
            url: url,
            expectedFrameCount: 2,
            loopPolicy: .playOnce
        )
        for color in [
            TestRGB(b: 0, g: 0, r: 255),
            TestRGB(b: 255, g: 0, r: 0)
        ] {
            try writer.append(
                pixelBuffer: makeSolidBGRABuffer(width: 3, height: 5, color: color),
                sourceColorSpace: .rec709,
                colorConversionPolicy: .convertToSRGB,
                delayCentiseconds: 10
            )
        }
        try writer.finalize()

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let global = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = global?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual((gif?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 1)
    }

    func testFREXP006SessionPublishesAtomicallyWithProgressAndOriginalAudit() async throws {
        let fixture = try AnimatedGIFFixture(frameCount: 3)
        try Data("old destination".utf8).write(to: fixture.destinationURL)
        let provider = RecordingAnimatedGIFFrameProvider(mediaID: UUID())
        let progress = AnimatedGIFProgressCollector()
        let session = AnimatedGIFExportSession(
            request: fixture.request,
            frameProvider: provider,
            onFrameProgress: { progress.append($0) }
        )

        let result = try await session.run()

        XCTAssertEqual(result.destinationURL, fixture.destinationURL)
        XCTAssertEqual(result.videoFrameCount, 3)
        XCTAssertEqual(result.audioFrameCount, 0)
        XCTAssertEqual(session.state, .completed)
        XCTAssertEqual(session.progress, ExportProgress(framesWritten: 3, totalFrames: 3))
        XCTAssertEqual(provider.times, try (0..<3).map {
            try fixture.request.timelineTime(forFrame: Int64($0))
        })
        XCTAssertEqual(progress.samples().map(\.framesWritten), [0, 1, 2, 3])
        XCTAssertTrue(session.sourceSelectionRecords.allSatisfy { $0.tier == .original })
        XCTAssertEqual(session.sourceSelectionRecords.map(\.frameIndex), [0, 1, 2])
        try fixture.assertNoPartialFiles()

        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(fixture.destinationURL as CFURL, nil)
        )
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
    }

    func testFREXP006CancellationAfterFinalizePreservesExistingDestination() async throws {
        let fixture = try AnimatedGIFFixture(frameCount: 2)
        let old = Data("keep me".utf8)
        try old.write(to: fixture.destinationURL)
        let sessionBox = AnimatedGIFSessionBox()
        let session = AnimatedGIFExportSession(
            request: fixture.request,
            frameProvider: RecordingAnimatedGIFFrameProvider(mediaID: UUID()),
            writerFactory: { url, frameCount, loopPolicy in
                try ImageIOAnimatedGIFWriter(
                    url: url,
                    expectedFrameCount: frameCount,
                    loopPolicy: loopPolicy
                )
            },
            beforePublish: { sessionBox.value?.cancel() }
        )
        sessionBox.value = session

        do {
            _ = try await session.run()
            XCTFail("expected cancellation")
        } catch let error as ExportError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertEqual(session.state, .cancelled)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), old)
        try fixture.assertNoPartialFiles()
    }

    func testFREXP006FinalizeFailureIsTypedAndRemovesPartial() async throws {
        let fixture = try AnimatedGIFFixture(frameCount: 2)
        let old = Data("preserve this destination".utf8)
        try old.write(to: fixture.destinationURL)
        let writer = FailingAnimatedGIFWriter(outputURL: fixture.destinationURL)
        writer.finalizeError = AnimatedGIFWriterError.finalizationFailed
        let session = AnimatedGIFExportSession(
            request: fixture.request,
            frameProvider: RecordingAnimatedGIFFrameProvider(mediaID: UUID()),
            writerFactory: { temporaryURL, _, _ in
                writer.outputURL = temporaryURL
                try Data("partial".utf8).write(to: temporaryURL)
                return writer
            }
        )

        do {
            _ = try await session.run()
            XCTFail("expected finalization failure")
        } catch let error as ExportError {
            guard case .animatedGIFFinalizeFailed(let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("finalization"))
        }
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), old)
        try fixture.assertNoPartialFiles()
    }
}

private final class AnimatedGIFFixture {
    let directoryURL: URL
    let destinationURL: URL
    let request: AnimatedGIFExportRequest
    let frameRate: FrameRate

    init(
        frameCount: Int64,
        rangeStartFrame: Int64 = 0,
        frameRate: FrameRate? = nil,
        resolution: PixelDimensions = PixelDimensions(width: 9, height: 7)
    ) throws {
        directoryURL = try makeTemporaryDirectory(prefix: "ajar-gif-session")
        destinationURL = directoryURL.appendingPathComponent("result.gif")
        let resolvedFrameRate = try frameRate ?? FrameRate(frames: 30)
        self.frameRate = resolvedFrameRate
        let start = try resolvedFrameRate.duration(ofFrames: rangeStartFrame)
        let duration = try resolvedFrameRate.duration(ofFrames: frameCount)
        let range = try TimeRange(start: start, duration: duration)
        let sequenceRange = try TimeRange(
            start: .zero,
            duration: resolvedFrameRate.duration(ofFrames: rangeStartFrame + frameCount + 1)
        )
        let sequence = Sequence(
            id: UUID(),
            name: "Animated GIF",
            videoTracks: [Track(id: UUID(), kind: .video, items: [.gap(sequenceRange)])],
            audioTracks: [],
            markers: [],
            timebase: resolvedFrameRate
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: resolvedFrameRate,
                resolution: PixelDimensions(width: 64, height: 64),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [],
            sequences: [sequence]
        )
        request = try AnimatedGIFExportRequest(
            project: project,
            sequenceID: sequence.id,
            range: range,
            destinationURL: destinationURL,
            settings: AnimatedGIFExportSettings(
                resolution: resolution,
                frameRate: resolvedFrameRate,
                sourceColorSpace: .rec709,
                loopPolicy: .forever
            )
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func assertNoPartialFiles(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        XCTAssertFalse(
            names.contains(where: { $0.contains("ajar-partial") }),
            file: file,
            line: line
        )
    }
}

private final class RecordingAnimatedGIFFrameProvider: ExportVideoFrameProvider,
    ExportGraphSourceAuditing, @unchecked Sendable {
    private let mediaID: UUID
    private let lock = NSLock()
    private var renderedTimes: [RationalTime] = []

    var times: [RationalTime] {
        lock.withLock { renderedTimes }
    }

    var lastRenderedExportSourceTiers: [(mediaID: UUID, tier: ExportMediaSourceTier)] {
        [(mediaID: mediaID, tier: .original)]
    }

    init(mediaID: UUID) {
        self.mediaID = mediaID
    }

    func renderFrame(at timelineTime: RationalTime, into pixelBuffer: CVPixelBuffer) async throws {
        let index = lock.withLock {
            let index = renderedTimes.count
            renderedTimes.append(timelineTime)
            return index
        }
        let colors: [TestRGB] = [
            TestRGB(b: 0, g: 0, r: 255),
            TestRGB(b: 0, g: 255, r: 0),
            TestRGB(b: 255, g: 0, r: 0)
        ]
        try fill(pixelBuffer: pixelBuffer, color: colors[index % colors.count])
    }
}

private final class AnimatedGIFProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExportProgress] = []

    func append(_ value: ExportProgress) {
        lock.withLock {
            values.append(value)
        }
    }

    func samples() -> [ExportProgress] {
        lock.withLock { values }
    }
}

private final class AnimatedGIFSessionBox: @unchecked Sendable {
    weak var value: AnimatedGIFExportSession?
}

private final class FailingAnimatedGIFWriter: AnimatedGIFWriting {
    var outputURL: URL
    var finalizeError: Error?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func append(
        pixelBuffer _: CVPixelBuffer,
        sourceColorSpace _: ExportColorSpace,
        colorConversionPolicy _: AnimatedGIFColorConversionPolicy,
        delayCentiseconds _: Int
    ) throws {}

    func finalize() throws {
        if let finalizeError {
            throw finalizeError
        }
    }
}

private struct TestRGB {
    let b: UInt8
    let g: UInt8
    let r: UInt8
}

private struct TestBGRA {
    let b: UInt8
    let g: UInt8
    let r: UInt8
    let a: UInt8
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "\(prefix)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeSolidBGRABuffer(
    width: Int,
    height: Int,
    color: TestRGB
) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        nil,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        throw ExportError.pixelBufferCreationFailed(status)
    }
    try fill(pixelBuffer: buffer, color: color)
    return buffer
}

private func fill(
    pixelBuffer: CVPixelBuffer,
    color: TestRGB
) throws {
    let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard status == kCVReturnSuccess else {
        throw ExportError.pixelBufferCreationFailed(status)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw ExportError.frameRenderFailed(frameIndex: 0, reason: "missing BGRA base address")
    }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<height {
        let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let offset = x * 4
            row[offset] = color.b
            row[offset + 1] = color.g
            row[offset + 2] = color.r
            row[offset + 3] = 255
        }
    }
}

private func decodeTopLeftBGRA(_ image: CGImage) throws -> TestBGRA {
    guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw ExportError.animatedGIFFrameWriteFailed(
            frameIndex: 0,
            reason: "sRGB is unavailable"
        )
    }
    var bytes = [UInt8](repeating: 0, count: 4)
    guard let context = CGContext(
        data: &bytes,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        throw ExportError.animatedGIFFrameWriteFailed(
            frameIndex: 0,
            reason: "could not make decode context"
        )
    }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return TestBGRA(b: bytes[0], g: bytes[1], r: bytes[2], a: bytes[3])
}
