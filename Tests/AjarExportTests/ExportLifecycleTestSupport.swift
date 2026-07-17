// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@testable import AjarExport

final class LifecycleFrameProvider: ExportVideoFrameProvider {
    private(set) var renderedFrameCount = 0

    func renderFrame(
        at _: RationalTime,
        into _: CVPixelBuffer
    ) async throws {
        renderedFrameCount += 1
    }
}

final class LifecycleWriter: ExportWriting {
    var outputURL: URL
    var startError: ExportError?
    var appendVideoError: ExportError?
    var finishError: ExportError?
    var onStart: (() -> Void)?
    var onAppendVideo: (() -> Void)?
    var onFinishEntered: (() -> Void)?
    var suspendFinishUntilCancelled = false
    var audioReady = false
    /// Number of `appendVideoIfReady` polls that return `false` before accepting (pending path).
    var videoNotReadyPollsRemaining = 0
    private(set) var didStart = false
    private(set) var didFinish = false
    private(set) var appendedVideoCount = 0
    private(set) var appendedVideoPresentationTimes: [CMTime] = []
    private(set) var appendedAudioRanges: [Range<Int>] = []
    private(set) var maximumAudioBufferFrameCount = 0
    private(set) var finishedAt: CMTime?
    /// True if any video append arrived after `finish(at:)` began.
    private(set) var appendedVideoAfterFinish = false
    private let finishLock = NSLock()
    private var didCancelValue = false
    private var finishContinuation: CheckedContinuation<Void, Never>?

    var didCancel: Bool {
        finishLock.lock()
        defer { finishLock.unlock() }
        return didCancelValue
    }

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() throws {
        didStart = true
        try Data("partial".utf8).write(to: outputURL)
        onStart?()
        if let startError {
            throw startError
        }
    }

    func makeVideoPixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw ExportError.pixelBufferCreationFailed(status)
        }
        return buffer
    }

    func appendVideoIfReady(
        _ pixelBuffer: CVPixelBuffer,
        at time: CMTime
    ) throws -> Bool {
        _ = pixelBuffer
        if let appendVideoError {
            throw appendVideoError
        }
        if videoNotReadyPollsRemaining > 0 {
            videoNotReadyPollsRemaining -= 1
            return false
        }
        if didFinish || finishedAt != nil {
            appendedVideoAfterFinish = true
        }
        appendedVideoCount += 1
        appendedVideoPresentationTimes.append(time)
        onAppendVideo?()
        return true
    }

    func appendAudioIfReady(
        _ buffer: RenderedAudioBuffer,
        frames: Range<Int>,
        presentationFrameOffset: Int
    ) throws -> Bool {
        _ = buffer
        guard audioReady else {
            return false
        }
        maximumAudioBufferFrameCount = max(maximumAudioBufferFrameCount, buffer.frameCount)
        let absoluteStart = presentationFrameOffset + frames.lowerBound
        let absoluteEnd = presentationFrameOffset + frames.upperBound
        appendedAudioRanges.append(absoluteStart..<absoluteEnd)
        return true
    }

    func checkForFailure() throws {}

    func finish(at endTime: CMTime) async throws {
        finishedAt = endTime
        if suspendFinishUntilCancelled {
            onFinishEntered?()
            await withCheckedContinuation { continuation in
                finishLock.lock()
                if didCancelValue {
                    finishLock.unlock()
                    continuation.resume()
                } else {
                    finishContinuation = continuation
                    finishLock.unlock()
                }
            }
            if didCancel {
                throw ExportError.cancelled
            }
        }
        if let finishError {
            throw finishError
        }
        didFinish = true
        try Data("complete".utf8).write(to: outputURL)
    }

    func cancel() {
        finishLock.lock()
        didCancelValue = true
        let continuation = finishContinuation
        finishContinuation = nil
        finishLock.unlock()
        continuation?.resume()
    }
}

final class LifecycleFixture {
    let directoryURL: URL
    let destinationURL: URL
    let request: ExportRequest

