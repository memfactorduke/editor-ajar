// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import AVFoundation
import CoreMedia
import Foundation
import XCTest

@testable import AjarExport

final class AudioOnlyExportTests: XCTestCase {
    func testFREXP004WAVRoundTripMatchesOfflineMixExactly() async throws {
        let fixture = try AudioOnlyFixture()
        let request = try fixture.makeRequest(
            container: .wav,
            codec: .linearPCM,
            bitRate: nil,
            fileExtension: "wav"
        )

        let expected = try OfflineAudioMixer.render(
            project: fixture.project,
            sequence: fixture.sequence,
            range: fixture.range,
            sourceProvider: fixture.audioProvider,
            channelCount: 2
        )

        let result = try await AudioOnlyExporter.export(
            request: request,
            audioSourceProvider: fixture.audioProvider
        )
        XCTAssertEqual(result.audioFrameCount, expected.frameCount)

        let decoded = try WAVReader.readFloat32(from: request.destinationURL)
        XCTAssertEqual(decoded.sampleRate, expected.format.sampleRate)
        XCTAssertEqual(decoded.channelCount, expected.format.channelCount)
        XCTAssertEqual(decoded.samples.count, expected.samples.count)
        XCTAssertEqual(decoded.samples, expected.samples)
    }

    func testFREXP004AACM4ARoundTripWithinDocumentedTolerance() async throws {
        let fixture = try AudioOnlyFixture()
        let request = try fixture.makeRequest(
            container: .m4a,
            codec: .aac,
            bitRate: 128_000,
            fileExtension: "m4a"
        )

        let expected = try OfflineAudioMixer.render(
            project: fixture.project,
            sequence: fixture.sequence,
            range: fixture.range,
            sourceProvider: fixture.audioProvider,
            channelCount: 2
        )

        // AAC software encode is always available on macOS 14+ runners — do not skip on
        // configuration / writer failures (that masked real defects).
        _ = try await AudioOnlyExporter.export(
            request: request,
            audioSourceProvider: fixture.audioProvider
        )

        let decoded = try await decodeAudioSamples(url: request.destinationURL)
        // AAC is lossy. Tolerance is documented here for CI stability:
        // mean absolute error ≤ 0.08 on a unit-amplitude offline mix after decode + length align.
        let mae = meanAbsoluteError(expected: expected.samples, actual: decoded)
        XCTAssertLessThanOrEqual(
            mae,
            0.08,
            "AAC decode MAE \(mae) exceeded documented tolerance 0.08"
        )
    }

    func testFREXP004AudioOnlyRejectsEmptyRange() throws {
        let fixture = try AudioOnlyFixture()
        let empty = try TimeRange(start: .zero, duration: .zero)
        XCTAssertThrowsError(
            try AudioOnlyExportRequest(
                project: fixture.project,
                sequenceID: fixture.sequence.id,
                range: empty,
                destinationURL: fixture.destinationURL(ext: "wav"),
                settings: try AudioOnlyExportSettings(
                    container: .wav,
                    codec: .linearPCM,
                    sampleRate: 48_000,
                    channelCount: 2
                )
            )
        ) { error in
            XCTAssertEqual(error as? ExportError, .invalidRange(empty))
        }
    }
}

// MARK: - Helpers

private func meanAbsoluteError(expected: [Float], actual: [Float]) -> Double {
    let count = min(expected.count, actual.count)
    guard count > 0 else {
        return Double.greatestFiniteMagnitude
    }
    var sum = 0.0
    for index in 0..<count {
        sum += abs(Double(expected[index] - actual[index]))
    }
    return sum / Double(count)
}

private func decodeAudioSamples(url: URL) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard let track = tracks.first else {
        throw ExportError.audioOnlyExportFailed("decoded asset has no audio track")
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
    reader.add(output)
    guard reader.startReading() else {
        throw ExportError.audioOnlyExportFailed(
            reader.error.map(String.init(describing:)) ?? "reader failed"
        )
    }
    var samples: [Float] = []
    while let sampleBuffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            continue
        }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        let floatCount = length / MemoryLayout<Float>.size
        data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Float.self)
            samples.append(contentsOf: buffer.prefix(floatCount))
        }
    }
    return samples
}

private struct AudioOnlyFixture {
    let directoryURL: URL
    let project: Project
    let sequence: Sequence
    let range: TimeRange
    let audioProvider: InMemoryAudioSourceProvider
    let mediaID: UUID

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-audio-only-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let frameRate = try FrameRate(frames: 30)
        let duration = try frameRate.duration(ofFrames: 30)
        range = try TimeRange(start: .zero, duration: duration)
        mediaID = UUID()
        sequence = try Self.makeSequence(mediaID: mediaID, frameRate: frameRate, range: range)
        project = Self.makeProject(
            sequence: sequence,
            mediaID: mediaID,
            frameRate: frameRate,
            duration: duration
        )
        audioProvider = try Self.makeAudioProvider(mediaID: mediaID)
    }

    private static func makeSequence(
        mediaID: UUID,
        frameRate: FrameRate,
        range: TimeRange
    ) throws -> Sequence {
        let audioClip = Clip(
            id: UUID(),
            source: .media(id: mediaID),
            sourceRange: range,
            timelineRange: range,
            kind: .audio,
            name: "Tone"
        )
        return Sequence(
            id: UUID(),
            name: "Audio only",
            videoTracks: [Track(id: UUID(), kind: .video, items: [.gap(range)])],
            audioTracks: [
                Track(id: UUID(), kind: .audio, items: [.clip(audioClip)])
            ],
            markers: [],
            timebase: frameRate
        )
    }

    private static func makeProject(
        sequence: Sequence,
        mediaID: UUID,
        frameRate: FrameRate,
        duration: RationalTime
    ) -> Project {
        Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 64, height: 64),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [
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
                        audioChannelLayout: AudioChannelLayout(channelCount: 2),
                        isVariableFrameRate: false,
                        conformedFrameRate: nil
                    )
                )
            ],
            sequences: [sequence]
        )
    }

    private static func makeAudioProvider(mediaID: UUID) throws -> InMemoryAudioSourceProvider {
        let sampleRate = 48_000
        let frameCount = 48_000 // 1 second at 48 kHz
        var samples = [Float](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let phase = Float(frame) * (2 * .pi * 440.0 / Float(sampleRate))
            let value = sin(phase) * 0.5
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: sampleRate, channelCount: 2),
            frameCount: frameCount,
            samples: samples
        )
        return InMemoryAudioSourceProvider(sources: [mediaID: source])
    }

    func destinationURL(ext: String) -> URL {
        directoryURL.appendingPathComponent("mix.\(ext)")
    }

    func makeRequest(
        container: AudioOnlyContainer,
        codec: ExportAudioCodec,
        bitRate: Int?,
        fileExtension: String
    ) throws -> AudioOnlyExportRequest {
        try AudioOnlyExportRequest(
            project: project,
            sequenceID: sequence.id,
            range: range,
            destinationURL: destinationURL(ext: fileExtension),
            settings: try AudioOnlyExportSettings(
                container: container,
                codec: codec,
                sampleRate: 48_000,
                channelCount: 2,
                bitRate: bitRate
            )
        )
    }
}
