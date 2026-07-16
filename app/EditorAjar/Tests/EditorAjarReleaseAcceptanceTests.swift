// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarExport
import AjarMedia
import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Metal
import XCTest

@testable import EditorAjar

/// End-to-end usable-app acceptance gate (#236): walks the real user journey through
/// `EditorAjarAppModel` APIs so CI can prove create → import → edit → compound open/edit/return →
/// save/reopen → export → decompose/undo.
///
/// Runs in the `EditorAjarTests` target (ui-smoke app-test step). ProRes export is CI-hard;
/// H.264 is capability-skipped when hardware encode is unavailable.
@MainActor
final class EditorAjarReleaseAcceptanceTests: XCTestCase {
    private let syntheticWidth = 64
    private let syntheticHeight = 64
    private let syntheticFrameCount = 15
    private let syntheticFrameRate: Int32 = 30

    /// Full journey: project → import (video + still + audio) → timeline edits → compound
    /// make/open/edit/return → save/reopen → ProRes export → decompose/undo.
    ///
    /// Nested rendering makes this intentionally broader journey exceed Xcode's 60-second default
    /// on some supported Macs. CI already caps app tests at 120 seconds, so opt this case into that
    /// existing ceiling instead of letting XCTest terminate a healthy export halfway through.
    func testReleaseAcceptanceEndToEndUserJourney() async throws {
        executionTimeAllowance = 120
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on this runner")
        }

        let workspace = try AcceptanceWorkspace()
        defer { workspace.cleanup() }

        let media = try workspace.makeMediaFixtures(
            width: syntheticWidth,
            height: syntheticHeight,
            frameCount: syntheticFrameCount,
            frameRate: syntheticFrameRate
        )
        let model = try makeModel(workspace: workspace)

        try await runCreateImportAndPlace(model: model, media: media)
        try runEditEffectsTitleAndAudio(model: model)
        let compoundJourney = try runCompoundMakeOpenEditAndReturn(model: model)

        let undoBeforeSave = model.editHistory?.undoCount ?? 0
        XCTAssertGreaterThan(
            undoBeforeSave,
            5,
            "journey should have produced multiple undoable edits; count=\(undoBeforeSave)"
        )

        let packageURL = workspace.packageURL(named: "ReleaseAcceptance.ajar")
        try model.saveProjectAs(to: packageURL)
        XCTAssertFalse(model.isDocumentDirty)