    init(
        frameCount: Int64,
        includeAudio: Bool = false,
        frameRate: FrameRate? = nil,
        duration: RationalTime? = nil,
        audioSampleRate: Int = 48_000,
        audioTrackCount: Int = 0,
        destinationCollisionPolicy: ExportDestinationCollisionPolicy = .replaceExisting
    ) throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-export-lifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        destinationURL = directoryURL.appendingPathComponent("result.mp4")
        let resolvedFrameRate = try frameRate ?? FrameRate(frames: 30)
        let resolvedDuration = try duration ?? resolvedFrameRate.duration(ofFrames: frameCount)
        request = try Self.makeRequest(
            destinationURL: destinationURL,
            frameRate: resolvedFrameRate,
            duration: resolvedDuration,
            includeAudio: includeAudio,
            audioSampleRate: audioSampleRate,
            audioTrackCount: audioTrackCount,
            destinationCollisionPolicy: destinationCollisionPolicy
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func session(
        frameProvider: any ExportVideoFrameProvider,
        audioSourceProvider: (any AudioSourceProvider)? = nil,
        audioSourceProviderFactory: ExportAudioSourceProviderFactory? = nil,
        beforePublish: (() -> Void)? = nil,
        onFrameProgress: (@Sendable (ExportProgress) -> Void)? = nil,
        writerFactory: @escaping ExportWriterFactory
    ) -> ExportSession {
        ExportSession(
            request: request,
            frameProvider: frameProvider,
            audioSourceProvider: audioSourceProvider,
            audioSourceProviderFactory: audioSourceProviderFactory,
            writerFactory: { temporaryURL, settings in
                let writer = try writerFactory(temporaryURL, settings)
                if let lifecycleWriter = writer as? LifecycleWriter {
                    lifecycleWriter.outputURL = temporaryURL
                }
                return writer
            },
            beforePublish: beforePublish,
            onFrameProgress: onFrameProgress
        )
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

    // swiftlint:disable:next function_body_length function_parameter_count
    private static func makeRequest(
        destinationURL: URL,
        frameRate: FrameRate,
        duration: RationalTime,
        includeAudio: Bool,
        audioSampleRate: Int,
        audioTrackCount: Int,
        destinationCollisionPolicy: ExportDestinationCollisionPolicy
    ) throws -> ExportRequest {
        let range = try TimeRange(start: .zero, duration: duration)
        let sequenceID = UUID()
        let mediaID = UUID()
        let audioTracks = (0..<audioTrackCount).map { index in
            Track(
                id: UUID(),
                kind: .audio,
                items: [
                    .clip(
                        Clip(
                            id: UUID(),
                            source: .media(id: mediaID),
                            sourceRange: range,
                            timelineRange: range,
                            kind: .audio,
                            name: "Cancellation probe \(index)"
                        )
                    )
                ]
            )
        }
        let sequence = Sequence(
            id: sequenceID,
            name: "Lifecycle",
            videoTracks: [Track(id: UUID(), kind: .video, items: [.gap(range)])],
            audioTracks: audioTracks,
            markers: [],
            timebase: frameRate
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 64, height: 64),
                colorSpace: .rec709,
                audioSampleRate: audioSampleRate
            ),
            mediaPool: audioTrackCount > 0
                ? [
                    MediaRef(
                        id: mediaID,
                        sourceURL: nil,
                        contentHash: nil,
                        metadata: MediaMetadata(
                            codecID: "pcm_f32le",
                            pixelDimensions: nil,
                            frameRate: nil,
                            duration: duration,
                            colorSpace: .unspecified,
                            audioChannelLayout: AudioChannelLayout(channelCount: 1),
                            isVariableFrameRate: false,
                            conformedFrameRate: nil
                        )
                    )
                ]
                : [],
            sequences: [sequence]
        )
        let audioSettings =
            includeAudio
            ? try ExportAudioSettings(
                codec: .aac,
                sampleRate: audioSampleRate,
                channelCount: 2,
                bitRate: 64_000
            )
            : nil
        let settings = try ExportSettings(
            container: .mp4,
            video: ExportVideoSettings(
                codec: .h264,
                resolution: PixelDimensions(width: 64, height: 64),
                frameRate: frameRate,
                averageBitRate: 500_000,
                colorSpace: .rec709
            ),
            audio: audioSettings
        )
        return try ExportRequest(
            project: project,
            sequenceID: sequenceID,
            range: range,
            destinationURL: destinationURL,
            settings: settings,
            destinationCollisionPolicy: destinationCollisionPolicy
        )
    }
}

final class WeakSessionBox {
    weak var value: ExportSession?
}

final class MixStartSignallingProvider: AudioSourceProvider, @unchecked Sendable {
    private let source: AudioSourceBuffer
    private let started: XCTestExpectation
    private let lock = NSLock()
    private var didSignal = false

    init(source: AudioSourceBuffer, started: XCTestExpectation) {
        self.source = source
        self.started = started
    }

    func audioSource(for _: UUID) throws -> AudioSourceBuffer {
        lock.lock()
        let shouldSignal = !didSignal
        didSignal = true
        lock.unlock()
        if shouldSignal {
            started.fulfill()
        }
        return source
    }
}
