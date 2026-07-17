// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import AjarMedia
import AudioToolbox
import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Metal
import XCTest

@testable import AjarExport
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
        let audioDriver = AcceptanceAudioOutputDriver()
        let audioCoordinator = EditorAjarLiveAudioCoordinator(driver: audioDriver)
        let model = try makeModel(
            workspace: workspace,
            audioCoordinator: audioCoordinator
        )

        let muxedMediaID = try await runCreateImportAndPlace(model: model, media: media)
        try runEditEffectsTitleAndAudio(model: model)
        let compoundJourney = try runCompoundMakeOpenEditAndReturn(model: model)
        try await verifyLivePlaybackAndMeters(
            model: model,
            coordinator: audioCoordinator,
            driver: audioDriver
        )

        let undoBeforeSave = model.editHistory?.undoCount ?? 0
        XCTAssertGreaterThan(
            undoBeforeSave,
            5,
            "journey should have produced multiple undoable edits; count=\(undoBeforeSave)"
        )

        let packageURL = workspace.packageURL(named: "ReleaseAcceptance.ajar")
        try model.saveProjectAs(to: packageURL)
        XCTAssertFalse(model.isDocumentDirty)

        // Muxed media needs two independent preview lanes: the browser thumbnail must not
        // suppress the timeline waveform request for the same media id.
        model.requestMediaPreview(forID: muxedMediaID)
        model.ensureTimelineAudioWaveforms()
        let previewsCompleted = await waitUntil(timeout: 30) {
            model.mediaThumbnailData[muxedMediaID] != nil
                && model.mediaWaveformSummary[muxedMediaID] != nil
        }
        XCTAssertTrue(
            previewsCompleted,
            "muxed media did not produce both its thumbnail and audio waveform"
        )

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
        try assertOnlyMuxedMediaSuppliesTimelineAudio(
            project: try XCTUnwrap(reopened.project),
            muxedMediaID: muxedMediaID
        )

        try verifyReopenedCompoundPropagation(
            model: reopened,
            journey: compoundJourney
        )

        let exportURL = workspace.rootURL.appendingPathComponent("acceptance-prores.mov")
        try await runProResExportAndVerify(
            model: reopened,
            exportURL: exportURL,
            expectedFrames: expectedExportFrames,
            expectedResolution: savedProject.settings.resolution,
            expectedAudioSampleRate: savedProject.settings.audioSampleRate,
            expectedAudioMarkerTime: media.muxedAudioMarkerTime
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

    private func makeModel(
        workspace: AcceptanceWorkspace,
        audioCoordinator: (any EditorAjarAudioCoordinating)? = nil
    ) throws -> EditorAjarAppModel {
        let bookmarkStore = AcceptanceBookmarkStore()
        let pipeline = MediaImportPipeline(
            probe: AVFoundationMediaProbe(),
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
            audioCoordinator: audioCoordinator,
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
    ) async throws -> UUID {
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
            XCTFail("import refused: \(error)")
            throw error
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
        XCTAssertNotEqual(videoMedia.id, audioMedia.id)

        // Place the unlinked still while the timeline is empty. Once the muxed fixture is on the
        // timeline, the playhead is intentionally clamped to its final in-range frame; trying to
        // insert a video-only still there would bisect just the video half of a linked A/V pair.
        model.scrub(to: 0)
        XCTAssertTrue(model.insertMediaOnTimeline(mediaID: stillMedia.id), "insert still refused")
        let stillClip = try firstClip(in: model) { clip in
            guard case .media(let id) = clip.source else { return false }
            return id == stillMedia.id
        }
        model.selectClip(trackID: stillClip.trackID, clipID: stillClip.clip.id, mode: .replace)
        XCTAssertTrue(
            model.trimSelectedClip(
                sourceStartFrame: 0,
                timelineStartFrame: 0,
                durationFrames: 10
            ),
            "trim still refused"
        )

        model.scrub(to: 0)
        let beforeMuxedPlacement = model.project
        XCTAssertTrue(
            model.insertMediaOnTimeline(mediaID: videoMedia.id),
            "insert video refused (typed refusal is a failure for this journey)"
        )
        let afterMuxedPlacement = model.project
        let placedVideo = try firstClip(in: model) {
            $0.kind == .video && $0.source == .media(id: videoMedia.id)
        }
        let placedAudio = try firstClip(in: model) {
            $0.kind == .audio && $0.source == .media(id: videoMedia.id)
        }
        let placementGroupID = try XCTUnwrap(
            placedVideo.clip.linkGroupID,
            "muxed placement must assign a link group"
        )
        XCTAssertEqual(placedAudio.clip.linkGroupID, placementGroupID)
        XCTAssertEqual(placedAudio.clip.timelineRange, placedVideo.clip.timelineRange)
        XCTAssertEqual(placedAudio.clip.sourceRange, placedVideo.clip.sourceRange)

        model.undo()
        XCTAssertEqual(
            model.project,
            beforeMuxedPlacement,
            "one undo must remove both halves of the atomic muxed placement"
        )
        model.redo()
        XCTAssertEqual(
            model.project,
            afterMuxedPlacement,
            "one redo must restore the linked A/V pair"
        )

        let videoClip = try firstClip(in: model) {
            $0.kind == .video && $0.source == .media(id: videoMedia.id)
        }
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
        let videoClipsAfterBlade = try mediaClips(
            in: model,
            mediaID: videoMedia.id,
            kind: .video
        )
        let audioClipsAfterBlade = try mediaClips(
            in: model,
            mediaID: videoMedia.id,
            kind: .audio
        )
        XCTAssertEqual(videoClipsAfterBlade.count, 2, "blade should produce two video pieces")
        XCTAssertEqual(
            audioClipsAfterBlade.count, 2, "linked blade should produce two audio pieces")
        for index in videoClipsAfterBlade.indices {
            let videoPiece = videoClipsAfterBlade[index].clip
            let audioPiece = audioClipsAfterBlade[index].clip
            XCTAssertEqual(audioPiece.timelineRange, videoPiece.timelineRange)
            XCTAssertEqual(audioPiece.sourceRange, videoPiece.sourceRange)
            XCTAssertEqual(
                audioPiece.linkGroupID,
                videoPiece.linkGroupID,
                "each bladed A/V half must retain one shared link group"
            )
            XCTAssertNotNil(videoPiece.linkGroupID)
        }
        XCTAssertEqual(
            Set(videoClipsAfterBlade.compactMap(\.clip.linkGroupID)).count,
            2,
            "left and right A/V halves need independent link groups"
        )
        // Stash for the edit step (left piece after blade).
        model.selectClip(
            trackID: videoClipsAfterBlade[0].trackID,
            clipID: videoClipsAfterBlade[0].clip.id,
            mode: .replace
        )
        return videoMedia.id
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

    private func verifyLivePlaybackAndMeters(
        model: EditorAjarAppModel,
        coordinator: EditorAjarLiveAudioCoordinator,
        driver: AcceptanceAudioOutputDriver
    ) async throws {
        model.scrub(to: 0)
        if !model.isMixerPanelVisible {
            model.toggleMixerPanel()
        } else {
            model.refreshMixerMeters()
        }
        let meterFinished = await waitUntil(timeout: 10) {
            !(model.mixerMeterSnapshot?.mixLevels.isEmpty ?? true)
                || model.mixerMeterError != nil
        }
        XCTAssertTrue(meterFinished, "real-media meter preparation did not finish")
        XCTAssertNil(model.mixerMeterError)
        let meter = try XCTUnwrap(model.mixerMeterSnapshot)
        XCTAssertFalse(meter.mixLevels.isEmpty)
        XCTAssertTrue(
            meter.mixLevels.allSatisfy { $0.peak.isFinite && $0.rms.isFinite },
            "meter values must be finite"
        )
        XCTAssertGreaterThan(
            meter.mixLevels.map(\.peak).max() ?? 0,
            0.01,
            "muxed fixture audio must reach the offline meters"
        )

        model.shuttleForward()
        await coordinator.drainPendingRendersForTesting()
        let playbackPublished = await waitUntil(timeout: 10) {
            driver.publishCount > 0 || model.audioPlaybackError != nil
        }
        XCTAssertTrue(playbackPublished, "real-media live playback did not publish a plan")
        XCTAssertNil(model.audioPlaybackError)
        XCTAssertGreaterThan(driver.startCount, 0)
        let samples = driver.lastPublishedSamples
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy(\.isFinite), "live PCM must contain only finite samples")
        XCTAssertTrue(
            samples.contains { abs($0) > 0.01 },
            "muxed fixture audio must reach the live playback plan"
        )
        model.shuttlePause()
    }

    private func assertOnlyMuxedMediaSuppliesTimelineAudio(
        project: Project,
        muxedMediaID: UUID
    ) throws {
        let mediaAudioIDs = project.sequences.flatMap { sequence in
            sequence.audioTracks.flatMap { track in
                track.items.compactMap { item -> UUID? in
                    guard case .clip(let clip) = item,
                        clip.kind == .audio,
                        case .media(let mediaID) = clip.source
                    else {
                        return nil
                    }
                    return mediaID
                }
            }
        }
        XCTAssertFalse(mediaAudioIDs.isEmpty, "journey must retain imported timeline audio")
        XCTAssertEqual(
            Set(mediaAudioIDs),
            Set([muxedMediaID]),
            "standalone audio must not be able to mask a broken muxed-audio path"
        )
    }

    private func runProResExportAndVerify(
        model: EditorAjarAppModel,
        exportURL: URL,
        expectedFrames: Int64,
        expectedResolution: PixelDimensions,
        expectedAudioSampleRate: Int,
        expectedAudioMarkerTime: RationalTime
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
        try await assertExportHasAlignedPCM(
            exportURL,
            expectedSampleRate: expectedAudioSampleRate,
            expectedMarkerTime: expectedAudioMarkerTime
        )
    }

    private func assertExportHasAlignedPCM(
        _ exportURL: URL,
        expectedSampleRate: Int,
        expectedMarkerTime: RationalTime
    ) async throws {
        let duration = try await AVURLAsset(url: exportURL).load(.duration)
        XCTAssertTrue(duration.isValid)
        XCTAssertTrue(duration.isNumeric)
        let sourceRange = try TimeRange(
            start: .zero,
            duration: RationalTime(
                value: duration.value,
                timescale: Int64(duration.timescale)
            )
        )
        let decoded = try await AudioPCMDecoder().decodeWindow(
            from: exportURL,
            sourceRange: sourceRange
        )
        XCTAssertEqual(decoded.sampleRate, expectedSampleRate)
        XCTAssertEqual(decoded.channelCount, 2)
        XCTAssertGreaterThan(decoded.frameCount, 0)
        XCTAssertEqual(decoded.frameOffset, 0)
        XCTAssertEqual(decoded.presentationTime, .zero)
        XCTAssertEqual(decoded.samples.count, decoded.frameCount * decoded.channelCount)
        XCTAssertTrue(
            decoded.samples.allSatisfy(\.isFinite),
            "exported PCM must not contain NaN or infinity"
        )

        let activeThreshold = Float(0.02)
        let firstActiveFrame = (0..<decoded.frameCount).first { frame in
            let firstSample = frame * decoded.channelCount
            let frameSamples = decoded.samples[
                firstSample..<(firstSample + decoded.channelCount)
            ]
            return frameSamples.contains { abs($0) > activeThreshold }
        }
        let observedMarkerFrame = try XCTUnwrap(
            firstActiveFrame,
            "exported PCM track is silent; muxed audio did not survive the user journey"
        )
        let outputRate = try FrameRate(frames: Int64(decoded.sampleRate))
        let expectedMarkerFrame = try expectedMarkerTime.frameIndex(
            at: outputRate,
            rounding: .nearestOrAwayFromZero
        )
        XCTAssertLessThanOrEqual(
            abs(Int64(observedMarkerFrame) - expectedMarkerFrame),
            4,
            "exported PCM marker is shifted from its linked timeline position"
        )

        let silencePrefixEnd = max(0, Int(expectedMarkerFrame) - 8)
        let silencePrefixSampleCount = silencePrefixEnd * decoded.channelCount
        XCTAssertTrue(
            decoded.samples.prefix(silencePrefixSampleCount).allSatisfy { abs($0) < 0.001 },
            "exported PCM became active before the fixture's deterministic marker"
        )
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
        case .sRGB:
            colorSpace = .sRGB
        case .rec709, .rec2020, .unspecified, .unknown:
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

    private func mediaClips(
        in model: EditorAjarAppModel,
        mediaID: UUID,
        kind: TrackKind
    ) throws -> [TrackedClip] {
        let sequence = try XCTUnwrap(model.activeSequence)
        var matches: [TrackedClip] = []
        for track in sequence.videoTracks + sequence.audioTracks {
            for item in track.items {
                guard case .clip(let clip) = item,
                    clip.kind == kind,
                    clip.source == .media(id: mediaID)
                else {
                    continue
                }
                matches.append(TrackedClip(trackID: track.id, clip: clip))
            }
        }
        return matches.sorted { $0.clip.timelineRange.start < $1.clip.timelineRange.start }
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
        let muxedAudioMarkerTime: RationalTime
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
        try AcceptancePCMWriter.writeTone(
            to: audioURL,
            sampleRate: 44_100,
            channelCount: 2,
            frameCount: Int(frameCount) * 44_100 / Int(frameRate)
        )
        return MediaFixtures(
            videoURL: videoURL,
            stillURL: stillURL,
            audioURL: audioURL,
            muxedAudioMarkerTime: try RationalTime(
                value: Int64(AcceptanceSyntheticProResWriter.audioMarkerStartFrame),
                timescale: Int64(AcceptanceSyntheticProResWriter.audioSampleRate)
            )
        )
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

private final class AcceptanceAudioOutputDriver: EditorAjarAudioOutputDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var publishedSamples: [[Float]] = []
    private var startCountValue = 0
    private var latestSafetyReport: RealtimeAudioSafetyReport?

    var publishCount: Int {
        lock.withLock { publishedSamples.count }
    }

    var startCount: Int {
        lock.withLock { startCountValue }
    }

    var lastPublishedSamples: [Float] {
        lock.withLock { publishedSamples.last ?? [] }
    }

    func publish(_ plan: RealtimeAudioRenderPlan) throws {
        let report = plan.safetyReport()
        var inspectablePlan = plan
        var samples = [Float](
            repeating: 0,
            count: report.preparedFrameCount * plan.format.channelCount
        )
        samples.withUnsafeMutableBufferPointer { output in
            _ = inspectablePlan.render(into: output)
        }
        lock.withLock {
            publishedSamples.append(samples)
            latestSafetyReport = report
        }
    }

    func start() throws {
        lock.withLock { startCountValue += 1 }
    }

    func stop() {}

    func safetyReport() -> RealtimeAudioSafetyReport? {
        lock.withLock { latestSafetyReport }
    }
}

/// Minimal muxed ProRes 4444 + native-rate Float32 PCM writer for the release journey.
private enum AcceptanceSyntheticProResWriter {
    static let audioSampleRate = 44_100
    static let audioMarkerStartFrame = 4_410
    private static let audioChannelCount = 2
    private static let audioAppendFrameCount = 4_096

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

        let audioOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: audioChannelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        guard writer.canApply(outputSettings: audioOutputSettings, forMediaType: .audio) else {
            throw AcceptanceFixtureError.cannotAddAudioInput
        }
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: audioOutputSettings
        )
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw AcceptanceFixtureError.cannotAddAudioInput
        }
        writer.add(audioInput)

        let audioFrameProduct = frameCount.multipliedReportingOverflow(by: audioSampleRate)
        guard frameRate > 0,
            !audioFrameProduct.overflow,
            audioFrameProduct.partialValue.isMultiple(of: Int(frameRate))
        else {
            throw AcceptanceFixtureError.writerFailed("fixture duration is not audio-frame exact")
        }
        let audioFrameCount = audioFrameProduct.partialValue / Int(frameRate)
        let audioBuffer = try makeAudioBuffer(frameCount: audioFrameCount)
        let audioSampleBufferFactory = try AudioSampleBufferFactory(
            sampleRate: audioSampleRate,
            channelCount: audioChannelCount
        )

        guard writer.startWriting() else {
            throw AcceptanceFixtureError.writerFailed(String(describing: writer.error))
        }
        writer.startSession(atSourceTime: .zero)

        var videoFrameIndex = 0
        var audioFrameIndex = 0
        let writeDeadline = Date().addingTimeInterval(15)
        do {
            while videoFrameIndex < frameCount || audioFrameIndex < audioFrameCount {
                if writer.status == .failed || writer.status == .cancelled {
                    throw AcceptanceFixtureError.writerFailed(String(describing: writer.error))
                }
                var madeProgress = false
                if videoFrameIndex < frameCount, input.isReadyForMoreMediaData {
                    let buffer = try makePixelBuffer(
                        width: width,
                        height: height,
                        frameIndex: videoFrameIndex
                    )
                    let time = CMTime(value: Int64(videoFrameIndex), timescale: frameRate)
                    guard adaptor.append(buffer, withPresentationTime: time) else {
                        throw AcceptanceFixtureError.writerFailed(
                            String(describing: writer.error)
                        )
                    }
                    videoFrameIndex += 1
                    madeProgress = true
                }
                if audioFrameIndex < audioFrameCount, audioInput.isReadyForMoreMediaData {
                    let end = min(
                        audioFrameIndex + audioAppendFrameCount,
                        audioFrameCount
                    )
                    let sampleBuffer = try audioSampleBufferFactory.makeSampleBuffer(
                        from: audioBuffer,
                        frames: audioFrameIndex..<end
                    )
                    guard audioInput.append(sampleBuffer) else {
                        throw AcceptanceFixtureError.writerFailed(
                            String(describing: writer.error)
                        )
                    }
                    audioFrameIndex = end
                    madeProgress = true
                }
                if !madeProgress {
                    guard Date() < writeDeadline else {
                        throw AcceptanceFixtureError.writerFailed(
                            "muxed fixture writer stalled before all samples were appended"
                        )
                    }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        audioInput.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw AcceptanceFixtureError.writerFailed(String(describing: writer.error))
        }
    }

    private static func makeAudioBuffer(frameCount: Int) throws -> RenderedAudioBuffer {
        guard frameCount > audioMarkerStartFrame else {
            throw AcceptanceFixtureError.writerFailed("audio marker falls outside fixture")
        }
        var samples: [Float] = []
        samples.reserveCapacity(frameCount * audioChannelCount)
        for frame in 0..<frameCount {
            let sample: Float
            if frame < audioMarkerStartFrame {
                sample = 0
            } else {
                let localFrame = frame - audioMarkerStartFrame
                let phase = 2 * Double.pi * 997 * Double(localFrame) / Double(audioSampleRate)
                sample = Float(cos(phase) * 0.5)
            }
            samples.append(sample)
            samples.append(-sample)
        }
        return try RenderedAudioBuffer(
            format: AudioRenderFormat(
                sampleRate: audioSampleRate,
                channelCount: audioChannelCount
            ),
            frameCount: frameCount,
            samples: samples
        )
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
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                "public.png" as CFString,
                1,
                nil
            )
        else {
            throw AcceptanceFixtureError.pngEncodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AcceptanceFixtureError.pngEncodeFailed
        }
    }
}

private enum AcceptancePCMWriter {
    static func writeTone(
        to url: URL,
        sampleRate: Int,
        channelCount: Int,
        frameCount: Int
    ) throws {
        guard sampleRate > 0,
            channelCount > 0,
            frameCount > 0,
            frameCount <= Int.max / channelCount,
            let dataByteCount = UInt32(
                exactly: frameCount * channelCount * MemoryLayout<Int16>.size
            ),
            let riffByteCount = UInt32(exactly: UInt64(dataByteCount) + 36),
            let byteRate = UInt32(
                exactly: sampleRate * channelCount * MemoryLayout<Int16>.size
            ),
            let blockAlign = UInt16(
                exactly: channelCount * MemoryLayout<Int16>.size
            ),
            let waveSampleRate = UInt32(exactly: sampleRate),
            let waveChannelCount = UInt16(exactly: channelCount)
        else {
            throw AcceptanceFixtureError.writerFailed("invalid PCM fixture dimensions")
        }

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        append(riffByteCount, to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(waveChannelCount, to: &data)
        append(waveSampleRate, to: &data)
        append(byteRate, to: &data)
        append(blockAlign, to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        append(dataByteCount, to: &data)

        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * 440 * Double(frame) / Double(sampleRate)
            let sample = Int16((sin(phase) * 8_192).rounded())
            for channel in 0..<channelCount {
                append(channel.isMultiple(of: 2) ? sample : -sample, to: &data)
            }
        }
        try data.write(to: url, options: .atomic)
    }

    private static func append<Value: FixedWidthInteger>(
        _ value: Value,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private enum AcceptanceFixtureError: Error, CustomStringConvertible {
    case cannotAddVideoInput
    case cannotAddAudioInput
    case writerFailed(String)
    case pixelBufferFailed(CVReturn)
    case missingBaseAddress
    case pngEncodeFailed
    case clipNotFound

    var description: String {
        switch self {
        case .cannotAddVideoInput:
            "cannot add ProRes video input"
        case .cannotAddAudioInput:
            "cannot add linear PCM audio input"
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
