// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import AjarMedia
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaPreviewKind: String, Hashable, Sendable {
    case thumbnail = "thumbnail.png"
    case waveform = "waveform.json"
}

enum MediaPreviewCacheError: Error {
    case missingPackage
    case missingHash
    case imageConversionFailed
    case unsupportedAudio
    case invalidCachedData
}

/// Bounded, coalescing scheduler for regeneratable media browser previews (FR-MED-009).
///
/// On-disk location is the package-top-level `thumbnails/` directory (ADR-0007). Content-hash
/// keys make entries regeneratable after relink. **No cache pruning yet** — files can accumulate
/// under `thumbnails/` until a future maintenance pass (L1 / future work).
actor MediaPreviewCache {
    typealias Extractor = @Sendable (MediaRef, MediaPreviewKind) async throws -> Data
    typealias AudioChunkDecoder = @Sendable (MediaRef, TimeRange) async throws
        -> AudioSourceBuffer

    /// Four seconds keeps ordinary 48 kHz stereo PCM windows near 1.5 MiB. Sources with unusually
    /// large native formats are retried with successively smaller exact time ranges when the
    /// decoder reports its hard allocation ceiling.
    static let waveformDecodeChunkSeconds: Int64 = 4

    private let packageURL: URL
    private let workerLimit: Int
    private let extractor: Extractor
    private var activeWorkers = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var requests: [String: Task<Data, Error>] = [:]

    init(packageURL: URL, workerLimit: Int = 2, extractor: Extractor? = nil) {
        self.packageURL = packageURL
        self.workerLimit = max(1, workerLimit)
        self.extractor = extractor ?? { media, kind in
            try await Self.extract(media: media, kind: kind)
        }
    }

    /// Directory for durable thumbnail/waveform files (ADR-0007 top-level `thumbnails/`).
    var thumbnailsDirectoryURL: URL {
        packageURL.appendingPathComponent("thumbnails", isDirectory: true)
    }

    func data(for media: MediaRef, kind: MediaPreviewKind) async throws -> Data {
        let key = try cacheKey(media: media, kind: kind)
        let destination = cacheURL(key: key)
        if let data = try? Data(contentsOf: destination), isValidCachedData(data, kind: kind) {
            return data
        }
        if let existing = requests[key] {
            return try await existing.value
        }
        let task = Task<Data, Error> {
            try Task.checkCancellation()
            return try await self.runBounded {
                try Task.checkCancellation()
                let data = try await extractor(media, kind)
                try Task.checkCancellation()
                // Persist non-empty extractor output; structural validation is on read (L2).
                guard !data.isEmpty else {
                    throw MediaPreviewCacheError.invalidCachedData
                }
                // mkdir -p packageRoot/thumbnails before atomic write. Required for both saved
                // packages (thumbnails/ may not exist yet) and the untitled autosave fallback
                // (package root may have been cleared of recovery while still hosting caches).
                try Self.ensureDirectory(for: destination)
                try data.write(to: destination, options: .atomic)
                return data
            }
        }
        requests[key] = task
        defer { requests[key] = nil }
        return try await task.value
    }

    /// Cancels an in-flight durable extraction for `media`/`kind` if one is tracked.
    func cancel(for media: MediaRef, kind: MediaPreviewKind) {
        guard let key = try? cacheKey(media: media, kind: kind) else { return }
        requests[key]?.cancel()
    }

    /// Cancels every in-flight durable extraction.
    func cancelAll() {
        for (_, task) in requests {
            task.cancel()
        }
    }

    /// Runs a transient decode (e.g. hover-scrub) through the same worker bound — no disk write.
    func runBounded<T: Sendable>(
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        await acquireWorker()
        do {
            try Task.checkCancellation()
            let value = try await work()
            releaseWorker()
            return value
        } catch {
            releaseWorker()
            throw error
        }
    }

    /// Hover-scrub frame at `time`, scheduled under the worker bound (not a free-standing decoder).
    func hoverFramePNG(for media: MediaRef, at time: RationalTime) async throws -> Data {
        try await runBounded {
            try await Self.extractThumbnailPNG(media: media, at: time)
        }
    }

    func cachedData(for media: MediaRef, kind: MediaPreviewKind) -> Data? {
        guard let key = try? cacheKey(media: media, kind: kind) else { return nil }
        guard let data = try? Data(contentsOf: cacheURL(key: key)),
              isValidCachedData(data, kind: kind)
        else {
            return nil
        }
        return data
    }

    private func cacheKey(media: MediaRef, kind: MediaPreviewKind) throws -> String {
        guard let hash = media.contentHash else { throw MediaPreviewCacheError.missingHash }
        return "\(hash.algorithm.rawValue)-\(hash.digest)-\(kind.rawValue)"
    }

    private func cacheURL(key: String) -> URL {
        // ADR-0007: top-level thumbnails/, not caches/thumbnails/.
        thumbnailsDirectoryURL.appendingPathComponent(key)
    }

    /// Creates the destination's parent directory tree (`package/…/thumbnails/`) if needed.
    ///
    /// Foundation's atomic `Data.write` uses mktemp in the parent; a missing or non-directory
    /// parent surfaces as `NSCocoaErrorDomain` / errno `EINVAL` (22) rather than a clean ENOENT.
    private static func ensureDirectory(for fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else {
            throw MediaPreviewCacheError.missingPackage
        }
    }

    private func isValidCachedData(_ data: Data, kind: MediaPreviewKind) -> Bool {
        Self.isValidCachedData(data, kind: kind)
    }

    /// Nonzero + kind-specific structural validation; failed validation forces regenerate (L2).
    nonisolated static func isValidCachedData(_ data: Data, kind: MediaPreviewKind) -> Bool {
        guard !data.isEmpty else { return false }
        switch kind {
        case .thumbnail:
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return false
            }
            return CGImageSourceGetCount(source) > 0
                && CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        case .waveform:
            return (try? JSONDecoder().decode(AudioWaveformSummary.self, from: data)) != nil
        }
    }

    /// Transfer the held worker slot on resume — never decrement then re-increment (M2).
    private func acquireWorker() async {
        if activeWorkers < workerLimit {
            activeWorkers += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        // Slot ownership was transferred by `releaseWorker`; do not increment again.
    }

    private func releaseWorker() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            activeWorkers -= 1
        }
    }

    private static func extract(media: MediaRef, kind: MediaPreviewKind) async throws -> Data {
        try Task.checkCancellation()
        switch kind {
        case .thumbnail:
            return try await extractThumbnailPNG(media: media, at: .zero)
        case .waveform:
            let summary = try await waveformSummary(for: media) { media, range in
                try await audioBuffer(for: media, range: range)
            }
            return try JSONEncoder().encode(summary)
        }
    }

    /// Generates one deterministic waveform while retaining only a bounded PCM window at a time.
    ///
    /// The accumulator preserves a partially filled bin between native-rate windows, so 44.1 kHz
    /// and other rates whose 24 Hz bin boundary does not align with four seconds produce exactly
    /// the same bins as a monolithic analysis.
    static func waveformSummary(
        for media: MediaRef,
        decodeChunk: AudioChunkDecoder
    ) async throws -> AudioWaveformSummary {
        let sourceDuration = media.metadata.duration
        let preferredChunkDuration = try RationalTime(
            value: waveformDecodeChunkSeconds,
            timescale: 1
        )
        let verifiedSource = try await MediaSourceIdentityVerifier.shared.verifyBeforeReading(media)
        var nextStart = RationalTime.zero
        var maximumChunkDuration = preferredChunkDuration
        var accumulator: AudioWaveformAccumulator?
        var decodedEmptySource = false

        while nextStart < sourceDuration || !decodedEmptySource && sourceDuration == .zero {
            try Task.checkCancellation()
            let remainingDuration = try sourceDuration.subtracting(nextStart)
            let initialChunkDuration = min(maximumChunkDuration, remainingDuration)
            let (source, decodedDuration) = try await boundedAudioChunk(
                media: media,
                start: nextStart,
                duration: initialChunkDuration,
                decodeChunk: decodeChunk
            )
            try Task.checkCancellation()

            if accumulator == nil {
                accumulator = try AudioWaveformAccumulator(
                    format: source.format,
                    binsPerSecond: 24
                )
            }
            try accumulator?.append(source) {
                try Task.checkCancellation()
            }

            decodedEmptySource = true
            nextStart = try nextStart.adding(decodedDuration)
            maximumChunkDuration = min(maximumChunkDuration, decodedDuration)
        }

        guard var accumulator else {
            throw MediaPreviewCacheError.unsupportedAudio
        }
        try Task.checkCancellation()
        let summary = accumulator.makeSummary()
        try await MediaSourceIdentityVerifier.shared.verifyAfterReading(verifiedSource)
        return summary
    }

    private static func boundedAudioChunk(
        media: MediaRef,
        start: RationalTime,
        duration initialDuration: RationalTime,
        decodeChunk: AudioChunkDecoder
    ) async throws -> (source: AudioSourceBuffer, duration: RationalTime) {
        var duration = initialDuration
        while true {
            try Task.checkCancellation()
            let range = try TimeRange(start: start, duration: duration)
            do {
                return (try await decodeChunk(media, range), duration)
            } catch let error as AudioPCMDecodeError {
                guard case .windowTooLarge(_, let frameCount, _, _) = error,
                    frameCount > 1
                else {
                    throw error
                }
                duration = try duration.divided(by: 2)
            }
        }
    }

    private static func extractThumbnailPNG(
        media: MediaRef,
        at time: RationalTime
    ) async throws -> Data {
        try Task.checkCancellation()
        let decoder = try VideoFrameDecoder()
        let frame = try await decoder.decodeFrame(from: media, at: time)
        try Task.checkCancellation()
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw MediaPreviewCacheError.imageConversionFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw MediaPreviewCacheError.imageConversionFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaPreviewCacheError.imageConversionFailed
        }
        return data as Data
    }

    private static func audioBuffer(
        for media: MediaRef,
        range: TimeRange
    ) async throws -> AudioSourceBuffer {
        let decoded = try await AudioPCMDecoder().decodeWindow(
            from: media,
            sourceRange: range
        )
        try Task.checkCancellation()
        return try AudioSourceBuffer(
            format: AudioRenderFormat(
                sampleRate: decoded.sampleRate,
                channelCount: decoded.channelCount
            ),
            frameCount: decoded.frameCount,
            samples: decoded.samples,
            frameOffset: decoded.frameOffset
        )
    }
}
