// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import AVFoundation
import CoreMedia
import Foundation

/// Containers supported for audio-only export (FR-EXP-004).
public enum AudioOnlyContainer: String, Codable, CaseIterable, Equatable, Sendable {
    /// RIFF WAVE with interleaved Float32 PCM (bit-exact offline mix).
    case wav

    /// MPEG-4 audio (AAC).
    case m4a

    /// QuickTime movie with a single audio track (PCM or AAC).
    case mov
}

/// Typed settings for audio-only export.
public struct AudioOnlyExportSettings: Codable, Equatable, Sendable {
    /// File container.
    public let container: AudioOnlyContainer

    /// Codec (PCM for WAV; AAC or PCM for MOV; AAC for M4A).
    public let codec: ExportAudioCodec

    /// Sample rate in hertz (must match the project mix rate).
    public let sampleRate: Int

    /// Interleaved channel count.
    public let channelCount: Int

    /// AAC bit rate; absent for PCM.
    public let bitRate: Int?

    /// Creates and validates audio-only settings.
    public init(
        container: AudioOnlyContainer,
        codec: ExportAudioCodec,
        sampleRate: Int,
        channelCount: Int,
        bitRate: Int? = nil
    ) throws {
        self.container = container
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitRate = bitRate
        try validate()
    }

    /// Decodes and validates untrusted settings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            container: container.decode(AudioOnlyContainer.self, forKey: .container),
            codec: container.decode(ExportAudioCodec.self, forKey: .codec),
            sampleRate: container.decode(Int.self, forKey: .sampleRate),
            channelCount: container.decode(Int.self, forKey: .channelCount),
            bitRate: container.decodeIfPresent(Int.self, forKey: .bitRate)
        )
    }

    /// Validates codec/container compatibility via the shared audio rules.
    public func validate() throws {
        let nested = try ExportAudioSettings(
            codec: codec,
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitRate: bitRate
        )
        try nested.validate()

        switch (container, codec) {
        case (.wav, .linearPCM), (.m4a, .aac), (.mov, .aac), (.mov, .linearPCM):
            break
        case (.wav, .aac):
            // Reuse the closest typed validation case; WAV is PCM-only.
            throw ExportSettingsValidationError.audioCodecUnsupportedInContainer(
                .aac,
                .mov
            )
        case (.m4a, .linearPCM):
            throw ExportSettingsValidationError.audioCodecUnsupportedInContainer(
                .linearPCM,
                .mp4
            )
        }
    }

    func asExportAudioSettings() throws -> ExportAudioSettings {
        try ExportAudioSettings(
            codec: codec,
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitRate: bitRate
        )
    }
}

/// Immutable inputs for one audio-only export.
public struct AudioOnlyExportRequest: Sendable {
    /// Project snapshot.
    public let project: Project

    /// Sequence to mix.
    public let sequenceID: UUID

    /// Captured sequence.
    public let sequence: Sequence

    /// Half-open timeline range to mix.
    public let range: TimeRange

    /// Destination file URL.
    public let destinationURL: URL

    /// Validated audio settings.
    public let settings: AudioOnlyExportSettings

    /// Creates and validates an audio-only request.
    public init(
        project: Project,
        sequenceID: UUID,
        range: TimeRange,
        destinationURL: URL,
        settings: AudioOnlyExportSettings
    ) throws {
        do {
            try settings.validate()
        } catch let error as ExportSettingsValidationError {
            throw ExportError.invalidSettings(error)
        }

        guard let sequence = project.sequences.first(where: { $0.id == sequenceID }) else {
            throw ExportError.sequenceNotFound(sequenceID)
        }
        guard range.start >= .zero, range.duration > .zero else {
            throw ExportError.invalidRange(range)
        }
        do {
            guard try range.end() <= sequence.timelineDuration() else {
                throw ExportError.invalidRange(range)
            }
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }
        if settings.sampleRate != project.settings.audioSampleRate {
            throw ExportError.audioSampleRateMismatch(
                project: project.settings.audioSampleRate,
                export: settings.sampleRate
            )
        }
        guard destinationURL.isFileURL else {
            throw ExportError.destinationMustBeFileURL(destinationURL)
        }

        self.project = project
        self.sequenceID = sequenceID
        self.sequence = sequence
        self.range = range
        self.destinationURL = destinationURL
        self.settings = settings
    }
}

