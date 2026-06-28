// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import Foundation

enum WAVCodec {
    static func write(_ buffer: RenderedAudioBuffer, to url: URL) throws {
        let dataByteCount = buffer.samples.count * MemoryLayout<Float>.size
        try validateWritable(format: buffer.format, dataByteCount: dataByteCount)
        var data = Data()
        appendASCII("RIFF", to: &data)
        appendUInt32LE(UInt32(36 + dataByteCount), to: &data)
        appendASCII("WAVE", to: &data)
        appendFormatChunk(format: buffer.format, to: &data)
        appendASCII("data", to: &data)
        appendUInt32LE(UInt32(dataByteCount), to: &data)
        for sample in buffer.samples {
            appendFloat32LE(sample, to: &data)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    static func write(_ source: AudioSourceBuffer, to url: URL) throws {
        let rendered = try RenderedAudioBuffer(
            format: source.format,
            frameCount: source.frameCount,
            samples: source.samples
        )
        try write(rendered, to: url)
    }

    static func readAudioSource(from url: URL) throws -> AudioSourceBuffer {
        let decoded = try readDecodedWAV(from: url)
        return try AudioSourceBuffer(
            format: decoded.format,
            frameCount: decoded.frameCount,
            samples: decoded.samples
        )
    }

    static func readRenderedAudio(from url: URL) throws -> RenderedAudioBuffer {
        let decoded = try readDecodedWAV(from: url)
        return try RenderedAudioBuffer(
            format: decoded.format,
            frameCount: decoded.frameCount,
            samples: decoded.samples
        )
    }
}

private struct DecodedWAV {
    let format: AudioRenderFormat
    let frameCount: Int
    let samples: [Float]
}

private struct WAVFormatChunk {
    let audioFormat: UInt16
    let channelCount: Int
    let sampleRate: Int
    let bitsPerSample: UInt16
}

private extension WAVCodec {
    static func validateWritable(format: AudioRenderFormat, dataByteCount: Int) throws {
        let blockAlign = format.channelCount * MemoryLayout<Float>.size
        guard format.channelCount > 0,
              format.channelCount <= Int(UInt16.max),
              format.sampleRate > 0,
              format.sampleRate <= Int(UInt32.max),
              dataByteCount <= Int(UInt32.max) - 36,
              blockAlign <= Int(UInt16.max),
              format.sampleRate <= Int(UInt32.max) / blockAlign
        else {
            throw AjarCLIError.audioFailed("audio buffer is too large for WAV output")
        }
    }

    static func readDecodedWAV(from url: URL) throws -> DecodedWAV {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard ascii(bytes, range: 0..<4) == "RIFF",
              ascii(bytes, range: 8..<12) == "WAVE"
        else {
            throw AjarCLIError.audioFailed("unsupported WAV header at \(url.path)")
        }

        let chunks = try scanChunks(bytes)
        guard let formatChunk = chunks.format else {
            throw AjarCLIError.audioFailed("WAV missing fmt chunk at \(url.path)")
        }
        guard let dataRange = chunks.dataRange else {
            throw AjarCLIError.audioFailed("WAV missing data chunk at \(url.path)")
        }
        guard formatChunk.audioFormat == 3, formatChunk.bitsPerSample == 32 else {
            throw AjarCLIError.audioFailed("only 32-bit float WAV is supported")
        }

        return try decodeFloatSamples(bytes: bytes, format: formatChunk, dataRange: dataRange)
    }

    static func scanChunks(
        _ bytes: [UInt8]
    ) throws -> (
        format: WAVFormatChunk?,
        dataRange: Range<Int>?
    ) {
        var offset = 12
        var format: WAVFormatChunk?
        var dataRange: Range<Int>?

        while offset + 8 <= bytes.count {
            let chunkID = ascii(bytes, range: offset..<(offset + 4)) ?? "????"
            let size = Int(readUInt32LE(bytes, at: offset + 4) ?? 0)
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= bytes.count else {
                throw AjarCLIError.audioFailed("WAV chunk \(chunkID) extends past EOF")
            }
            if chunkID == "fmt " {
                format = try parseFormatChunk(bytes: bytes, range: payloadStart..<payloadEnd)
            } else if chunkID == "data" {
                dataRange = payloadStart..<payloadEnd
            }
            offset = payloadEnd + (size % 2)
        }

        return (format, dataRange)
    }

    static func parseFormatChunk(bytes: [UInt8], range: Range<Int>) throws -> WAVFormatChunk {
        guard range.count >= 16,
              let audioFormat = readUInt16LE(bytes, at: range.lowerBound),
              let channelCount = readUInt16LE(bytes, at: range.lowerBound + 2),
              let sampleRate = readUInt32LE(bytes, at: range.lowerBound + 4),
              let bitsPerSample = readUInt16LE(bytes, at: range.lowerBound + 14)
        else {
            throw AjarCLIError.audioFailed("malformed WAV fmt chunk")
        }

        return WAVFormatChunk(
            audioFormat: audioFormat,
            channelCount: Int(channelCount),
            sampleRate: Int(sampleRate),
            bitsPerSample: bitsPerSample
        )
    }

    static func decodeFloatSamples(
        bytes: [UInt8],
        format: WAVFormatChunk,
        dataRange: Range<Int>
    ) throws -> DecodedWAV {
        guard dataRange.count % MemoryLayout<Float>.size == 0 else {
            throw AjarCLIError.audioFailed("WAV float data is not 32-bit aligned")
        }

        let sampleCount = dataRange.count / MemoryLayout<Float>.size
        guard format.channelCount > 0, sampleCount % format.channelCount == 0 else {
            throw AjarCLIError.audioFailed("WAV data does not align with channel count")
        }

        var samples: [Float] = []
        samples.reserveCapacity(sampleCount)
        for offset in stride(from: dataRange.lowerBound, to: dataRange.upperBound, by: 4) {
            guard let bitPattern = readUInt32LE(bytes, at: offset) else {
                throw AjarCLIError.audioFailed("WAV sample extends past EOF")
            }
            samples.append(Float(bitPattern: bitPattern))
        }

        return DecodedWAV(
            format: AudioRenderFormat(
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            ),
            frameCount: sampleCount / format.channelCount,
            samples: samples
        )
    }
}

private extension WAVCodec {
    static func appendFormatChunk(format: AudioRenderFormat, to data: inout Data) {
        appendASCII("fmt ", to: &data)
        appendUInt32LE(16, to: &data)
        appendUInt16LE(3, to: &data)
        appendUInt16LE(UInt16(format.channelCount), to: &data)
        appendUInt32LE(UInt32(format.sampleRate), to: &data)
        let blockAlign = UInt16(format.channelCount * MemoryLayout<Float>.size)
        appendUInt32LE(UInt32(format.sampleRate * Int(blockAlign)), to: &data)
        appendUInt16LE(blockAlign, to: &data)
        appendUInt16LE(32, to: &data)
    }

    static func appendASCII(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0x00FF))
        data.append(UInt8((value >> 8) & 0x00FF))
    }

    static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0x000000FF))
        data.append(UInt8((value >> 8) & 0x000000FF))
        data.append(UInt8((value >> 16) & 0x000000FF))
        data.append(UInt8((value >> 24) & 0x000000FF))
    }

    static func appendFloat32LE(_ value: Float, to data: inout Data) {
        appendUInt32LE(value.bitPattern, to: &data)
    }
}

private func ascii(_ bytes: [UInt8], range: Range<Int>) -> String? {
    guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
        return nil
    }
    return String(bytes: bytes[range], encoding: .ascii)
}

private func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= bytes.count else {
        return nil
    }
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= bytes.count else {
        return nil
    }
    return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}
