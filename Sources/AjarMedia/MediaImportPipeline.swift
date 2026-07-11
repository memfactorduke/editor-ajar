// SPDX-License-Identifier: GPL-3.0-or-later
// swiftlint:disable file_length

import AjarCore
import Foundation

/// Stage reported while discovering and importing file/folder selections.
public enum MediaImportProgressPhase: String, Equatable, Sendable {
    /// Recursive folder enumeration is in progress.
    case discovering

    /// Discovered files are being probed, hashed, and bookmarked.
    case importing
}

/// Session-only progress for one import batch (FR-MED-001).
public struct MediaImportProgress: Equatable, Sendable {
    /// Current import stage.
    public let phase: MediaImportProgressPhase

    /// Number of discovered files whose import attempt has completed.
    public let completedUnitCount: Int

    /// Total number of discovered files, once enumeration finishes.
    public let totalUnitCount: Int

    /// File currently being imported, if any.
    public let currentFileURL: URL?

    /// Creates a progress snapshot.
    public init(
        phase: MediaImportProgressPhase,
        completedUnitCount: Int,
        totalUnitCount: Int,
        currentFileURL: URL? = nil
    ) {
        self.phase = phase
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.currentFileURL = currentFileURL
    }

    /// Normalized completion for a determinate progress indicator.
    public var fractionCompleted: Double {
        guard totalUnitCount > 0 else {
            return 0
        }
        return min(1, max(0, Double(completedUnitCount) / Double(totalUnitCount)))
    }
}

/// Typed failures shown per source in the import summary.
public enum MediaImportError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A selection was not a local file URL.
    case sourceMustBeFileURL(URL)

    /// A selected file/folder was missing or unreadable.
    case sourceUnavailable(URL)

    /// Recursive folder enumeration failed.
    case folderEnumerationFailed(url: URL, reason: String)

    /// AVFoundation/ImageIO cannot open the format and no FFmpeg fallback exists in this build.
    case unsupportedFormat(URL)

    /// Native media probing failed for a supported-looking source.
    case probingFailed(url: URL, reason: String)

    /// VFR was detected, but no stable conform rate could be derived.
    case conformRateUnavailable(URL)

    /// SHA-256 hashing failed.
    case hashingFailed(url: URL, reason: String)

    /// A durable security-scoped bookmark could not be created.
    case bookmarkCreationFailed(url: URL, reason: String)

    /// The prepared reference could not be committed to the open project.
    case projectUpdateFailed(url: URL, reason: String)

    public var description: String {
        switch self {
        case .sourceMustBeFileURL(let url):
            "not a local file URL: \(url)"
        case .sourceUnavailable(let url):
            "source is missing or unreadable: \(url.path)"
        case .folderEnumerationFailed(let url, let reason):
            "could not scan \(url.lastPathComponent): \(reason)"
        case .unsupportedFormat(let url):
            "unsupported format (FFmpeg import fallback is not available): \(url.lastPathComponent)"
        case .probingFailed(let url, let reason):
            "could not inspect \(url.lastPathComponent): \(reason)"
        case .conformRateUnavailable(let url):
            "variable frame rate detected but no stable conform rate was available: "
                + url.lastPathComponent
        case .hashingFailed(let url, let reason):
            "could not hash \(url.lastPathComponent): \(reason)"
        case .bookmarkCreationFailed(let url, let reason):
            "could not save access to \(url.lastPathComponent): \(reason)"
        case .projectUpdateFailed(let url, let reason):
            "could not add \(url.lastPathComponent) to the project: \(reason)"
        }
    }
}

/// One successfully prepared media reference.
public struct ImportedMediaItem: Equatable, Sendable {
    /// Original URL kept in place (FR-MED-008).
    public let sourceURL: URL

    /// Stable, hashed, bookmarked project reference.
    public let mediaReference: MediaRef

    /// Creates an imported item.
    public init(sourceURL: URL, mediaReference: MediaRef) {
        self.sourceURL = sourceURL
        self.mediaReference = mediaReference
    }
}

/// One same-content source intentionally skipped by import deduplication.
public struct SkippedDuplicateMediaItem: Equatable, Sendable {
    /// Newly selected duplicate path.
    public let sourceURL: URL