/// Result of a successful audio-only export.
public struct AudioOnlyExportResult: Equatable, Sendable {
    /// Published destination URL.
    public let destinationURL: URL

    /// Exact mixed duration.
    public let duration: RationalTime

    /// Number of offline-mixed audio frames written.
    public let audioFrameCount: Int
}

/// Offline-mix audio-only export (WAV PCM and AAC/M4A/MOV) — FR-EXP-004.
public enum AudioOnlyExporter {
    /// Mixes the range once and writes the container atomically.
    public static func export(
        request: AudioOnlyExportRequest,
        audioSourceProvider: any AudioSourceProvider
    ) async throws -> AudioOnlyExportResult {
        let buffer: RenderedAudioBuffer
        do {
            buffer = try OfflineAudioMixer.render(
                project: request.project,
                sequence: request.sequence,
                range: request.range,
                sourceProvider: audioSourceProvider,
                channelCount: request.settings.channelCount
            )
        } catch {
            throw ExportError.audioMixFailed(String(describing: error))
        }

        let transaction = try ExportOutputTransaction(destinationURL: request.destinationURL)
        do {
            switch request.settings.container {
            case .wav:
                try WAVWriter.write(buffer: buffer, to: transaction.temporaryURL)
            case .m4a, .mov:
                try await writeCompressedAudio(
                    buffer: buffer,
                    settings: request.settings,
                    to: transaction.temporaryURL,
                    duration: request.range.duration
                )
            }
            try transaction.commit()
        } catch {
            try? transaction.cleanUp()
            if let exportError = error as? ExportError {
                throw exportError
            }
            throw ExportError.audioOnlyExportFailed(String(describing: error))
        }

        return AudioOnlyExportResult(
            destinationURL: request.destinationURL,
            duration: request.range.duration,
            audioFrameCount: buffer.frameCount
        )
    }

    private static func writeCompressedAudio(
        buffer: RenderedAudioBuffer,
        settings: AudioOnlyExportSettings,
        to url: URL,
        duration: RationalTime
    ) async throws {
        let audioSettings = try settings.asExportAudioSettings()
        let fileType = try avFileType(for: settings.container)
        let writer = try makeWriter(url: url, fileType: fileType)
        let input = try addAudioInput(to: writer, audioSettings: audioSettings)
        try startWriter(writer)
        try await appendAllAudio(
            buffer: buffer,
            settings: audioSettings,
            input: input,
            writer: writer
        )
        try await finishWriter(writer, duration: duration, input: input)
    }

    private static func avFileType(for container: AudioOnlyContainer) throws -> AVFileType {
        switch container {
        case .m4a:
            return .m4a
        case .mov:
            return .mov
        case .wav:
            throw ExportError.audioOnlyExportFailed("WAV path should not use AVAssetWriter")
        }
    }

    private static func makeWriter(url: URL, fileType: AVFileType) throws -> AVAssetWriter {
        do {
            return try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw ExportError.writerCreationFailed(String(describing: error))
        }
    }

    private static func addAudioInput(
        to writer: AVAssetWriter,
        audioSettings: ExportAudioSettings
    ) throws -> AVAssetWriterInput {
        let output = AssetWriterSettings.audioOutput(for: audioSettings)
        guard writer.canApply(outputSettings: output, forMediaType: .audio) else {
            throw ExportError.inputConfigurationFailed(
                .audio,
                "AVAssetWriter cannot apply audio-only output settings"
            )
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: output)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw ExportError.inputConfigurationFailed(
                .audio,
                "AVAssetWriter cannot add audio-only input"
            )
        }
        writer.add(input)
        return input
    }

    private static func startWriter(_ writer: AVAssetWriter) throws {
        guard writer.startWriting() else {
            throw ExportError.writerStartFailed(
                writer.error.map(String.init(describing:)) ?? "unknown"
            )
        }
        writer.startSession(atSourceTime: .zero)
    }

    private static func appendAllAudio(
        buffer: RenderedAudioBuffer,
        settings: ExportAudioSettings,
        input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws {
        let factory = try AudioSampleBufferFactory(
            sampleRate: settings.sampleRate,
            channelCount: settings.channelCount
        )
        let chunk = 4_096
        var frameIndex = 0
        while frameIndex < buffer.frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task<Never, Never>.sleep(nanoseconds: 1_000_000)
            }
            let end = min(frameIndex + chunk, buffer.frameCount)
            let sampleBuffer = try factory.makeSampleBuffer(
                from: buffer,
                frames: frameIndex..<end
            )
            guard input.append(sampleBuffer) else {
                writer.cancelWriting()
                throw ExportError.appendRefused(
                    .audio,
                    reason: writer.error.map(String.init(describing:)) ?? "audio append refused",
                    underlyingError: writer.error as NSError?
                )
            }
            frameIndex = end
        }
    }

    private static func finishWriter(
        _ writer: AVAssetWriter,
        duration: RationalTime,
        input: AVAssetWriterInput
    ) async throws {
        input.markAsFinished()
        let endTime = try ExportTimeMapping.endTime(for: duration)
        writer.endSession(atSourceTime: endTime)

        typealias FinishContinuation = CheckedContinuation<Void, Error>
        try await withCheckedThrowingContinuation { (continuation: FinishContinuation) in
            writer.finishWriting { [writer] in
                let status = writer.status
                let errorDescription = writer.error.map(String.init(describing:))
                if status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: ExportError.writerFailed(
                            errorDescription ?? "audio finalize failed"
                        )
                    )
                }
            }
        }
    }
}

