// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
extension MediaPreviewIdentityTests {
    func model(
        with media: MediaRef,
        cache: MediaPreviewCache,
        root: URL
    ) throws -> EditorAjarAppModel {
        let model = EditorAjarAppModel(
            autosavePackageURL: root,
            autosaveIntervalSeconds: 0,
            automaticallyResolvesMediaReferences: false
        )
        try model.createNewProject(settings: .sensibleDefaults)
        XCTAssertTrue(model.applyEditForTesting(.addMediaReferences([media])))
        model.setMediaPreviewCacheForTesting(cache)
        return model
    }

    func ordinaryMedia(
        id: UUID = UUID(),
        sourceURL: URL,
        contentHash: ContentHash,
        availability: MediaAvailability = .available,
        isVideo: Bool = true
    ) throws -> MediaRef {
        MediaRef(
            id: id,
            sourceURL: sourceURL,
            contentHash: contentHash,
            metadata: try metadata(isVideo: isVideo),
            availability: availability
        )
    }

    func transcodedMedia(
        id: UUID = UUID(),
        sourceURL: URL,
        originalHash: ContentHash,
        playableHash: ContentHash?,
        availability: MediaAvailability = .available,
        isVideo: Bool = true
    ) throws -> MediaRef {
        MediaRef(
            id: id,
            sourceURL: sourceURL,
            contentHash: originalHash,
            metadata: try metadata(isVideo: isVideo),
            availability: availability,
            transcodeProvenance: MediaTranscodeProvenance(
                originalSourceURL: sourceURL.deletingLastPathComponent()
                    .appendingPathComponent("original-source.mov"),
                originalContentHash: originalHash,
                playableContentHash: playableHash
            )
        )
    }

    func metadata(isVideo: Bool) throws -> MediaMetadata {
        MediaMetadata(
            codecID: isVideo ? "prores422" : "pcm_f32le",
            pixelDimensions: isVideo ? PixelDimensions(width: 1_920, height: 1_080) : nil,
            frameRate: isVideo ? try FrameRate(frames: 30) : nil,
            duration: try RationalTime(value: 4, timescale: 1),
            colorSpace: isVideo ? .rec709 : .unspecified,
            audioChannelLayout: isVideo ? nil : AudioChannelLayout(channelCount: 1),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    }

    func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "editor-ajar-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func writePlayableSource(_ data: Data, to sourceURL: URL) throws {
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: sourceURL, options: .atomic)
    }

    func waitUntil(
        timeout: TimeInterval = 3,
        _ predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met within \(timeout) seconds")
        throw MediaPreviewIdentityTestError.timeout
    }

    nonisolated static var minimalPNGData: Data {
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/"
                + "x8AAwMCAO5W3qUAAAAASUVORK5CYII="
        ) ?? Data()
    }
}

enum MediaPreviewIdentityTestError: Error {
    case timeout
}

actor PreviewExtractionProbe {
    private(set) var callCount = 0

    func recordCall() {
        callCount += 1
    }
}

actor ControlledContentIdentityProbe {
    private let blockedCalls: Set<Int>
    private var callCount = 0
    private var startedCalls: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    init(blockedCalls: Set<Int>) {
        self.blockedCalls = blockedCalls
    }

    func resolve(media: MediaRef) async throws -> MediaPreviewContentIdentity {
        callCount += 1
        let call = callCount
        startedCalls.insert(call)
        if blockedCalls.contains(call) {
            await withCheckedContinuation { continuation in
                continuations[call] = continuation
            }
        }
        guard let contentHash = media.playableSourceContentHash else {
            throw MediaPreviewCacheError.missingHash
        }
        return .durable(contentHash)
    }

    func hasStarted(call: Int) -> Bool {
        startedCalls.contains(call)
    }

    func release(call: Int) {
        continuations.removeValue(forKey: call)?.resume()
    }
}

actor ControlledPreviewProbe {
    private let blockedCalls: Set<Int>
    private var callCount = 0
    private var startedCalls: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    init(blockedCalls: Set<Int>) {
        self.blockedCalls = blockedCalls
    }

    func extract(media _: MediaRef, kind: MediaPreviewKind) async throws -> Data {
        callCount += 1
        let call = callCount
        startedCalls.insert(call)
        if blockedCalls.contains(call) {
            await withCheckedContinuation { continuation in
                continuations[call] = continuation
            }
        }
        switch kind {
        case .thumbnail:
            return Data("thumbnail-\(call)".utf8)
        case .waveform:
            return try waveformData(marker: call)
        }
    }

    func hasStarted(call: Int) -> Bool {
        startedCalls.contains(call)
    }

    var extractionCount: Int {
        callCount
    }

    func release(call: Int) {
        continuations.removeValue(forKey: call)?.resume()
    }
}

actor CancellationAwarePreviewProbe {
    private(set) var hasStarted = false
    private(set) var wasCancelled = false

    func extract(media _: MediaRef, kind _: MediaPreviewKind) async throws -> Data {
        hasStarted = true
        do {
            try await Task.sleep(for: .seconds(60))
            return Data()
        } catch {
            wasCancelled = error is CancellationError
            throw error
        }
    }
}

actor ControlledHoverProbe {
    private let blockedCalls: Set<Int>
    private var callCount = 0
    private var startedCalls: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    init(blockedCalls: Set<Int>) {
        self.blockedCalls = blockedCalls
    }

    func frame(media _: MediaRef, time _: RationalTime) async -> Data {
        callCount += 1
        let call = callCount
        startedCalls.insert(call)
        if blockedCalls.contains(call) {
            await withCheckedContinuation { continuation in
                continuations[call] = continuation
            }
        }
        return Data("hover-\(call)".utf8)
    }

    func hasStarted(call: Int) -> Bool {
        startedCalls.contains(call)
    }

    func release(call: Int) {
        continuations.removeValue(forKey: call)?.resume()
    }
}

func waveformData(marker: Int) throws -> Data {
    let bin = AudioWaveformBin(
        minimum: -Float(marker),
        maximum: Float(marker),
        rms: Float(marker) / 2,
        frameCount: 1
    )
    let summary = AudioWaveformSummary(
        sampleRate: 48_000 + marker,
        channelCount: 1,
        sourceFrameCount: 1,
        framesPerBin: 1,
        channels: [AudioWaveformChannelSummary(channelIndex: 0, bins: [bin])]
    )
    return try JSONEncoder().encode(summary)
}