        XCTAssertTrue(model.startMediaConsolidation())
        let consolidationCompleted = await waitUntil(timeout: 30) {
            !model.isConsolidatingMedia
        }
        XCTAssertTrue(consolidationCompleted, "media consolidation did not finish in time")
        XCTAssertNil(model.mediaConsolidationError)
        let mediaDirectory = packageURL.appendingPathComponent("media", isDirectory: true)
        XCTAssertTrue(
            try XCTUnwrap(model.project).mediaPool.allSatisfy {
                $0.sourceURL?.deletingLastPathComponent().standardizedFileURL
                    == mediaDirectory.standardizedFileURL
            },
            "every release-acceptance reference should point into the saved package"
        )
        for originalURL in [media.videoURL, media.stillURL, media.audioURL] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: originalURL.path),
                "consolidation must never delete original media"
            )
        }
        try model.saveProject()
        XCTAssertFalse(model.isDocumentDirty)

        let undoBeforePackageSaveAs = model.editHistory?.undoCount
        let copiedPackageURL = workspace.packageURL(named: "ReleaseAcceptanceCopy.ajar")
        try model.saveProjectAs(to: copiedPackageURL)
        XCTAssertEqual(model.editHistory?.undoCount, undoBeforePackageSaveAs)
        XCTAssertTrue(
            try XCTUnwrap(model.project).mediaPool.allSatisfy {
                $0.sourceURL?.deletingLastPathComponent().standardizedFileURL
                    == copiedPackageURL.appendingPathComponent("media").standardizedFileURL
            }
        )
        try assertHistoryRoundTripsAfterSaveAs(
            model.editHistory,
            expectedProject: try XCTUnwrap(model.project)
        )
        for snapshotURL in try EditorAjarDocumentStore(
            bookmarkStore: AcceptanceBookmarkStore()
        ).versionSnapshotURLs(in: copiedPackageURL) {
            let snapshot = try EditorAjarDocumentStore(
                bookmarkStore: AcceptanceBookmarkStore()
            ).revert(at: snapshotURL).project
            XCTAssertTrue(
                snapshot.mediaPool.allSatisfy {
                    $0.sourceURL?.deletingLastPathComponent().standardizedFileURL
                        != packageURL.appendingPathComponent("media").standardizedFileURL
                }
            )
        }
        try FileManager.default.removeItem(at: packageURL)

        let savedProject = try XCTUnwrap(model.project)
        let sequence = try XCTUnwrap(model.activeSequence)
        let expectedExportFrames = try exportFrameCount(for: sequence)

        let reopened = try makeModel(workspace: workspace)
        try reopened.openProject(at: copiedPackageURL)
        XCTAssertEqual(
            reopened.project,
            savedProject,
            "reopened project must equal saved state (full model equality)"
        )
        XCTAssertEqual(reopened.projectOpenMode, .editable)
        XCTAssertFalse(reopened.isDocumentDirty)
        XCTAssertEqual(reopened.project?.mediaPool.count, 3)
        XCTAssertFalse(reopened.canUndo)

        try verifyReopenedCompoundPropagation(
            model: reopened,
            journey: compoundJourney
        )

        let exportURL = workspace.rootURL.appendingPathComponent("acceptance-prores.mov")
        try await runProResExportAndVerify(
            model: reopened,
            exportURL: exportURL,
            expectedFrames: expectedExportFrames,
            expectedResolution: savedProject.settings.resolution
        )
        XCTAssertTrue(reopened.selectSequence(compoundJourney.parentSequenceID))
        reopened.selectClip(
            trackID: compoundJourney.compoundTrackID,
            clipID: compoundJourney.compoundClipID,
            mode: .replace
        )
        let beforeDecompose = reopened.project
        XCTAssertTrue(reopened.decomposeCompoundClip(), "release compound should decompose")
        let existingReferences = Set(
            TimelineInteraction.clipReferences(in: try XCTUnwrap(reopened.activeSequence))
        )
        XCTAssertFalse(reopened.timelineState.selectedClips.isEmpty)
        XCTAssertTrue(reopened.timelineState.selectedClips.isSubset(of: existingReferences))
        reopened.undo()
        XCTAssertEqual(reopened.project, beforeDecompose)
        XCTAssertGreaterThan(undoBeforeSave, 0)
    }

    /// Same journey shape with H.264 export; capability-skipped when hardware encode is absent.
    func testReleaseAcceptanceH264ExportHardwareOnly() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on this runner")
        }

        let workspace = try AcceptanceWorkspace()
        defer { workspace.cleanup() }

        let media = try workspace.makeMediaFixtures(
            width: syntheticWidth,
            height: syntheticHeight,
            frameCount: syntheticFrameCount,
            frameRate: syntheticFrameRate
        )
        let model = try makeModel(workspace: workspace)
        try model.createNewProject(settings: .sensibleDefaults)
        await model.importMediaAndWait(from: [media.videoURL, media.stillURL, media.audioURL])
        let summary = try XCTUnwrap(model.mediaImportSummary)
        XCTAssertEqual(summary.imported.count, 3, "H.264 path import failed: \(summary.failed)")
        model.dismissMediaImportSummary()
        if model.proposedFirstMediaSettings != nil {
            model.applyProposedFirstMediaSettings()
        }

        let pool = try XCTUnwrap(model.project?.mediaPool)
        let videoMedia = try XCTUnwrap(videoMedia(in: pool))
        model.scrub(to: 0)
        XCTAssertTrue(model.insertMediaOnTimeline(mediaID: videoMedia.id))
        model.scrub(to: 0)
        XCTAssertTrue(model.insertTitleAtPlayhead())
        if let title = model.selectedClip {
            let start = try frameCount(
                of: title.timelineRange.start,
                timebase: try XCTUnwrap(model.activeSequence).timebase
            )
            _ = model.trimSelectedClip(
                sourceStartFrame: 0,
                timelineStartFrame: start,
                durationFrames: 10
            )
        }

        let project = try XCTUnwrap(model.project)
        let sequence = try XCTUnwrap(model.activeSequence)
        let duration = try sequence.timelineDuration()
        let range = try TimeRange(start: .zero, duration: duration)
        let expectedFrames = try exportFrameCount(for: sequence)
        let exportURL = workspace.rootURL.appendingPathComponent("acceptance-h264.mp4")

        // Model-API gap: dialog preset selection has no enqueue path. H.264 uses the queue
        // controller with project-sized H.264 settings (YouTube preset shape, local canvas).
        let h264Settings = try makeH264Settings(for: project)
        do {
            _ = try await model.exportQueueController.enqueueExport(
                project: project,
                sequenceID: sequence.id,
                range: range,
                destinationURL: exportURL,
                settings: h264Settings,
                displayName: "acceptance-h264"
            )
        } catch let error as ExportError where error.isHardwareEncoderUnavailable(for: .h264) {
            throw XCTSkip("H.264 hardware encoder unavailable: \(error)")
        } catch {
            model.exportQueueController.presentError(error)
        }

        try await waitForTerminalExport(model: model, timeout: 90)
        let job = try XCTUnwrap(model.exportQueueController.jobs.first)
        if job.state == .failed, let failure = job.failure {
            if failure.isHardwareEncoderUnavailable(for: .h264) {
                throw XCTSkip("H.264 hardware encoder unavailable at encode: \(failure)")
            }
            return XCTFail("H.264 export failed: \(failure)")
        }
        XCTAssertEqual(job.state, .done)

        let frames = try await ExportMovieDecoder.decodeBGRA8Frames(from: exportURL)
        XCTAssertEqual(frames.count, Int(expectedFrames))
        assertNonTrivialContent(frames)
    }

    // MARK: - Journey steps

    private func makeModel(workspace: AcceptanceWorkspace) throws -> EditorAjarAppModel {
        let bookmarkStore = AcceptanceBookmarkStore()
        let pipeline = MediaImportPipeline(
            probe: AcceptanceImportProbe(
                audioResult: try audioOnlyProbeResult(frameCount: syntheticFrameCount)
            ),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: bookmarkStore
        )
        let consolidationRunner = EditorAjarDefaultMediaConsolidationRunner { request in
            try MediaConsolidateCommand(bookmarkStore: bookmarkStore).prepare(
                project: request.project,
                openMode: request.openMode,
                projectPackageURL: request.packageURL,
                progress: AcceptanceConsolidationProgress(request.progress),
                isCancelled: request.isCancelled
            )
        }
        return EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            mediaImportPipeline: pipeline,
            mediaConsolidationRunner: consolidationRunner,
            documentStore: EditorAjarDocumentStore(bookmarkStore: bookmarkStore),
            recentProjectsUserDefaults: workspace.userDefaults,
            recentProjectsStorageKey: workspace.recentProjectsStorageKey
        )
    }

    private func runCreateImportAndPlace(
        model: EditorAjarAppModel,
        media: AcceptanceWorkspace.MediaFixtures
    ) async throws {
        try model.createNewProject(settings: .sensibleDefaults)
        let defaults = try EditorAjarNewProjectSettings.sensibleDefaults.makeProjectSettings()
        XCTAssertEqual(model.project?.settings.resolution, defaults.resolution)
        XCTAssertEqual(model.project?.settings.frameRate, defaults.frameRate)
        XCTAssertEqual(model.project?.settings.colorSpace, defaults.colorSpace)
        XCTAssertEqual(model.project?.settings.audioSampleRate, defaults.audioSampleRate)
        XCTAssertTrue(model.project?.mediaPool.isEmpty == true)
        XCTAssertTrue(model.isDocumentDirty)

        await model.importMediaAndWait(from: [media.videoURL, media.stillURL, media.audioURL])
        if let error = model.mediaImportError {
            return XCTFail("import refused: \(error)")
        }
        let summary = try XCTUnwrap(model.mediaImportSummary, "import summary missing")
        XCTAssertEqual(
            summary.imported.count,
            3,
            "expected 3 imports; failed=\(summary.failed) skipped=\(summary.skippedDuplicates)"
        )
        XCTAssertTrue(summary.failed.isEmpty, "import failures: \(summary.failed)")
        XCTAssertEqual(model.project?.mediaPool.count, 3)
        model.dismissMediaImportSummary()

        if model.proposedFirstMediaSettings != nil {
            XCTAssertTrue(
                model.isFirstMediaSettingsProposalPresented,
                "summary dismiss should present the first-media settings proposal"
            )
            model.applyProposedFirstMediaSettings()
            XCTAssertEqual(
                model.project?.settings.resolution,
                PixelDimensions(width: syntheticWidth, height: syntheticHeight)
            )
        }

        let pool = try XCTUnwrap(model.project?.mediaPool)
        let videoMedia = try XCTUnwrap(videoMedia(in: pool), "missing video media in pool")
        let stillMedia = try XCTUnwrap(stillMedia(in: pool), "missing still media in pool")
        let audioMedia = try XCTUnwrap(audioMedia(in: pool), "missing audio media in pool")

        model.scrub(to: 0)
        XCTAssertTrue(
            model.insertMediaOnTimeline(mediaID: videoMedia.id),
            "insert video refused (typed refusal is a failure for this journey)"
        )
        let videoClip = try firstClip(in: model, matching: { $0.kind == .video })
        model.selectClip(trackID: videoClip.trackID, clipID: videoClip.clip.id, mode: .replace)
        XCTAssertTrue(
            model.moveSelectedClip(toStartFrame: 0),
            "drag-equivalent move of video clip refused"
        )

        let videoDurationFrames = try frameCount(
            of: videoClip.clip.timelineRange.duration,
            timebase: try XCTUnwrap(model.activeSequence).timebase
        )
        let bladeFrame = max(1, videoDurationFrames / 2)
        model.scrub(to: bladeFrame)
        XCTAssertTrue(
            model.bladeSelectedClipAtPlayhead(),
            "blade refused at frame \(bladeFrame)"
        )
        let videoTrackAfterBlade = try XCTUnwrap(
            model.activeSequence?.videoTracks.first(where: { $0.id == videoClip.trackID })
        )
        let videoClipsAfterBlade = videoTrackAfterBlade.items.compactMap { item -> Clip? in
            guard case .clip(let clip) = item, clip.kind == .video else { return nil }
            return clip
        }
        XCTAssertGreaterThanOrEqual(
            videoClipsAfterBlade.count,
            2,
            "blade should produce two video pieces"
        )
        // Stash for the edit step (left piece after blade).
        model.selectClip(
            trackID: videoClip.trackID,
            clipID: try XCTUnwrap(
                videoClipsAfterBlade.min {
                    $0.timelineRange.start < $1.timelineRange.start
                }
            ).id,
            mode: .replace
        )

        let stillStart = try sequenceEndFrame(model)
        model.scrub(to: stillStart)
        XCTAssertTrue(model.insertMediaOnTimeline(mediaID: stillMedia.id), "insert still refused")
        let stillClip = try firstClip(in: model) { clip in
            guard case .media(let id) = clip.source else { return false }
            return id == stillMedia.id
        }
        model.selectClip(trackID: stillClip.trackID, clipID: stillClip.clip.id, mode: .replace)
        XCTAssertTrue(
            model.trimSelectedClip(
                sourceStartFrame: 0,
                timelineStartFrame: stillStart,
                durationFrames: 10
            ),
            "trim still refused"
        )

        model.scrub(to: 0)
        XCTAssertTrue(model.insertMediaOnTimeline(mediaID: audioMedia.id), "insert audio refused")
    }

    private func runEditEffectsTitleAndAudio(model: EditorAjarAppModel) throws {
        // Left video piece should already be selected from placement; re-select if needed.
        if model.selectedClip?.kind != .video {
            let video = try firstClip(in: model, matching: { $0.kind == .video })
            model.selectClip(trackID: video.trackID, clipID: video.clip.id, mode: .replace)
        }

        XCTAssertTrue(
            model.addEffectToSelectedClip(kind: .gaussianBlur),
            "add gaussian blur refused"
        )
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.count, 1)
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.first?.kind, .gaussianBlur)
        XCTAssertTrue(
            model.setSelectedColorScalar(.exposure, doubleValue: 0.8, coalesce: false),
            "set color exposure refused"
        )
        XCTAssertEqual(
            model.selectedColorInspector?.correction.exposure.doubleValue ?? 0,
            0.8,
            accuracy: 0.001
        )

        model.scrub(to: 0)
        XCTAssertTrue(model.insertTitleAtPlayhead(), "insert title refused")
        guard case .title = model.selectedClip?.source else {
            return XCTFail("expected title selection after insert")
        }
        XCTAssertTrue(model.setSelectedTitleFontWeight(.bold), "title bold refused")
        XCTAssertTrue(
            model.setSelectedTitleScalar(.fontSize, doubleValue: 48, coalesce: false),
            "title font size refused"
        )
        XCTAssertEqual(model.selectedTitleInspector?.selectedBox?.style.fontWeight, .bold)
        XCTAssertEqual(
            model.selectedTitleInspector?.selectedBox?.style.fontSize.doubleValue ?? 0,
            48,
            accuracy: 0.01
        )
        if let title = model.selectedClip {
            let titleStart = try frameCount(
                of: title.timelineRange.start,
                timebase: try XCTUnwrap(model.activeSequence).timebase
            )
            XCTAssertTrue(
                model.trimSelectedClip(
                    sourceStartFrame: 0,
                    timelineStartFrame: titleStart,
                    durationFrames: 12
                ),
                "trim title refused"
            )
        }

        let audioClip = try firstClip(in: model, matching: { $0.kind == .audio })
        model.selectClip(trackID: audioClip.trackID, clipID: audioClip.clip.id, mode: .replace)
        XCTAssertTrue(
            model.applyDefaultFadeInToSelectedAudioClip(),
            "default audio fade-in refused"
        )
        XCTAssertNotNil(model.selectedClip?.audioMix.fadeIn)
    }

    private struct CompoundAcceptanceJourney {
        let parentSequenceID: UUID
        let nestedSequenceID: UUID
        let compoundTrackID: UUID
        let compoundClipID: UUID
        let innerClipID: UUID
    }

    private func runCompoundMakeOpenEditAndReturn(
        model: EditorAjarAppModel
    ) throws -> CompoundAcceptanceJourney {
        let parentSequenceID = try XCTUnwrap(model.activeSequenceID)
        let editedVideo = try firstClip(in: model) {
            $0.kind == .video && !$0.effectStack.nodes.isEmpty
        }
        model.selectClip(
            trackID: editedVideo.trackID,
            clipID: editedVideo.clip.id,
            mode: .replace
        )
        XCTAssertTrue(model.makeCompoundClip(), "release make compound refused")
        let compoundTrackID = try XCTUnwrap(model.selectedClipReference?.trackID)
        let compoundClipID = try XCTUnwrap(model.selectedClip?.id)
        guard case .sequence(let nestedSequenceID) = model.selectedClip?.source else {
            XCTFail("release make must select the compound replacement")
            throw AcceptanceFixtureError.clipNotFound
        }

        XCTAssertTrue(model.openCompoundClip(), "release open compound refused")
        XCTAssertEqual(model.activeSequenceID, nestedSequenceID)
        let inner = try firstClip(in: model, matching: { $0.kind == .video })
        XCTAssertEqual(inner.clip.id, editedVideo.clip.id)
        model.selectClip(trackID: inner.trackID, clipID: inner.clip.id, mode: .replace)
        XCTAssertTrue(
            model.updateSelectedTransformField(.positionX, rawValue: "4"),
            "nested edit refused"
        )
        XCTAssertTrue(model.selectSequence(parentSequenceID), "return to parent refused")
        XCTAssertEqual(model.selectedClip?.id, compoundClipID)

        return CompoundAcceptanceJourney(
            parentSequenceID: parentSequenceID,
            nestedSequenceID: nestedSequenceID,
            compoundTrackID: compoundTrackID,
            compoundClipID: compoundClipID,
            innerClipID: inner.clip.id
        )
    }

    private func verifyReopenedCompoundPropagation(
        model: EditorAjarAppModel,
        journey: CompoundAcceptanceJourney
    ) throws {
        XCTAssertTrue(model.selectSequence(journey.parentSequenceID))
        model.selectClip(
            trackID: journey.compoundTrackID,
            clipID: journey.compoundClipID,
            mode: .replace
        )
        XCTAssertTrue(model.openCompoundClip())
        XCTAssertEqual(model.activeSequenceID, journey.nestedSequenceID)
        let inner = try firstClip(in: model) { $0.id == journey.innerClipID }
        XCTAssertEqual(inner.clip.transform.position.x, RationalValue(4))
        XCTAssertTrue(model.selectSequence(journey.parentSequenceID))
        XCTAssertEqual(model.selectedClip?.id, journey.compoundClipID)
    }

    private func runProResExportAndVerify(
        model: EditorAjarAppModel,
        exportURL: URL,
        expectedFrames: Int64,
        expectedResolution: PixelDimensions
    ) async throws {
        model.enqueueActiveSequenceExport(destinationURL: exportURL)
        try await waitForTerminalExport(model: model, timeout: 90)
        let job = try XCTUnwrap(model.exportQueueController.jobs.first)
        if job.state == .failed {
            return XCTFail(
                "ProRes export failed: \(String(describing: job.failure)) "
                    + "status=\(String(describing: model.exportQueueController.statusMessage))"
            )
        }
        XCTAssertEqual(job.state, .done, "expected ProRes job done, got \(job.state)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: exportURL.path),
            "export file missing at \(exportURL.path)"
        )

        let frames = try await ExportMovieDecoder.decodeBGRA8Frames(from: exportURL)
        XCTAssertEqual(
            frames.count,
            Int(expectedFrames),
            "export frame count must match sequence duration"
        )
        let first = try XCTUnwrap(frames.first)
        XCTAssertEqual(first.width, expectedResolution.width)
        XCTAssertEqual(first.height, expectedResolution.height)
        assertNonTrivialContent(frames)
    }

    // MARK: - Assertions / helpers

    private func assertHistoryRoundTripsAfterSaveAs(
        _ savedHistory: EditHistory?,
        expectedProject: Project
    ) throws {
        var history = try XCTUnwrap(savedHistory)
        while history.undo() != nil {}
        while try history.redo() != nil {}
        XCTAssertEqual(history.currentProject, expectedProject)
    }

    private func assertNonTrivialContent(_ frames: [ExportDecodedBGRAFrame]) {
        XCTAssertFalse(frames.isEmpty)
        var maxChannel: UInt8 = 0
        var anyNonBlack = false
        for frame in frames {
            frame.bgra8.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                let pixelCount = frame.width * frame.height
                for pixel in 0..<pixelCount {
                    let blue = base[pixel * 4]
                    let green = base[pixel * 4 + 1]
                    let red = base[pixel * 4 + 2]
                    maxChannel = max(maxChannel, max(red, max(green, blue)))
                    if red > 8 || green > 8 || blue > 8 {
                        anyNonBlack = true
                    }
                }
            }
            if anyNonBlack { break }
        }
        XCTAssertTrue(
            anyNonBlack,
            "export frames are trivially black (maxChannel=\(maxChannel)); expected content"
        )
        XCTAssertGreaterThan(
            maxChannel,
            16,
            "export content too dark to count as non-trivial (maxChannel=\(maxChannel))"
        )
    }

    private func makeH264Settings(for project: Project) throws -> ExportSettings {
        let colorSpace: ExportColorSpace
        switch project.settings.colorSpace {
        case .displayP3:
            colorSpace = .displayP3
        case .rec709, .sRGB, .rec2020, .unspecified, .unknown:
            colorSpace = .rec709
        }
        return try ExportSettings(
            container: .mp4,
            video: ExportVideoSettings(
                codec: .h264,
                resolution: project.settings.resolution,
                frameRate: project.settings.frameRate,
                averageBitRate: 2_000_000,
                colorSpace: colorSpace
            ),
            audio: nil
        )
    }

    private func audioOnlyProbeResult(frameCount: Int) throws -> MediaProbeResult {
        let frameRate = try FrameRate(frames: Int64(syntheticFrameRate))
        let duration = try frameRate.duration(ofFrames: Int64(frameCount))
        return MediaProbeResult(
            metadata: MediaMetadata(
                codecID: "pcm_s16le",
                pixelDimensions: nil,
                frameRate: nil,
                duration: duration,
                colorSpace: .unspecified,
                audioChannelLayout: AjarCore.AudioChannelLayout(
                    channelCount: 2,
                    layoutTag: "stereo"
                ),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            ),
            videoFrameCount: nil,
            audioSampleRate: 48_000
        )
    }

    private struct TrackedClip {
        let trackID: UUID
        let clip: Clip
    }

    private func videoMedia(in pool: [MediaRef]) -> MediaRef? {
        pool.first {
            $0.metadata.pixelDimensions != nil
                && !StillMediaDefaults.isStillCodec($0.metadata.codecID)
        }
    }

    private func stillMedia(in pool: [MediaRef]) -> MediaRef? {
        pool.first {
            StillMediaDefaults.isStillCodec($0.metadata.codecID)
                || $0.sourceURL.map(StillMediaDefaults.isStillImageFile) == true
        }
    }

    private func audioMedia(in pool: [MediaRef]) -> MediaRef? {
        pool.first { $0.metadata.pixelDimensions == nil }
    }

    private func firstClip(
        in model: EditorAjarAppModel,
        matching predicate: (Clip) -> Bool
    ) throws -> TrackedClip {
        let sequence = try XCTUnwrap(model.activeSequence)
        for track in sequence.videoTracks + sequence.audioTracks {
            for item in track.items {
                guard case .clip(let clip) = item, predicate(clip) else { continue }
                return TrackedClip(trackID: track.id, clip: clip)
            }
        }
        XCTFail("expected clip matching predicate was not found on the timeline")
        throw AcceptanceFixtureError.clipNotFound
    }

    private func sequenceEndFrame(_ model: EditorAjarAppModel) throws -> Int64 {
        let sequence = try XCTUnwrap(model.activeSequence)
        return try frameCount(of: try sequence.timelineDuration(), timebase: sequence.timebase)
    }

    private func exportFrameCount(for sequence: Sequence) throws -> Int64 {
        // Match ExportRequest.videoFrameCount rounding so decode counts align.
        try sequence.timelineDuration().frameIndex(at: sequence.timebase, rounding: .up)
    }

    private func frameCount(of time: RationalTime, timebase: FrameRate) throws -> Int64 {
        try time.frameIndex(at: timebase, rounding: .up)
    }

    private func waitForTerminalExport(
        model: EditorAjarAppModel,
        timeout: TimeInterval
    ) async throws {
        let completed = await waitUntil(timeout: timeout) {
            guard let job = model.exportQueueController.jobs.first else { return false }
            switch job.state {
            case .done, .failed, .cancelled:
                return true
            default:
                return false
            }
        }
        XCTAssertTrue(completed, "export did not finish in time")
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(
            by: .milliseconds(Int64(timeout * 1_000))
        )
        while ContinuousClock.now < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }
}