    /// Stable ID of the first reference retained in the pool.
    public let existingMediaID: UUID

    /// Existing path/bookmark retained without an implicit relink.
    public let existingSourceURL: URL?

    /// Creates a duplicate result.
    public init(sourceURL: URL, existingMediaID: UUID, existingSourceURL: URL?) {
        self.sourceURL = sourceURL
        self.existingMediaID = existingMediaID
        self.existingSourceURL = existingSourceURL
    }
}

/// One VFR source and its stable import timebase.
public struct ConformedVariableFrameRateItem: Equatable, Sendable {
    /// Imported source.
    public let sourceURL: URL

    /// Native/average source rate when known.
    public let sourceFrameRate: FrameRate?

    /// Stable timebase stored on the media reference.
    public let conformedFrameRate: FrameRate

    /// Creates a VFR summary item.
    public init(
        sourceURL: URL,
        sourceFrameRate: FrameRate?,
        conformedFrameRate: FrameRate
    ) {
        self.sourceURL = sourceURL
        self.sourceFrameRate = sourceFrameRate
        self.conformedFrameRate = conformedFrameRate
    }
}

/// One failed file/folder selection.
public struct FailedMediaImportItem: Equatable, Sendable {
    /// Source that failed.
    public let sourceURL: URL

    /// Typed failure reason.
    public let error: MediaImportError

    /// Creates a failed item.
    public init(sourceURL: URL, error: MediaImportError) {
        self.sourceURL = sourceURL
        self.error = error
    }
}

/// User-visible result of a complete media import batch.
public struct MediaImportSummary: Equatable, Sendable {
    /// Files appended to the media pool.
    public let imported: [ImportedMediaItem]

    /// Same-hash files skipped without changing the first reference.
    public let skippedDuplicates: [SkippedDuplicateMediaItem]

    /// Imported VFR files and their chosen stable timebases.
    public let vfrConformed: [ConformedVariableFrameRateItem]

    /// Files/folders that could not be imported.
    public let failed: [FailedMediaImportItem]

    /// Creates an import summary.
    public init(
        imported: [ImportedMediaItem] = [],
        skippedDuplicates: [SkippedDuplicateMediaItem] = [],
        vfrConformed: [ConformedVariableFrameRateItem] = [],
        failed: [FailedMediaImportItem] = []
    ) {
        self.imported = imported
        self.skippedDuplicates = skippedDuplicates
        self.vfrConformed = vfrConformed
        self.failed = failed
    }

    /// Whether the selection contained no importable files and produced no file-level failures.
    public var isEmpty: Bool {
        imported.isEmpty
            && skippedDuplicates.isEmpty
            && vfrConformed.isEmpty
            && failed.isEmpty
    }
}

/// Prepared import result: one deterministic command plus the complete UI summary.
public struct PreparedMediaImportBatch: Equatable, Sendable {
    /// One undoable command for all successful files, or `nil` when none succeeded.
    public let command: EditCommand?

    /// Complete imported/skipped/conformed/failed breakdown.
    public let summary: MediaImportSummary

    /// Creates a prepared batch.
    public init(command: EditCommand?, summary: MediaImportSummary) {
        self.command = command
        self.summary = summary
    }
}

/// VFR conform decision at the import boundary (FR-MED-010).
public enum MediaFrameRateConformer {
    /// Returns metadata with a stable VFR timebase, preserving a probe-provided choice when set.
    public static func conform(_ result: MediaProbeResult) -> MediaMetadata? {
        let metadata = result.metadata
        guard metadata.isVariableFrameRate else {
            return metadata
        }
        if metadata.conformedFrameRate != nil {
            return metadata
        }

        let averageRate: Double?
        let statisticsDuration = result.videoDuration ?? metadata.duration
        if let frameCount = result.videoFrameCount,
           frameCount > 0,
           statisticsDuration.value > 0 {
            averageRate = Double(frameCount) * Double(statisticsDuration.timescale)
                / Double(statisticsDuration.value)
        } else if let frameRate = metadata.frameRate {
            averageRate = Double(frameRate.frames) / Double(frameRate.seconds)
        } else {
            averageRate = nil
        }
        guard let averageRate,
              averageRate.isFinite,
              averageRate > 0,
              let conformedRate = nearestStandardRate(to: averageRate)
        else {
            return nil
        }

        return MediaMetadata(
            codecID: metadata.codecID,
            pixelDimensions: metadata.pixelDimensions,
            frameRate: metadata.frameRate,
            duration: metadata.duration,
            colorSpace: metadata.colorSpace,
            audioChannelLayout: metadata.audioChannelLayout,
            isVariableFrameRate: true,
            conformedFrameRate: conformedRate
        )
    }

