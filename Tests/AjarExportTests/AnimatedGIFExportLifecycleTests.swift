// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreVideo
import Darwin
import Foundation
import XCTest

@testable import AjarExport

final class AnimatedGIFExportLifecycleTests: XCTestCase {
    func testFREXP006CancellationBeforeRunDoesNotCreateOutput() async throws {
        let fixture = try AnimatedGIFLifecycleFixture()
        let writer = LifecycleGIFWriter()
        let session = makeSession(fixture: fixture, writer: writer)

        session.cancel()

        await assertCancelled(session)
        XCTAssertEqual(session.state, .cancelled)
        XCTAssertFalse(writer.wasCreated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURL.path))
        try fixture.assertNoPartialFiles()
    }

    func testFREXP006CancellationAfterRenderSkipsAppendAndPreservesDestination() async throws {
        let fixture = try AnimatedGIFLifecycleFixture()
        let original = Data("existing GIF".utf8)
        try original.write(to: fixture.destinationURL)
        let box = AnimatedGIFLifecycleSessionBox()
        let provider = LifecycleGIFProvider { box.value?.cancel() }
        let writer = LifecycleGIFWriter()
        let session = makeSession(fixture: fixture, provider: provider, writer: writer)
        box.value = session

        await assertCancelled(session)

        XCTAssertEqual(provider.renderCount, 1)
        XCTAssertEqual(writer.appendCount, 0)
        XCTAssertFalse(writer.didFinalize)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), original)
        try fixture.assertNoPartialFiles()
    }

    func testFREXP006CancellationAfterAppendSkipsFinalizeAndPreservesDestination() async throws {
        let fixture = try AnimatedGIFLifecycleFixture()
        let original = Data("existing GIF".utf8)
        try original.write(to: fixture.destinationURL)
        let box = AnimatedGIFLifecycleSessionBox()
        let writer = LifecycleGIFWriter { box.value?.cancel() }
        let session = makeSession(fixture: fixture, writer: writer)
        box.value = session

        await assertCancelled(session)

        XCTAssertEqual(writer.appendCount, 1)
        XCTAssertFalse(writer.didFinalize)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), original)
        try fixture.assertNoPartialFiles()
    }

    func testFREXP006SessionIsOneShotAfterSuccessfulPublication() async throws {
        let fixture = try AnimatedGIFLifecycleFixture()
        let writer = LifecycleGIFWriter()
        let session = makeSession(fixture: fixture, writer: writer)

        _ = try await session.run()

        do {
            _ = try await session.run()
            XCTFail("expected completed session to reject a second run")
        } catch let error as ExportError {
            XCTAssertEqual(error, .invalidSessionState(.completed))
        }
        XCTAssertEqual(session.state, .completed)
        try fixture.assertNoPartialFiles()
    }

    func testNFRSTAB002GIFCleanupFailureRetainsFrameWriteRootCause() async throws {
        let fixture = try AnimatedGIFLifecycleFixture()
        let writer = LifecycleGIFWriter()
        writer.appendError = LifecycleGIFWriterError.refusedAppend
        writer.onCreate = { temporaryURL in
            var values = URLResourceValues()
            values.isUserImmutable = true
            var mutableURL = temporaryURL
            try? mutableURL.setResourceValues(values)
        }
        let session = makeSession(fixture: fixture, writer: writer)

        do {
            _ = try await session.run()
            XCTFail("expected write or cleanup failure")
        } catch let error as ExportError {
            switch error {
            case .cleanupFailed(let rootCause, let temporaryURL, let reason):
                guard case .animatedGIFFrameWriteFailed(
                    let index,
                    let rootReason
                ) = rootCause else {
                    return XCTFail("unexpected root cause: \(rootCause)")
                }
                XCTAssertEqual(index, 0)
                XCTAssertTrue(rootReason.contains("refused append"))
                XCTAssertFalse(reason.isEmpty)
                var mutableURL = temporaryURL
                var values = URLResourceValues()
                values.isUserImmutable = false
                try? mutableURL.setResourceValues(values)
                try? FileManager.default.removeItem(at: temporaryURL)
            case .animatedGIFFrameWriteFailed(let index, let reason):
                // Some file systems ignore the user-immutable bit; the root failure still surfaces.
                XCTAssertEqual(index, 0)
                XCTAssertTrue(reason.contains("refused append"))
            default:
                XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(session.state, .failed)
    }

    func testNFRSTAB002GIFPreservesDiskFullAcrossEveryWriterBoundary() async throws {
        for stage in LifecycleGIFDiskFullStage.allCases {
            let fixture = try AnimatedGIFLifecycleFixture()
            let original = Data("existing GIF".utf8)
            try original.write(to: fixture.destinationURL)
            let diskFull = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            let writer = LifecycleGIFWriter()
            let session: AnimatedGIFExportSession

            switch stage {
            case .creation:
                session = AnimatedGIFExportSession(
                    request: fixture.request,
                    frameProvider: LifecycleGIFProvider(),
                    writerFactory: { _, _, _ in throw diskFull }
                )
            case .append:
                writer.appendError = diskFull
                session = makeSession(fixture: fixture, writer: writer)
            case .finalize:
                writer.finalizeError = diskFull
                session = makeSession(fixture: fixture, writer: writer)
            }

            do {
                _ = try await session.run()
                XCTFail("expected disk-full failure at \(stage)")
            } catch let error as ExportError {
                XCTAssertEqual(error, .diskFull(fixture.destinationURL))
            }
            XCTAssertEqual(session.state, .failed)
            XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), original)
            try fixture.assertNoPartialFiles()
        }
    }

    private func makeSession(
        fixture: AnimatedGIFLifecycleFixture,
        provider: LifecycleGIFProvider = LifecycleGIFProvider(),
        writer: LifecycleGIFWriter
    ) -> AnimatedGIFExportSession {
        AnimatedGIFExportSession(
            request: fixture.request,
            frameProvider: provider,
            writerFactory: { temporaryURL, _, _ in
                writer.wasCreated = true
                try Data("partial GIF".utf8).write(to: temporaryURL)
                writer.onCreate(temporaryURL)
                return writer
            }
        )
    }

    private func assertCancelled(
        _ session: AnimatedGIFExportSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await session.run()
            XCTFail("expected cancellation", file: file, line: line)
        } catch let error as ExportError {
            XCTAssertEqual(error, .cancelled, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}

private final class AnimatedGIFLifecycleFixture {
    let directoryURL: URL
    let destinationURL: URL
    let request: AnimatedGIFExportRequest

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-gif-lifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        destinationURL = directoryURL.appendingPathComponent("result.gif")
        let frameRate = try FrameRate(frames: 30)
        let duration = try frameRate.duration(ofFrames: 1)
        let sequenceDuration = try frameRate.duration(ofFrames: 2)
        let sequenceRange = try TimeRange(start: .zero, duration: sequenceDuration)
        let sequence = Sequence(
            id: UUID(),
            name: "GIF lifecycle",
            videoTracks: [Track(id: UUID(), kind: .video, items: [.gap(sequenceRange)])],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 16, height: 16),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [],
            sequences: [sequence]
        )
        request = try AnimatedGIFExportRequest(
            project: project,
            sequenceID: sequence.id,
            range: TimeRange(start: .zero, duration: duration),
            destinationURL: destinationURL,
            settings: AnimatedGIFExportSettings(
                resolution: PixelDimensions(width: 9, height: 7),
                frameRate: frameRate
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

private final class LifecycleGIFProvider: ExportVideoFrameProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let onRender: @Sendable () -> Void
    private var renderCountValue = 0

    var renderCount: Int {
        lock.withLock { renderCountValue }
    }

    init(onRender: @escaping @Sendable () -> Void = {}) {
        self.onRender = onRender
    }

    func renderFrame(at _: RationalTime, into _: CVPixelBuffer) async throws {
        lock.withLock {
            renderCountValue += 1
        }
        onRender()
    }
}

private final class LifecycleGIFWriter: AnimatedGIFWriting {
    var wasCreated = false
    var appendError: Error?
    var finalizeError: Error?
    var onCreate: (URL) -> Void = { _ in }
    private(set) var appendCount = 0
    private(set) var didFinalize = false
    private let onAppend: () -> Void

    init(onAppend: @escaping () -> Void = {}) {
        self.onAppend = onAppend
    }

    func append(
        pixelBuffer _: CVPixelBuffer,
        sourceColorSpace _: ExportColorSpace,
        colorConversionPolicy _: AnimatedGIFColorConversionPolicy,
        delayCentiseconds _: Int
    ) throws {
        appendCount += 1
        onAppend()
        if let appendError {
            throw appendError
        }
    }

    func finalize() throws {
        if let finalizeError {
            throw finalizeError
        }
        didFinalize = true
    }
}

private enum LifecycleGIFWriterError: Error, CustomStringConvertible {
    case refusedAppend

    var description: String {
        "refused append"
    }
}

private enum LifecycleGIFDiskFullStage: String, CaseIterable {
    case creation
    case append
    case finalize
}

private final class AnimatedGIFLifecycleSessionBox: @unchecked Sendable {
    weak var value: AnimatedGIFExportSession?
}