// MARK: - Workspace / media fixtures

private struct AcceptanceWorkspace {
    let rootURL: URL
    let userDefaults: UserDefaults
    let userDefaultsSuiteName: String
    let recentProjectsStorageKey: String

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "editor-ajar-release-acceptance-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        userDefaultsSuiteName = "org.editorajar.release-acceptance.\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: userDefaultsSuiteName))
        recentProjectsStorageKey = "release.acceptance.recent.\(UUID().uuidString)"
    }

    func packageURL(named name: String) -> URL {
        rootURL.appendingPathComponent(name, isDirectory: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }

    struct MediaFixtures {
        let videoURL: URL
        let stillURL: URL
        let audioURL: URL
    }

    func makeMediaFixtures(
        width: Int,
        height: Int,
        frameCount: Int,
        frameRate: Int32
    ) throws -> MediaFixtures {
        let videoURL = rootURL.appendingPathComponent("acceptance-video.mov")
        let stillURL = rootURL.appendingPathComponent("acceptance-still.png")
        let audioURL = rootURL.appendingPathComponent("acceptance-audio.wav")
        try AcceptanceSyntheticProResWriter.writeMovie(
            to: videoURL,
            width: width,
            height: height,
            frameCount: frameCount,
            frameRate: frameRate
        )
        try AcceptanceStillWriter.writeSolidPNG(
            to: stillURL,
            size: PixelDimensions(width: width, height: height),
            red: 220,
            green: 80,
            blue: 40
        )
        // Audio is probe-injected; bytes only need to exist and hash stably.
        try Data("editor-ajar-release-acceptance-audio".utf8).write(to: audioURL)
        return MediaFixtures(videoURL: videoURL, stillURL: stillURL, audioURL: audioURL)
    }
}