    private static func nearestStandardRate(to framesPerSecond: Double) -> FrameRate? {
        standardRates.min { left, right in
            abs(left.framesPerSecond - framesPerSecond)
                < abs(right.framesPerSecond - framesPerSecond)
        }?.rate
    }

    private static var standardRates: [(rate: FrameRate, framesPerSecond: Double)] {
        let values: [(Int64, Int64)] = [
            (24_000, 1_001), (24, 1), (25, 1), (30_000, 1_001), (30, 1),
            (48_000, 1_001), (48, 1), (50, 1), (60_000, 1_001), (60, 1), (120, 1)
        ]
        return values.compactMap { frames, seconds in
            guard let rate = try? FrameRate(frames: frames, per: seconds) else {
                return nil
            }
            return (rate, Double(frames) / Double(seconds))
        }
    }
}

/// Asynchronous import orchestrator. Actor isolation keeps recursive I/O, hashing, and bookmark
/// work off the main actor so the app remains responsive throughout a batch (FR-MED-001).
public actor MediaImportPipeline {
    /// Progress callback invoked after discovery and each attempted file.
    public typealias ProgressHandler = @Sendable (MediaImportProgress) async -> Void

    private let probe: any MediaProbing
    private let hasher: any MediaFileHashing
    private let bookmarkStore: any MediaBookmarkStore
    private let fileManager: FileManager
    private let makeMediaID: @Sendable () -> UUID

    /// Creates the production native import pipeline.
    public init() {
        self.init(
            probe: AVFoundationMediaProbe(),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: SecurityScopedMediaBookmarkStore()
        )
    }

    /// Creates an import pipeline with injectable platform boundaries.
    public init(
        probe: any MediaProbing,
        hasher: any MediaFileHashing,
        bookmarkStore: any MediaBookmarkStore,
        fileManager: FileManager = .default,
        makeMediaID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.probe = probe
        self.hasher = hasher
        self.bookmarkStore = bookmarkStore
        self.fileManager = fileManager
        self.makeMediaID = makeMediaID
    }

    /// Prepares one import batch from file and/or folder URLs without mutating the project.
    ///
    /// Same-hash selections are true no-ops: the existing URL/bookmark is retained. Changing it
    /// here would silently relink a stable reference; relink remains an explicit undoable action.
    ///
    /// Cooperative cancellation: the per-file loop checks `Task.isCancelled` before each file and
    /// stops early, returning the **partial** batch prepared so far rather than throwing. This
    /// matches the caller's existing handling — `EditorAjarAppModel.performMediaImport` guards
    /// `!Task.isCancelled` after this returns and takes a no-mutation path, so the partial batch is
    /// simply discarded. Returning a value (rather than throwing `CancellationError`) keeps this
    /// non-`throws` surface stable for every call site and needs no `try` at the boundary.
    public func prepareImport(
        from selectedURLs: [URL],
        existingMedia: [MediaRef],
        progress: ProgressHandler? = nil
    ) async -> PreparedMediaImportBatch {
        let scopedURLs = selectedURLs.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }
        defer {
            for (url, started) in scopedURLs where started {
                url.stopAccessingSecurityScopedResource()
            }
        }

        await progress?(
            MediaImportProgress(
                phase: .discovering,
                completedUnitCount: 0,
                totalUnitCount: 0
            )
        )
        let discovery = discoverFiles(from: selectedURLs)
        let total = discovery.files.count
        await progress?(
            MediaImportProgress(
                phase: .importing,
                completedUnitCount: 0,
                totalUnitCount: total
            )
        )

        var accumulator = MediaImportAccumulator(
            existingMedia: existingMedia,
            discoveryFailures: discovery.failures
        )

        for (index, fileURL) in discovery.files.enumerated() {
            // Bail early on cancellation with the partial batch; the caller's post-return
            // `!Task.isCancelled` guard discards it without mutating the pool.
            if Task.isCancelled {
                break
            }
            await progress?(
                MediaImportProgress(
                    phase: .importing,
                    completedUnitCount: index,
                    totalUnitCount: total,
                    currentFileURL: fileURL
                )
            )
            let result = await prepareFile(
                fileURL,
                referenceByHash: accumulator.referenceByHash
            )
            accumulator.record(result, sourceURL: fileURL)
            await progress?(
                MediaImportProgress(
                    phase: .importing,
                    completedUnitCount: index + 1,
                    totalUnitCount: total
                )
            )
        }
        return accumulator.preparedBatch
    }

    private func prepareFile(
        _ fileURL: URL,
        referenceByHash: [ContentHash: MediaRef]
    ) async -> PreparedFileResult {
        let probed: MediaProbeResult
        switch await probeResult(for: fileURL) {
        case .success(let result):
            probed = result
        case .failure(let error):
            return failedResult(for: fileURL, error: error)
        }

        guard let metadata = MediaFrameRateConformer.conform(probed) else {
            return .failed(
                FailedMediaImportItem(
                    sourceURL: fileURL,
                    error: .conformRateUnavailable(fileURL)
                )
            )
        }

        let contentHash: ContentHash
        switch contentHashResult(for: fileURL) {
        case .success(let hash):
            contentHash = hash
        case .failure(let error):
            return failedResult(for: fileURL, error: error)
        }

        if let existing = referenceByHash[contentHash] {
            return .duplicate(
                SkippedDuplicateMediaItem(
                    sourceURL: fileURL,
                    existingMediaID: existing.id,
                    existingSourceURL: existing.sourceURL
                )
            )
        }

        let bookmark: Data
        switch bookmarkResult(for: fileURL) {
        case .success(let data):
            bookmark = data
        case .failure(let error):
            return failedResult(for: fileURL, error: error)
        }

        let reference = MediaRef(
            id: makeMediaID(),
            sourceURL: fileURL,
            bookmark: bookmark,
            contentHash: contentHash,
            metadata: metadata
        )
        return .imported(ImportedMediaItem(sourceURL: fileURL, mediaReference: reference))
    }

    private func probeResult(
        for fileURL: URL
    ) async -> Result<MediaProbeResult, MediaImportError> {
        do {
            return .success(try await probe.probe(fileURL))
        } catch let error as MediaProbeError {
            switch error {
            case .unsupportedFormat:
                return .failure(.unsupportedFormat(fileURL))
            case .sourceMustBeFileURL:
                return .failure(.sourceMustBeFileURL(fileURL))
            case .sourceUnavailable:
                return .failure(.sourceUnavailable(fileURL))
            case .metadataUnavailable, .timingReadFailed:
                return .failure(.probingFailed(url: fileURL, reason: error.description))
            }
        } catch {
            return .failure(
                .probingFailed(url: fileURL, reason: String(describing: error))
            )
        }
    }

    private func contentHashResult(
        for fileURL: URL
    ) -> Result<ContentHash, MediaImportError> {
        do {
            return .success(try hasher.contentHash(of: fileURL))
        } catch {
            return .failure(
                .hashingFailed(url: fileURL, reason: String(describing: error))
            )
        }
    }

    private func bookmarkResult(for fileURL: URL) -> Result<Data, MediaImportError> {
        do {
            return .success(try bookmarkStore.createBookmark(for: fileURL))
        } catch {
            return .failure(
                .bookmarkCreationFailed(url: fileURL, reason: String(describing: error))
            )
        }
    }

    private func failedResult(
        for fileURL: URL,
        error: MediaImportError
    ) -> PreparedFileResult {
        .failed(FailedMediaImportItem(sourceURL: fileURL, error: error))
    }

    private func discoverFiles(from selectedURLs: [URL]) -> FileDiscoveryResult {
        var files: [URL] = []
        var failures: [FailedMediaImportItem] = []
        var seenPaths = Set<String>()

        for url in selectedURLs {
            guard url.isFileURL else {
                failures.append(
                    FailedMediaImportItem(
                        sourceURL: url,
                        error: .sourceMustBeFileURL(url)
                    )
                )
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  fileManager.isReadableFile(atPath: url.path) else {
                failures.append(
                    FailedMediaImportItem(sourceURL: url, error: .sourceUnavailable(url))
                )
                continue
            }

            if isDirectory.boolValue {
                let folderResult = recursivelyEnumerate(folderURL: url)
                failures.append(contentsOf: folderResult.failures)
                for candidate in folderResult.files {
                    appendUnique(candidate, to: &files, seenPaths: &seenPaths)
                }
            } else {
                appendUnique(url, to: &files, seenPaths: &seenPaths)
            }
        }
        return FileDiscoveryResult(files: files, failures: failures)
    }

    private func recursivelyEnumerate(folderURL: URL) -> FileDiscoveryResult {
        var enumerationFailure: FailedMediaImportItem?
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                if enumerationFailure == nil {
                    enumerationFailure = FailedMediaImportItem(
                        sourceURL: url,
                        error: .folderEnumerationFailed(
                            url: folderURL,
                            reason: String(describing: error)
                        )
                    )
                }
                return true
            }
        ) else {
            return FileDiscoveryResult(
                files: [],
                failures: [
                    FailedMediaImportItem(
                        sourceURL: folderURL,
                        error: .folderEnumerationFailed(
                            url: folderURL,
                            reason: "could not create a recursive directory enumerator"
                        )
                    )
                ]
            )
        }

        var files: [URL] = []
        for case let candidate as URL in enumerator {
            let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(candidate)
            }
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return FileDiscoveryResult(
            files: files,
            failures: enumerationFailure.map { [$0] } ?? []
        )
    }

    private func appendUnique(
        _ url: URL,
        to files: inout [URL],
        seenPaths: inout Set<String>
    ) {
        let normalizedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        if seenPaths.insert(normalizedPath).inserted {
            files.append(url)
        }
    }
}

