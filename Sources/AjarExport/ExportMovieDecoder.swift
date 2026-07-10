// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Decodes exported movie containers back into packed BGRA8 / PCM for FR-EXP-007 gates.
public enum ExportMovieDecoder {
    /// Decodes every video sample as tightly packed BGRA8 (row padding stripped).
    public static func decodeBGRA8Frames(from url: URL) async throws -> [ExportDecodedBGRAFrame] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw ExportError.writerFailed("export golden decode found no video track")
        }

        let reader = try AVAssetReader(asset: asset)
        // Pin 709 primaries/transfer/matrix with 32BGRA so decode conversion is explicit rather
        // than inherited from track tags (FR-EXP-007 golden path).
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ]
            ]
        )
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw ExportError.writerFailed("export golden decode could not add video output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.writerFailed(
                "export golden decode failed to start: "
                    + String(describing: reader.error)
            )
        }

        var frames: [ExportDecodedBGRAFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
                throw ExportError.writerFailed("export golden decode sample missing image buffer")
            }
            // Strict sample enumeration: no pad/duplicate to a requested frame count. A short
            // movie fails later in ExportGoldenComparator as "frame counts differ".
            frames.append(try packedBGRA8Frame(from: imageBuffer))
        }
        if reader.status == .failed {
            throw ExportError.writerFailed(
                "export golden decode reader failed: "
                    + String(describing: reader.error)
            )
        }
        return frames
    }

    /// Decodes interleaved Float32 PCM when the container carries a linear-PCM audio track.
    ///
    /// Returns `nil` when there is no audio track. AAC is not expanded here — movie golden cases
    /// that assert audio determinism use PCM (offline mixer is deterministic; WSOLA already has
    /// its own tests).
    public static func decodeInterleavedFloat32PCM(from url: URL) async throws -> [Float]? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            return nil
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        )
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw ExportError.writerFailed("export golden decode could not add audio output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.writerFailed(
                "export golden audio decode failed to start: "
                    + String(describing: reader.error)
            )
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            samples.append(contentsOf: try float32Samples(from: sampleBuffer))
        }
        if reader.status == .failed {
            throw ExportError.writerFailed(
                "export golden audio decode reader failed: "
                    + String(describing: reader.error)
            )
        }
        return samples
    }

    private static func float32Samples(from sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return []
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            let status = CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: base
            )
            if status != kCMBlockBufferNoErr {
                throw ExportError.audioSampleBufferFailed(status)
            }
        }
        let floatCount = length / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(floatCount))
        }
    }

    /// Copies tightly packed BGRA8 from a 32BGRA pixel buffer (strips row padding).
    public static func packedBGRA8Frame(
        from pixelBuffer: CVPixelBuffer
    ) throws -> ExportDecodedBGRAFrame {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "could not lock decoded pixel buffer"
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "decoded pixel buffer has no base address"
            )
        }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dstRowBytes = width * 4
        var data = Data(count: dstRowBytes * height)
        data.withUnsafeMutableBytes { raw in
            guard let dstBase = raw.baseAddress else {
                return
            }
            for row in 0..<height {
                let src = base.advanced(by: row * srcRowBytes)
                let dst = dstBase.advanced(by: row * dstRowBytes)
                memcpy(dst, src, dstRowBytes)
            }
        }
        return ExportDecodedBGRAFrame(width: width, height: height, bgra8: data)
    }
}
