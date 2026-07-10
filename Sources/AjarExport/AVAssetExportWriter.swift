// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
import AVFoundation
import AjarAudio
import CoreMedia
import CoreVideo
import Foundation

// swiftlint:enable sorted_imports

private struct ExportVideoWriterComponents {
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let pixelBufferPool: CVPixelBufferPool
}

final class AVAssetExportWriter: ExportWriting, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let videoPixelBufferPool: CVPixelBufferPool
    private let settings: ExportSettings
    private let outputURL: URL
    private let audioSampleBufferFactory: AudioSampleBufferFactory?
    private let operationQueue = DispatchQueue(label: "org.editorajar.export-writer")

    init(outputURL: URL, settings: ExportSettings) throws {
        self.outputURL = outputURL
        self.settings = settings
        let configuredWriter: AVAssetWriter
        do {
            configuredWriter = try AVAssetWriter(
                outputURL: outputURL,
                fileType: AssetWriterSettings.fileType(for: settings.container)
            )
        } catch {
            let mapped = ExportErrorMapper.map(error, destinationURL: outputURL)
            if case .diskFull = mapped {
                throw mapped
            }
            throw ExportError.writerCreationFailed(String(describing: error))
        }
        writer = configuredWriter

        let videoComponents = try Self.addVideoInput(
            to: configuredWriter,
            settings: settings.video
        )
        videoInput = videoComponents.input
        videoAdaptor = videoComponents.adaptor
        videoPixelBufferPool = videoComponents.pixelBufferPool
        let audioComponents = try Self.addAudioInput(
            to: configuredWriter,
            settings: settings.audio
        )
        audioInput = audioComponents.input
        audioSampleBufferFactory = audioComponents.sampleBufferFactory
    }

    private static func addVideoInput(
        to writer: AVAssetWriter,
        settings: ExportVideoSettings
    ) throws -> ExportVideoWriterComponents {
        let output = AssetWriterSettings.videoOutput(for: settings)
        guard writer.canApply(outputSettings: output, forMediaType: .video) else {
            if settings.codec.requiresHardwareEncoder {
                throw ExportError.encoderRefused(
                    codec: settings.codec,
                    reason: "AVAssetWriter cannot apply the configured hardware settings"
                )
            }
            throw ExportError.inputConfigurationFailed(
                .video,
                "AVAssetWriter cannot apply the configured output settings"
            )
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: output)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: nil
        )
        let pixelBufferPool = try makePixelBufferPool(settings: settings)
        guard writer.canAdd(input) else {
            if settings.codec.requiresHardwareEncoder {
                throw ExportError.encoderRefused(
                    codec: settings.codec,
                    reason: "AVAssetWriter cannot add the configured hardware video input"
                )
            }
            throw ExportError.inputConfigurationFailed(
                .video,
                "AVAssetWriter cannot add the configured input"
            )
        }
        writer.add(input)
        return ExportVideoWriterComponents(
            input: input,
            adaptor: adaptor,
            pixelBufferPool: pixelBufferPool
        )
    }

    private static func makePixelBufferPool(
        settings: ExportVideoSettings
    ) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            nil,
            nil,
            AssetWriterSettings.videoPixelBufferAttributes(for: settings) as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw ExportError.pixelBufferPoolCreationFailed(status)
        }
        return pool
    }

    private static func addAudioInput(
        to writer: AVAssetWriter,
        settings: ExportAudioSettings?
    ) throws -> (input: AVAssetWriterInput?, sampleBufferFactory: AudioSampleBufferFactory?) {
        guard let settings else {
            return (nil, nil)
        }
        let output = AssetWriterSettings.audioOutput(for: settings)
        guard writer.canApply(outputSettings: output, forMediaType: .audio) else {
            throw ExportError.inputConfigurationFailed(
                .audio,
                "AVAssetWriter cannot apply the configured output settings"
            )
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: output)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw ExportError.inputConfigurationFailed(
                .audio,
                "AVAssetWriter cannot add the configured input"
            )
        }
        writer.add(input)
        return (
            input,
            try AudioSampleBufferFactory(
                sampleRate: settings.sampleRate,
                channelCount: settings.channelCount
            )
        )
    }

    func start() throws {
        try operationQueue.sync {
            guard writer.startWriting() else {
                throw mappedWriterFailure(starting: true)
            }
            writer.startSession(atSourceTime: .zero)
        }
    }

    func makeVideoPixelBuffer() throws -> CVPixelBuffer {
        try operationQueue.sync {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(
                nil,
                videoPixelBufferPool,
                &buffer
            )
            guard status == kCVReturnSuccess, let buffer else {
                throw ExportError.pixelBufferCreationFailed(status)
            }
            return buffer
        }
    }

    func appendVideoIfReady(
        _ pixelBuffer: CVPixelBuffer,
        at time: CMTime
    ) throws -> Bool {
        try operationQueue.sync {
            guard try canAppend(to: videoInput) else {
                return false
            }
            guard videoAdaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw mappedAppendFailure(kind: .video)
            }
            return true
        }
    }

    func appendAudioIfReady(
        _ buffer: RenderedAudioBuffer,
        frames: Range<Int>
    ) throws -> Bool {
        try operationQueue.sync {
            guard let audioInput, let audioSampleBufferFactory else {
                throw ExportError.inputConfigurationFailed(.audio, "audio input is absent")
            }
            guard try canAppend(to: audioInput) else {
                return false
            }
            let sampleBuffer = try audioSampleBufferFactory.makeSampleBuffer(
                from: buffer,
                frames: frames
            )
            guard audioInput.append(sampleBuffer) else {
                throw mappedAppendFailure(kind: .audio)
            }
            return true
        }
    }

    func checkForFailure() throws {
        try operationQueue.sync {
            if writer.status == .failed {
                throw mappedWriterFailure(starting: false)
            }
        }
    }

    func finish(at endTime: CMTime) async throws {
        await withCheckedContinuation { continuation in
            operationQueue.async {
                guard self.writer.status == .writing else {
                    continuation.resume()
                    return
                }
                self.writer.endSession(atSourceTime: endTime)
                self.videoInput.markAsFinished()
                self.audioInput?.markAsFinished()
                self.writer.finishWriting {
                    continuation.resume()
                }
            }
        }
        try operationQueue.sync {
            guard writer.status == .completed else {
                throw mappedWriterFailure(starting: false)
            }
        }
    }

    func cancel() {
        operationQueue.sync {
            if writer.status == .writing || writer.status == .unknown {
                writer.cancelWriting()
            }
        }
    }

    private func canAppend(to input: AVAssetWriterInput) throws -> Bool {
        switch writer.status {
        case .writing:
            return input.isReadyForMoreMediaData
        case .failed:
            throw mappedWriterFailure(starting: false)
        case .cancelled:
            throw ExportError.writerFailed("asset writer cancelled before append")
        case .completed:
            throw ExportError.writerFailed("asset writer completed before append")
        case .unknown:
            return false
        @unknown default:
            throw ExportError.writerFailed("asset writer entered an unknown state")
        }
    }

    private func mappedAppendFailure(kind: ExportMediaKind) -> ExportError {
        if let error = writer.error {
            if Self.isEncoderRefusal(error as NSError) {
                return .encoderRefused(
                    codec: settings.video.codec,
                    reason: String(describing: error)
                )
            }
            let mapped = ExportErrorMapper.map(error, destinationURL: outputURL)
            if case .diskFull = mapped {
                return mapped
            }
            return .appendRefused(
                kind,
                reason: String(describing: error),
                underlyingError: error as NSError
            )
        }
        return .appendRefused(
            kind,
            reason: "AVAssetWriter returned false without an error",
            underlyingError: nil
        )
    }

    private func mappedWriterFailure(starting: Bool) -> ExportError {
        let reason = writer.error.map(String.init(describing:)) ?? "unknown writer failure"
        if let error = writer.error {
            if Self.isEncoderRefusal(error as NSError) {
                return .encoderRefused(codec: settings.video.codec, reason: reason)
            }
            let mapped = ExportErrorMapper.map(error, destinationURL: outputURL)
            if case .diskFull = mapped {
                return mapped
            }
            return starting ? .writerStartFailed(reason) : .writerFailed(reason)
        }
        if starting, settings.video.codec.requiresHardwareEncoder {
            return .encoderRefused(codec: settings.video.codec, reason: reason)
        }
        return starting ? .writerStartFailed(reason) : .writerFailed(reason)
    }

    static func isEncoderRefusal(_ error: NSError) -> Bool {
        let refusalCodes = [
            AVError.Code.encoderNotFound.rawValue,
            AVError.Code.encoderTemporarilyUnavailable.rawValue
        ]
        if error.domain == AVFoundationErrorDomain, refusalCodes.contains(error.code) {
            return true
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return isEncoderRefusal(underlying)
    }
}