private enum PreparedFileResult {
    case imported(ImportedMediaItem)
    case duplicate(SkippedDuplicateMediaItem)
    case failed(FailedMediaImportItem)
}

private struct FileDiscoveryResult {
    let files: [URL]
    let failures: [FailedMediaImportItem]
}

private struct MediaImportAccumulator {
    private(set) var imported: [ImportedMediaItem] = []
    private(set) var skipped: [SkippedDuplicateMediaItem] = []
    private(set) var conformed: [ConformedVariableFrameRateItem] = []
    private(set) var failed: [FailedMediaImportItem]
    private(set) var referenceByHash: [ContentHash: MediaRef]

    init(existingMedia: [MediaRef], discoveryFailures: [FailedMediaImportItem]) {
        failed = discoveryFailures
        referenceByHash = Dictionary(
            existingMedia.compactMap { reference in
                reference.contentHash.map { ($0, reference) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    mutating func record(_ result: PreparedFileResult, sourceURL: URL) {
        switch result {
        case .imported(let item):
            imported.append(item)
            if let hash = item.mediaReference.contentHash {
                referenceByHash[hash] = item.mediaReference
            }
            recordConformIfNeeded(item.mediaReference, sourceURL: sourceURL)
        case .duplicate(let item):
            skipped.append(item)
        case .failed(let item):
            failed.append(item)
        }
    }

    var preparedBatch: PreparedMediaImportBatch {
        let summary = MediaImportSummary(
            imported: imported,
            skippedDuplicates: skipped,
            vfrConformed: conformed,
            failed: failed
        )
        let command = imported.isEmpty
            ? nil
            : EditCommand.addMediaReferences(imported.map(\.mediaReference))
        return PreparedMediaImportBatch(command: command, summary: summary)
    }

    private mutating func recordConformIfNeeded(
        _ reference: MediaRef,
        sourceURL: URL
    ) {
        guard reference.metadata.isVariableFrameRate,
              let stableRate = reference.metadata.conformedFrameRate else {
            return
        }
        conformed.append(
            ConformedVariableFrameRateItem(
                sourceURL: sourceURL,
                sourceFrameRate: reference.metadata.frameRate,
                conformedFrameRate: stableRate
            )
        )
    }
}

// swiftlint:enable file_length