/// Decoded Float32 WAVE payload.
public struct WAVFloat32Contents: Equatable, Sendable {
    /// Sample rate in hertz.
    public let sampleRate: Int
    /// Interleaved channel count.
    public let channelCount: Int
    /// Interleaved IEEE Float32 samples.
    public let samples: [Float]
}

/// Reads a Float32 PCM WAVE file produced by `WAVWriter`.
public enum WAVReader {
    /// Decodes interleaved little-endian Float32 samples from a WAVE file.
    public static func readFloat32(from url: URL) throws -> WAVFloat32Contents {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else {
            throw ExportError.audioOnlyExportFailed("WAVE file too small")
        }
        // RIFF header
        guard String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE"
        else {
            throw ExportError.audioOnlyExportFailed("not a RIFF/WAVE file")
        }

        var offset = 12
        var sampleRate = 0
        var channelCount = 0
        var bitsPerSample = 0
        var audioFormat: UInt16 = 0
        var pcmData: Data?

        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let chunkSize = Int(readUInt32LE(data, offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + chunkSize
            guard payloadEnd <= data.count else {
                throw ExportError.audioOnlyExportFailed("WAVE chunk overruns file")
            }

            if chunkID == "fmt " {
                audioFormat = readUInt16LE(data, payloadStart)
                channelCount = Int(readUInt16LE(data, payloadStart + 2))
                sampleRate = Int(readUInt32LE(data, payloadStart + 4))
                bitsPerSample = Int(readUInt16LE(data, payloadStart + 14))
            } else if chunkID == "data" {
                pcmData = data[payloadStart..<payloadEnd]
            }

            offset = payloadEnd + (chunkSize % 2)
        }

        // WAVE_FORMAT_IEEE_FLOAT = 3
        guard audioFormat == 3, bitsPerSample == 32 else {
            throw ExportError.audioOnlyExportFailed(
                "expected IEEE Float32 WAVE (format \(audioFormat), \(bitsPerSample)-bit)"
            )
        }
        guard let pcmData, channelCount > 0, sampleRate > 0 else {
            throw ExportError.audioOnlyExportFailed("WAVE missing fmt/data")
        }
        let sampleCount = pcmData.count / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBytes { dest in
            pcmData.copyBytes(to: dest)
        }
        return WAVFloat32Contents(
            sampleRate: sampleRate,
            channelCount: channelCount,
            samples: samples
        )
    }

    private static func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

enum WAVWriter {
    static func write(buffer: RenderedAudioBuffer, to url: URL) throws {
        let channels = buffer.format.channelCount
        let sampleRate = buffer.format.sampleRate
        let frameCount = buffer.frameCount
        let bytesPerSample = 4
        let blockAlign = channels * bytesPerSample
        let dataSize = frameCount * blockAlign
        let byteRate = sampleRate * blockAlign

        var data = Data()
        data.reserveCapacity(44 + dataSize)

        func appendASCII(_ string: String) {
            data.append(contentsOf: string.utf8)
        }
        func appendUInt16(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt32(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(3) // WAVE_FORMAT_IEEE_FLOAT
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(32)
        appendASCII("data")
        appendUInt32(UInt32(dataSize))

        buffer.samples.withUnsafeBytes { raw in
            data.append(contentsOf: raw)
        }

        try data.write(to: url, options: .atomic)
    }
}
