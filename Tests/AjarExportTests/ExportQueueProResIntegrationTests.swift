// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
import AVFoundation
import AjarCore
import AjarRender
import CoreMedia
import Foundation
import Metal
import XCTest

@testable import AjarExport

// swiftlint:enable sorted_imports

/// Queue + real ProRes path (CI can encode ProRes; prefer over H.264 for integration).
final class ExportQueueProResIntegrationTests: XCTestCase {
    func testFREXP005QueuedProResExportCompletesThroughQueue() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on this runner")
        }

        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let request = try makeProResRequest(
            destinationURL: directory.appendingPathComponent("queue.mov")
        )
        let frameProvider = try makeFrameProvider(for: request)
        let queue = ExportQueue { jobID, jobRequest, onProgress in
            ExportSession(
                id: jobID,
                request: jobRequest,
                frameProvider: frameProvider,
                audioSourceProvider: nil,
                onFrameProgress: onProgress
            )
        }

        let jobID = await queue.enqueue(request: request, displayName: "prores-queue")
        let done = await ExportQueueFixtures.waitUntil(timeout: 30) {
            let state = await queue.state(for: jobID)
            return state == .done || state == .failed || state == .cancelled
        }
        XCTAssertTrue(done)
        try await assertProResSuccess(queue: queue, jobID: jobID, url: request.destinationURL)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-export-queue-prores-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeProResRequest(destinationURL: URL) throws -> ExportRequest {
        let frameRate = try FrameRate(frames: 30)
        let frameCount = Int64(4)
        let duration = try frameRate.duration(ofFrames: frameCount)
        let range = try TimeRange(start: .zero, duration: duration)
        let sequenceID = UUID()
        let sequence = Sequence(
            id: sequenceID,
            name: "ProRes Queue",
            videoTracks: [Track(id: UUID(), kind: .video, items: [.gap(range)])],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 64, height: 64),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [],
            sequences: [sequence]
        )
        let settings = try ExportSettings(
            container: .mov,
            video: ExportVideoSettings(
                codec: .proRes422,
                resolution: PixelDimensions(width: 64, height: 64),
                frameRate: frameRate,
                colorSpace: .rec709
            ),
            audio: nil
        )
        return try ExportRequest(
            project: project,
            sequenceID: sequenceID,
            range: range,
            destinationURL: destinationURL,
            settings: settings
        )
    }

    private func makeFrameProvider(
        for request: ExportRequest
    ) throws -> RenderGraphExportFrameProvider {
        do {
            return try RenderGraphExportFrameProvider(
                project: request.project,
                sequence: request.sequence,
                videoSettings: request.settings.video,
                sourceProvider: SourceLessExportProvider()
            )
        } catch {
            throw XCTSkip("RenderGraph export provider unavailable: \(error)")
        }
    }

    private func assertProResSuccess(
        queue: ExportQueue,
        jobID: UUID,
        url: URL
    ) async throws {
        let state = await queue.state(for: jobID)
        if state == .failed {
            let failure = await queue.snapshots().first(where: { $0.id == jobID })?.failure
            XCTFail("ProRes queue export failed: \(String(describing: failure))")
            return
        }
        XCTAssertEqual(state, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let formatDescriptions = try await tracks[0].load(.formatDescriptions)
        guard let description = formatDescriptions.first else {
            XCTFail("expected a video format description")
            return
        }
        XCTAssertEqual(
            CMFormatDescriptionGetMediaSubType(description),
            kCMVideoCodecType_AppleProRes422
        )
    }
}