/// Routes still/video to the real native probe; audio-only temp files use an injected result.
private struct AcceptanceImportProbe: MediaProbing {
    let audioResult: MediaProbeResult
    let native = AVFoundationMediaProbe()

    func probe(_ sourceURL: URL) async throws -> MediaProbeResult {
        let ext = sourceURL.pathExtension.lowercased()
        if ext == "wav" || ext == "aif" || ext == "aiff" {
            return audioResult
        }
        return try await native.probe(sourceURL)
    }
}

private struct AcceptanceBookmarkStore: MediaBookmarkStore {
    func createBookmark(for url: URL) throws -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8) else {
            throw MediaBookmarkError.resolutionFailed(reason: "invalid acceptance bookmark")
        }
        return MediaBookmarkResolution(url: URL(fileURLWithPath: path), isStale: false)
    }
}

private final class AcceptanceConsolidationProgress: ConsolidateProgress, @unchecked Sendable {
    private let receive: @Sendable (ConsolidateProgressUpdate) -> Void

    init(_ receive: @escaping @Sendable (ConsolidateProgressUpdate) -> Void) {
        self.receive = receive
    }

    func consolidateDidUpdate(_ progress: ConsolidateProgressUpdate) {
        receive(progress)
    }
}

/// Minimal ProRes 4444 writer (same CI-safe path as the sample project / golden harness).
private enum AcceptanceSyntheticProResWriter {
    static func writeMovie(
        to url: URL,
        width: Int,
        height: Int,
        frameCount: Int,
        frameRate: Int32
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var outputSettings: [String: Any] = [:]
        outputSettings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        outputSettings[AVVideoWidthKey] = width
        outputSettings[AVVideoHeightKey] = height

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(input) else {
            throw AcceptanceFixtureError.cannotAddVideoInput
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw AcceptanceFixtureError.writerFailed(String(describing: writer.error))
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "org.editorajar.release-acceptance.prores")
        let finished = DispatchSemaphore(value: 0)
        var writeError: Error?
        var frameIndex = 0
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData, frameIndex < frameCount {
                do {
                    let buffer = try makePixelBuffer(
                        width: width,
                        height: height,
                        frameIndex: frameIndex
                    )
                    let time = CMTime(value: Int64(frameIndex), timescale: frameRate)
                    guard adaptor.append(buffer, withPresentationTime: time) else {
                        writeError = AcceptanceFixtureError.writerFailed(
                            String(describing: writer.error)
                        )
                        input.markAsFinished()
                        finished.signal()
                        return
                    }
                    frameIndex += 1
                } catch {
                    writeError = error
                    input.markAsFinished()
                    finished.signal()
                    return
                }
            }
            if frameIndex >= frameCount {
                input.markAsFinished()
                finished.signal()
            }
        }
        finished.wait()
        if let writeError {
            throw writeError
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw AcceptanceFixtureError.writerFailed(String(describing: writer.error))
        }
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int,
        frameIndex: Int
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw AcceptanceFixtureError.pixelBufferFailed(status)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw AcceptanceFixtureError.missingBaseAddress
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        let blue = UInt8(40 + (frameIndex * 7) % 80)
        let green = UInt8(160 + (frameIndex * 3) % 40)
        let red = UInt8(20 + (frameIndex * 5) % 30)
        for yPosition in 0..<height {
            for xPosition in 0..<width {
                let offset = yPosition * rowBytes + xPosition * 4
                bytes[offset] = blue
                bytes[offset + 1] = green &+ UInt8(xPosition % 16)
                bytes[offset + 2] = red
                bytes[offset + 3] = 255
            }
        }
        return pixelBuffer
    }
}

