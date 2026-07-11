// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarIssue246AppModelTests: XCTestCase {
    // MARK: - FR-PROJ-003 auto-detect

    func testFRPROJ003DetectorVideoProposesResolutionFPSColorAndAudio() throws {
        let current = try EditorAjarNewProjectSettings.sensibleDefaults.makeProjectSettings()
        let media = try makeMedia(
            codec: "h264",
            dimensions: PixelDimensions(width: 3_840, height: 2_160),
            frameRate: try FrameRate(frames: 24),
            colorSpace: .displayP3,
            conformed: nil
        )
        let proposed = EditorAjarFirstClipSettingsDetector.detectedSettings(
            from: media,
            current: current,
            detectedAudioSampleRate: 96_000
        )
        XCTAssertEqual(proposed.resolution, PixelDimensions(width: 3_840, height: 2_160))
        XCTAssertEqual(proposed.frameRate, try FrameRate(frames: 24))
        XCTAssertEqual(proposed.colorSpace, .displayP3)
        XCTAssertEqual(proposed.audioSampleRate, 96_000)
    }

    func testFRPROJ003DetectorVFRUsesConformedRateForFPS() throws {
        let current = try EditorAjarNewProjectSettings.sensibleDefaults.makeProjectSettings()
        let conformed = try FrameRate(frames: 30_000, per: 1_001)
        let media = try makeMedia(
            codec: "h264",
            dimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 30),
            colorSpace: .rec709,
            conformed: conformed,
            isVFR: true
        )
        let proposed = EditorAjarFirstClipSettingsDetector.detectedSettings(
            from: media,
            current: current
        )
        XCTAssertEqual(proposed.frameRate, conformed)
    }

    func testFRPROJ003DetectorStillProposesResolutionOnly() throws {
        let current = try EditorAjarNewProjectSettings.sensibleDefaults.makeProjectSettings()
        let media = MediaRef(
            id: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/photo.png"),
            contentHash: ContentHash.sha256(data: Data("still".utf8)),
            metadata: MediaMetadata(
                codecID: "png",
                pixelDimensions: PixelDimensions(width: 4_000, height: 3_000),
                frameRate: nil,
                duration: try StillMediaDefaults.defaultDuration(),
                colorSpace: .displayP3,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        let proposed = EditorAjarFirstClipSettingsDetector.detectedSettings(
            from: media,
            current: current
        )
        XCTAssertEqual(proposed.resolution, PixelDimensions(width: 4_000, height: 3_000))
        XCTAssertEqual(proposed.frameRate, current.frameRate)
        XCTAssertEqual(proposed.colorSpace, current.colorSpace)
        XCTAssertEqual(proposed.audioSampleRate, current.audioSampleRate)
    }

    func testFRPROJ003DetectorAudioOnlyKeepsResolutionUsesAudioRateWhenProvided() throws {
        let current = try EditorAjarNewProjectSettings.sensibleDefaults.makeProjectSettings()
        let media = MediaRef(
            id: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/voice.wav"),
            contentHash: ContentHash.sha256(data: Data("audio".utf8)),
            metadata: MediaMetadata(
                codecID: "pcm",
                pixelDimensions: nil,
                frameRate: nil,
                duration: try RationalTime(value: 10, timescale: 1),
                colorSpace: .unspecified,
                audioChannelLayout: AudioChannelLayout(channelCount: 2),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        let proposed = EditorAjarFirstClipSettingsDetector.detectedSettings(
            from: media,
            current: current,
            detectedAudioSampleRate: 44_100
        )
        XCTAssertEqual(proposed.resolution, current.resolution)
        XCTAssertEqual(proposed.frameRate, current.frameRate)
        XCTAssertEqual(proposed.audioSampleRate, 44_100)
    }

    func testFRPROJ003ImportPresentsProposalApplyIsUndoable() async throws {
        let root = try temporaryDirectory(named: "first-settings-apply")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("first.mov")
        try Data("first-clip-bytes".utf8).write(to: sourceURL)
        let metadata = MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_280, height: 720),
            frameRate: try FrameRate(frames: 24),
            duration: try RationalTime(value: 3, timescale: 1),
            colorSpace: .displayP3,
            audioChannelLayout: AudioChannelLayout(channelCount: 2),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
        let pipeline = MediaImportPipeline(
            probe: Issue246ImportProbe(
                result: MediaProbeResult(metadata: metadata, audioSampleRate: 96_000)
            ),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: Issue246ImportBookmarkStore()
        )
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaImportPipeline: pipeline
        )
        try model.createNewProject(settings: .sensibleDefaults)
        let before = try XCTUnwrap(model.project?.settings)

        await model.importMediaAndWait(from: [sourceURL])

        // H1: summary first; proposal only after summary dismiss (not both sheets at once).
        XCTAssertTrue(model.isMediaImportSummaryPresented)
        XCTAssertFalse(model.isFirstMediaSettingsProposalPresented)
        let proposedWhileSummary = try XCTUnwrap(model.proposedFirstMediaSettings)
        XCTAssertEqual(proposedWhileSummary.resolution, PixelDimensions(width: 1_280, height: 720))
        XCTAssertEqual(proposedWhileSummary.frameRate, try FrameRate(frames: 24))
        XCTAssertEqual(proposedWhileSummary.colorSpace, .displayP3)
        XCTAssertEqual(proposedWhileSummary.audioSampleRate, 96_000)
        // Import lands media but does not silently apply settings.
        XCTAssertEqual(model.project?.settings.resolution, before.resolution)

        model.dismissMediaImportSummary()
        XCTAssertFalse(model.isMediaImportSummaryPresented)
        XCTAssertTrue(model.isFirstMediaSettingsProposalPresented)
        let proposed = try XCTUnwrap(model.proposedFirstMediaSettings)

        model.applyProposedFirstMediaSettings()
        XCTAssertEqual(model.project?.settings.resolution, proposed.resolution)
        XCTAssertEqual(model.project?.settings.frameRate, proposed.frameRate)
        XCTAssertEqual(model.project?.settings.audioSampleRate, 96_000)
        XCTAssertFalse(model.isFirstMediaSettingsProposalPresented)

        model.undo()
        XCTAssertEqual(model.project?.settings.resolution, before.resolution)
    }

    func testFRPROJ003ImportDeclineKeepsSettings() async throws {
        let root = try temporaryDirectory(named: "first-settings-decline")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("still.png")
        try Self.minimalPNGData.write(to: sourceURL)
        let pipeline = MediaImportPipeline(
            probe: AVFoundationMediaProbe(),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: Issue246ImportBookmarkStore()
        )
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaImportPipeline: pipeline
        )
        try model.createNewProject(settings: .sensibleDefaults)
        let before = try XCTUnwrap(model.project?.settings)

        await model.importMediaAndWait(from: [sourceURL])

        // 1×1 still differs from Full HD — proposal is pending behind the summary sheet.
        XCTAssertTrue(model.isMediaImportSummaryPresented)
        XCTAssertFalse(model.isFirstMediaSettingsProposalPresented)
        model.dismissMediaImportSummary()
        XCTAssertTrue(model.isFirstMediaSettingsProposalPresented)
        model.declineProposedFirstMediaSettings()
        XCTAssertEqual(model.project?.settings, before)
        XCTAssertFalse(model.isFirstMediaSettingsProposalPresented)
    }

    // MARK: - FR-MED-002 still on timeline

    func testFRMED002StillImportInsertsFiveSecondClip() async throws {
        let root = try temporaryDirectory(named: "still-timeline")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("photo.png")
        try Self.minimalPNGData.write(to: sourceURL)
        let pipeline = MediaImportPipeline(
            probe: AVFoundationMediaProbe(),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: Issue246ImportBookmarkStore()
        )
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaImportPipeline: pipeline
        )
        try model.createNewProject(settings: .sensibleDefaults)
        await model.importMediaAndWait(from: [sourceURL])
        model.dismissMediaImportSummary()
        if model.isFirstMediaSettingsProposalPresented {
            model.declineProposedFirstMediaSettings()
        }
        let media = try XCTUnwrap(model.project?.mediaPool.last)
        XCTAssertEqual(media.metadata.codecID, "png")
        // Source extent is unbounded (24h); placement is still 5s.
        XCTAssertEqual(media.metadata.duration, try StillMediaDefaults.sourceExtentDuration())
        XCTAssertTrue(model.insertMediaOnTimeline(mediaID: media.id))
        let clip = try XCTUnwrap(
            model.activeSequence?.videoTracks.first?.items.compactMap { item -> Clip? in
                if case .clip(let clip) = item { return clip }
                return nil
            }.last
        )
        XCTAssertEqual(clip.timelineRange.duration, try StillMediaDefaults.defaultDuration())
        XCTAssertEqual(clip.sourceRange.duration, try StillMediaDefaults.defaultDuration())
    }

    func testFRMED002StillTrimExtendPastFiveSeconds() async throws {
        let root = try temporaryDirectory(named: "still-extend")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("photo.png")
        try Self.minimalPNGData.write(to: sourceURL)
        let pipeline = MediaImportPipeline(
            probe: AVFoundationMediaProbe(),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: Issue246ImportBookmarkStore()
        )
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaImportPipeline: pipeline
        )
        try model.createNewProject(settings: .sensibleDefaults)
        await model.importMediaAndWait(from: [sourceURL])
        model.dismissMediaImportSummary()
        if model.isFirstMediaSettingsProposalPresented {
            model.declineProposedFirstMediaSettings()
        }
        let media = try XCTUnwrap(model.project?.mediaPool.last)
        XCTAssertTrue(model.insertMediaOnTimeline(mediaID: media.id))
        let sequence = try XCTUnwrap(model.activeSequence)
        let clip = try XCTUnwrap(
            sequence.videoTracks.first?.items.compactMap { item -> Clip? in
                if case .clip(let clip) = item { return clip }
                return nil
            }.last
        )
        model.selectClip(trackID: sequence.videoTracks[0].id, clipID: clip.id, mode: .replace)

        // Extend past the 5 s default placement (source extent is 24h).
        let timebase = sequence.timebase
        let tenSeconds = try RationalTime(value: 10, timescale: 1)
        let durationFrames = try tenSeconds.frameIndex(at: timebase, rounding: .towardZero)
        XCTAssertGreaterThan(durationFrames, 0)
        XCTAssertTrue(
            model.trimSelectedClip(
                sourceStartFrame: 0,
                timelineStartFrame: 0,
                durationFrames: durationFrames
            )
        )
        let extended = try XCTUnwrap(
            model.activeSequence?.videoTracks.first?.items.compactMap { item -> Clip? in
                if case .clip(let clip) = item { return clip }
                return nil
            }.last
        )
        XCTAssertEqual(
            extended.timelineRange.duration,
            try timebase.duration(ofFrames: durationFrames)
        )
        XCTAssertGreaterThan(
            extended.timelineRange.duration,
            try StillMediaDefaults.defaultDuration()
        )
    }

    // MARK: - FR-MED-007 relink UI completion

    func testFRMED007MismatchSurfacesOverridePath() async throws {
        let root = try temporaryDirectory(named: "relink-mismatch-ui")
        defer { try? FileManager.default.removeItem(at: root) }
        let originalBytes = Data("original media bytes".utf8)
        let originalURL = root.appendingPathComponent("clip.mov")
        try originalBytes.write(to: originalURL)
        let mismatchURL = root.appendingPathComponent("other.mov")
        try Data("different media bytes".utf8).write(to: mismatchURL)

        let media = MediaRef(
            id: UUID(),
            sourceURL: originalURL,
            contentHash: ContentHash.sha256(data: originalBytes),
            metadata: try constantVideoMetadata(),
            availability: .offline
        )
        let model = try installProject(with: [media], packageRoot: root)
        model.presentRelinker(for: media.id)
        model.handleRelinkerResult(.success(mismatchURL))
        try await waitUntil { model.pendingRelinkMismatch != nil }
        XCTAssertEqual(model.pendingRelinkMismatch?.mediaID, media.id)
        XCTAssertEqual(model.pendingRelinkMismatch?.candidateURL, mismatchURL)

        model.overridePendingRelinkMismatch()
        try await waitUntil {
            model.project?.mediaPool.first(where: { $0.id == media.id })?.isOffline == false
                && model.pendingRelinkMismatch == nil
        }
        let relinked = try XCTUnwrap(model.project?.mediaPool.first(where: { $0.id == media.id }))
        XCTAssertEqual(relinked.sourceURL, mismatchURL)
        XCTAssertFalse(relinked.isOffline)
    }

    func testFRMED007BatchRelinkSummaryCounts() throws {
        let root = try temporaryDirectory(named: "batch-relink-ui")
        defer { try? FileManager.default.removeItem(at: root) }
        let matchBytes = Data("batch-match".utf8)
        let offlineURL = root.appendingPathComponent("missing/clip.mov")
        try FileManager.default.createDirectory(
            at: offlineURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let foundURL = root.appendingPathComponent("found/clip.mov")
        try FileManager.default.createDirectory(
            at: foundURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try matchBytes.write(to: foundURL)
        let unmatchedBytes = Data("unmatched-offline".utf8)
        let unmatchedURL = root.appendingPathComponent("missing/other.mov")
        let mediaMatch = MediaRef(
            id: UUID(),
            sourceURL: offlineURL,
            contentHash: ContentHash.sha256(data: matchBytes),
            metadata: try constantVideoMetadata(),
            availability: .offline
        )
        let mediaUnmatched = MediaRef(
            id: UUID(),
            sourceURL: unmatchedURL,
            contentHash: ContentHash.sha256(data: unmatchedBytes),
            metadata: try constantVideoMetadata(),
            availability: .offline
        )
        let model = try installProject(with: [mediaMatch, mediaUnmatched], packageRoot: root)
        model.handleBatchRelinkerResult(.success([root.appendingPathComponent("found")]))
        let summary = try XCTUnwrap(model.batchRelinkSummary)
        XCTAssertTrue(model.isBatchRelinkSummaryPresented)
        XCTAssertEqual(summary.relinkedMediaIDs, [mediaMatch.id])
        XCTAssertEqual(summary.unresolvedMediaIDs, [mediaUnmatched.id])
        XCTAssertEqual(
            model.project?.mediaPool.first(where: { $0.id == mediaMatch.id })?.isOffline,
            false
        )
    }

    func testFRMED007RetranscodeMissingFFmpegSurfacesGuidance() async throws {
        let guidance = SystemFFmpegImportTranscoder.installGuidance
        let message = AppString.mediaRelinkFailureMessage(
            for: .retranscodeFailed(.ffmpegUnavailable(guidance: guidance))
        )
        XCTAssertEqual(message, guidance)

        let root = try temporaryDirectory(named: "relink-retranscode-ui")
        defer { try? FileManager.default.removeItem(at: root) }
        let originalBytes = Data("fallback original bytes".utf8)
        let originalURL = root.appendingPathComponent("source.mkv")
        try originalBytes.write(to: originalURL)
        let hash = ContentHash.sha256(data: originalBytes)
        let media = MediaRef(
            id: UUID(),
            sourceURL: root.appendingPathComponent("transcodes/old.mov"),
            contentHash: hash,
            metadata: try constantVideoMetadata(),
            availability: .offline,
            transcodeProvenance: MediaTranscodeProvenance(
                originalSourceURL: root.appendingPathComponent("old-original.mkv"),
                originalContentHash: hash
            )
        )
        let workflow = MediaRelinkCommand(
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: Issue246ImportBookmarkStore(),
            ffmpegTranscoder: Issue246UnavailableFFmpegTranscoder()
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: try EditorAjarNewProjectSettings.sensibleDefaults.makeProjectSettings(),
            mediaPool: [media],
            sequences: []
        )
        do {
            _ = try await workflow.prepare(
                mediaReferenceID: media.id,
                newFileURL: originalURL,
                in: project,
                projectPackageURL: root,
                mismatchPolicy: .warn
            )
            XCTFail("expected retranscode failure")
        } catch let error as MediaRelinkCommandError {
            let ui = AppString.mediaRelinkFailureMessage(for: error)
            XCTAssertFalse(ui.isEmpty)
            XCTAssertEqual(project.mediaPool.first, media)
        }
    }

    // MARK: - Helpers

    private static let minimalPNGData = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5W3qUAAAAASUVORK5CYII="
    )!

    private func makeMedia(
        codec: String,
        dimensions: PixelDimensions?,
        frameRate: FrameRate?,
        colorSpace: MediaColorSpace,
        conformed: FrameRate?,
        isVFR: Bool = false
    ) throws -> MediaRef {
        MediaRef(
            id: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/\(codec).mov"),
            contentHash: ContentHash.sha256(data: Data(codec.utf8)),
            metadata: MediaMetadata(
                codecID: codec,
                pixelDimensions: dimensions,
                frameRate: frameRate,
                duration: try RationalTime(value: 5, timescale: 1),
                colorSpace: colorSpace,
                audioChannelLayout: AudioChannelLayout(channelCount: 2),
                isVariableFrameRate: isVFR,
                conformedFrameRate: conformed
            )
        )
    }

    private func constantVideoMetadata() throws -> MediaMetadata {
        MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_280, height: 720),
            frameRate: try FrameRate(frames: 30),
            duration: try RationalTime(value: 3, timescale: 1),
            colorSpace: .rec709,
            audioChannelLayout: AudioChannelLayout(channelCount: 2),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    }

    private func installProject(with media: [MediaRef], packageRoot: URL) throws -> EditorAjarAppModel {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        try model.createNewProject(settings: .sensibleDefaults)
        XCTAssertTrue(model.applyEditForTesting(.addMediaReferences(media)))
        if let current = model.project {
            let offline = current.updatingMediaAvailability(.offline, for: Set(media.map(\.id)))
            model.replaceProjectPreservingHistoryForTesting(offline)
        }
        model.setProjectPackageRootForTesting(packageRoot)
        return model
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-246-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}

private struct Issue246ImportProbe: MediaProbing {
    let result: MediaProbeResult

    func probe(_ sourceURL: URL) async throws -> MediaProbeResult {
        result
    }
}

private struct Issue246ImportBookmarkStore: MediaBookmarkStore {
    func createBookmark(for url: URL) throws -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8) else {
            throw MediaBookmarkError.resolutionFailed(reason: "invalid test bookmark")
        }
        return MediaBookmarkResolution(url: URL(fileURLWithPath: path), isStale: false)
    }
}

private struct Issue246UnavailableFFmpegTranscoder: FFmpegImportTranscoding {
    func transcode(
        sourceURL: URL,
        originalHash: ContentHash,
        projectPackageURL: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> FFmpegTranscodeResult {
        throw FFmpegTranscodeError.ffmpegUnavailable(
            guidance: SystemFFmpegImportTranscoder.installGuidance
        )
    }
}