private enum AcceptanceStillWriter {
    static func writeSolidPNG(
        to url: URL,
        size: PixelDimensions,
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) throws {
        let width = size.width
        let height = size.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let offset = index * 4
            rgba[offset] = red
            rgba[offset + 1] = green
            rgba[offset + 2] = blue
            rgba[offset + 3] = 255
        }
        let nsData = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: nsData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else {
            throw AcceptanceFixtureError.pngEncodeFailed
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw AcceptanceFixtureError.pngEncodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AcceptanceFixtureError.pngEncodeFailed
        }
    }
}

private enum AcceptanceFixtureError: Error, CustomStringConvertible {
    case cannotAddVideoInput
    case writerFailed(String)
    case pixelBufferFailed(CVReturn)
    case missingBaseAddress
    case pngEncodeFailed
    case clipNotFound

    var description: String {
        switch self {
        case .cannotAddVideoInput:
            "cannot add ProRes video input"
        case .writerFailed(let message):
            "synthetic ProRes writer failed: \(message)"
        case .pixelBufferFailed(let code):
            "pixel buffer create failed: \(code)"
        case .missingBaseAddress:
            "pixel buffer missing base address"
        case .pngEncodeFailed:
            "PNG encode failed"
        case .clipNotFound:
            "timeline clip not found"
        }
    }
}
