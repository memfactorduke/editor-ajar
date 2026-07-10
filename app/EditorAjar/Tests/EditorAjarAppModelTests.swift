// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import AjarExport
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarAppModelTests: XCTestCase {
    func testFRPLAY001SampleProjectLoadsFromAjarCoreModel() {
        let model = EditorAjarAppModel()

        XCTAssertNotNil(model.project)
        XCTAssertEqual(model.activeSequenceName, "Sample Playback Sequence")
        XCTAssertEqual(model.project?.validate(), .valid)
        XCTAssertEqual(model.frameRateDescription, "30 fps")
        XCTAssertEqual(model.project?.mediaPool.count, 2)
        XCTAssertEqual(model.activeSequence?.videoTracks.count, 2)
        XCTAssertEqual(model.activeSequence?.audioTracks.count, 2)
        XCTAssertGreaterThan(model.durationFrames, 1)
    }

    func testFREXP003004ExportDialogPresentsPresetsAndValidatesWholeTimeline() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-export-presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL
        )

        model.presentExportDialog()
        XCTAssertTrue(model.exportDialog.isPresented)
        XCTAssertGreaterThanOrEqual(model.exportDialog.availablePresets.count, 5)
        XCTAssertEqual(model.exportDialog.mode, .video)
        XCTAssertEqual(model.exportDialog.rangeChoice, .wholeTimeline)

        XCTAssertTrue(model.validateExportDialogSelection())
        XCTAssertEqual(
            model.exportDialog.statusMessage,
            "Ready to export video"
        )

        model.setExportMode(.stillFrame)
        XCTAssertTrue(model.validateExportDialogSelection())

        model.setExportMode(.audioOnly)
        model.setAudioOnlyFormat(.wavPCM)
        XCTAssertTrue(model.validateExportDialogSelection())

        model.dismissExportDialog()
        XCTAssertFalse(model.exportDialog.isPresented)
    }

    func testFREXP003CustomPresetsPersistAppSideNotInProject() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-export-presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL
        )
        let frameRate = try FrameRate(frames: 30)
        let custom = ExportPreset(
            name: "Test 480p",
            isBuiltIn: false,
            container: .mp4,
            videoCodec: .h264,
            resolution: PixelDimensions(width: 854, height: 480),
            frameRate: frameRate,
            averageBitRate: 2_500_000,
            audio: try ExportAudioSettings(
                codec: .aac,
                sampleRate: 48_000,
                channelCount: 2,
                bitRate: 128_000
            )
        )
        try model.saveCustomExportPreset(custom)

        let reloaded = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL
        )
        XCTAssertTrue(reloaded.exportDialog.availablePresets.contains { $0.id == custom.id })
        // Project package is untouched — custom presets never appear in project.json fields.
        XCTAssertEqual(model.project, reloaded.project)
    }

    func testFREXP004ExportDialogRejectsMissingInOutMarks() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-export-presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL
        )
        model.presentExportDialog()
        model.setExportRangeChoice(.inOutMarks)
        // No in/out marks set.
        XCTAssertFalse(model.validateExportDialogSelection())
        XCTAssertNotNil(model.exportDialog.statusMessage)
    }

    /// Out mark is inclusive (NLE convention): UI "Range 10-14" exports frames 10…14 inclusive.
    func testFREXP004InOutMarksExportInclusiveOutFrameFirstAndLast() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-export-presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL
        )
        let sequence = try XCTUnwrap(model.activeSequence)
        let frameRate = sequence.timebase

        model.scrub(to: 10)
        model.setTimelineRangeIn()
        model.scrub(to: 14)
        model.setTimelineRangeOut()
        XCTAssertEqual(model.timelineRangeDescription, "Range 10-14")

        model.setExportRangeChoice(.inOutMarks)
        let range = try model.exportDialog.resolvedRange(
            sequence: sequence,
            selectionInFrame: model.timelineState.selectionInFrame,
            selectionOutFrame: model.timelineState.selectionOutFrame
        )

        let firstFrame = try range.start.frameIndex(
            at: frameRate,
            rounding: .towardZero
        )
        let exclusiveEnd = try range.start.adding(range.duration)
        let exclusiveEndFrame = try exclusiveEnd.frameIndex(
            at: frameRate,
            rounding: .towardZero
        )
        let lastFrame = exclusiveEndFrame - 1
        let frameCount = try range.duration.frameIndex(
            at: frameRate,
            rounding: .towardZero
        )

        XCTAssertEqual(firstFrame, 10, "first exported frame must match inclusive in mark")
        XCTAssertEqual(lastFrame, 14, "last exported frame must match inclusive out mark")
        XCTAssertEqual(frameCount, 5, "inclusive [10,14] is 5 frames → half-open [10,15)")
        XCTAssertEqual(exclusiveEndFrame, 15)

        // Single-frame mark pair is valid under inclusive-out.
        model.scrub(to: 7)
        model.setTimelineRangeIn()
        model.setTimelineRangeOut()
        XCTAssertEqual(model.timelineRangeDescription, "Range 7-7")
        let single = try model.exportDialog.resolvedRange(
            sequence: sequence,
            selectionInFrame: model.timelineState.selectionInFrame,
            selectionOutFrame: model.timelineState.selectionOutFrame
        )
        let singleCount = try single.duration.frameIndex(
            at: frameRate,
            rounding: .towardZero
        )
        XCTAssertEqual(singleCount, 1)
    }

    func testFREXP004StillExportClampsPlayheadAtDurationExclusiveEnd() {
        // playheadFrame is private(set) and scrub clamps below duration; pin the pure clamp
        // used by the still-export path when playhead sits on the exclusive end.
        XCTAssertEqual(
            EditorAjarAppModel.clampedStillExportFrame(playheadFrame: 90, durationFrames: 90),
            89
        )
        XCTAssertEqual(
            EditorAjarAppModel.clampedStillExportFrame(playheadFrame: 89, durationFrames: 90),
            89
        )
        XCTAssertEqual(
            EditorAjarAppModel.clampedStillExportFrame(playheadFrame: 0, durationFrames: 1),
            0
        )
        XCTAssertEqual(
            EditorAjarAppModel.clampedStillExportFrame(playheadFrame: 5, durationFrames: 0),
            0
        )
    }

    func testFREXP003SaveCustomPresetRecoversFromCorruptStore() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-export-presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        // Corrupt JSON that would make loadCustomPresets throw decodingFailed.
        try Data("{ not valid json".utf8).write(to: storeURL)

        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL
        )
        let frameRate = try FrameRate(frames: 30)
        let custom = ExportPreset(
            name: "Recovered After Corrupt",
            isBuiltIn: false,
            container: .mp4,
            videoCodec: .h264,
            resolution: PixelDimensions(width: 640, height: 360),
            frameRate: frameRate,
            averageBitRate: 1_500_000,
            audio: try ExportAudioSettings(
                codec: .aac,
                sampleRate: 48_000,
                channelCount: 2,
                bitRate: 128_000
            )
        )
        // Must not propagate decodingFailed — overwrite corrupt store with the new preset.
        try model.saveCustomExportPreset(custom)
        XCTAssertTrue(model.exportDialog.availablePresets.contains { $0.id == custom.id })

        let reloaded = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL
        )
        XCTAssertTrue(reloaded.exportDialog.availablePresets.contains { $0.id == custom.id })
    }

    func testFRPLAY001TransportTogglesPlaybackAndFrameStepPauses() {
        let model = EditorAjarAppModel()

        XCTAssertFalse(model.isPlaying)
        model.togglePlayback()
        XCTAssertTrue(model.isPlaying)

        model.stepForward()
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playheadFrame, 1)

        model.stepBackward()
        model.stepBackward()
        XCTAssertEqual(model.playheadFrame, 0)
    }

    func testFRAUD007TransportStartsAndStopsLiveAudioWithVideoPlayback() {
        let audioCoordinator = FakeAudioCoordinator()
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            audioCoordinator: audioCoordinator
        )

        model.togglePlayback()

        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(audioCoordinator.startedFrames, [0])
        XCTAssertEqual(audioCoordinator.stopCount, 0)

        model.togglePlayback()

        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(audioCoordinator.stopCount, 1)
    }

    func testFRPLAY003StepAndScrubDoNotRepublishLiveAudioWhilePaused() {
        let audioCoordinator = FakeAudioCoordinator()
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            audioCoordinator: audioCoordinator
        )

        model.scrub(to: 12)
        model.stepForward()
        model.stepBackward()

        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(audioCoordinator.seekFrames, [])
        XCTAssertEqual(audioCoordinator.stopCount, 3)
    }

    func testFRAUD007CoordinatorRefillsLiveAudioAtPlaybackWindowMargin() throws {
        let driver = FakeAudioOutputDriver()
        let coordinator = EditorAjarLiveAudioCoordinator(driver: driver)
        let project = try EditorAjarSampleProjectFactory.makeSampleProject()
        let sequence = try XCTUnwrap(project.sequences.first)
        let durationFrames = try Self.durationFrames(for: sequence)

        try coordinator.start(
            project: project,
            sequence: sequence,
            playheadFrame: 0,
            durationFrames: durationFrames
        )
        coordinator.drainPendingRendersForTesting()

        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(driver.publishCount, 1)
        XCTAssertEqual(driver.publishedFrameCounts, [96_000])
        XCTAssertEqual(driver.publishWasOnMainThread, [false])

        try coordinator.ensurePlaybackPlan(
            project: project,
            sequence: sequence,
            playheadFrame: 29,
            durationFrames: durationFrames
        )
        coordinator.drainPendingRendersForTesting()

        XCTAssertEqual(driver.publishCount, 1)

        try coordinator.ensurePlaybackPlan(
            project: project,
            sequence: sequence,
            playheadFrame: 30,
            durationFrames: durationFrames
        )
        coordinator.drainPendingRendersForTesting()

        XCTAssertEqual(driver.publishCount, 2)
        XCTAssertEqual(driver.publishedFrameCounts, [96_000, 96_000])
        XCTAssertEqual(driver.publishWasOnMainThread, [false, false])
    }

    func testFRPLAY001DisplayLinkAdvancesPlayheadAtSequenceFrameRate() throws {
        let frameRate = try FrameRate(frames: 30)
        var controller = EditorAjarPlaybackController(frameRate: frameRate, durationFrames: 4)

        XCTAssertFalse(controller.advance(by: 1.0 / 60.0))
        XCTAssertEqual(controller.playheadFrame, 0)
        XCTAssertTrue(controller.advance(by: 1.0 / 60.0))
        XCTAssertEqual(controller.playheadFrame, 1)

        XCTAssertTrue(controller.advance(by: 3.0 / 30.0))
        XCTAssertEqual(controller.playheadFrame, 0)
    }

    func testFRPLAY003ScrubClampsAndStepUpdatesFrame() throws {
        let frameRate = try FrameRate(frames: 30)
        var controller = EditorAjarPlaybackController(frameRate: frameRate, durationFrames: 10)

        controller.scrub(to: 7)
        XCTAssertEqual(controller.playheadFrame, 7)

        controller.stepForward()
        XCTAssertEqual(controller.playheadFrame, 8)

        controller.scrub(to: 20)
        XCTAssertEqual(controller.playheadFrame, 9)

        controller.scrub(to: -4)
        XCTAssertEqual(controller.playheadFrame, 0)
    }

    func testFRTL001TrackToggleRoutesThroughEditHistoryAndUndo() throws {
        let model = EditorAjarAppModel()
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)

        model.setTrackState(
            sequenceID: sequence.id,
            trackID: videoTrack.id,
            enabled: false,
            locked: true,
            hidden: true
        )

        let editedTrack = try XCTUnwrap(model.activeSequence?.videoTracks.first)
        XCTAssertFalse(editedTrack.enabled)
        XCTAssertTrue(editedTrack.locked)
        XCTAssertTrue(editedTrack.hidden)
        XCTAssertTrue(model.canUndo)

        model.undo()

        let restoredTrack = try XCTUnwrap(model.activeSequence?.videoTracks.first)
        XCTAssertTrue(restoredTrack.enabled)
        XCTAssertFalse(restoredTrack.locked)
        XCTAssertFalse(restoredTrack.hidden)
    }

    func testFRTL012AppUndoRedoMenuTitlesAndAvailabilityReflectEditHistory() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
        let originalProject = try XCTUnwrap(model.project)

        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertEqual(model.undoMenuTitle, "Undo")
        XCTAssertEqual(model.redoMenuTitle, "Redo")

        model.setTrackState(
            sequenceID: sequence.id,
            trackID: videoTrack.id,
            hidden: true
        )
        let editedProject = try XCTUnwrap(model.project)

        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertEqual(model.undoMenuTitle, "Undo Change Track State")

        model.undo()

        XCTAssertEqual(model.project, originalProject)
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canRedo)
        XCTAssertEqual(model.undoMenuTitle, "Undo")
        XCTAssertEqual(model.redoMenuTitle, "Redo Change Track State")

        model.redo()

        XCTAssertEqual(model.project, editedProject)
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertEqual(model.undoMenuTitle, "Undo Change Track State")
        XCTAssertEqual(model.redoMenuTitle, "Redo")

        model.undo()
        model.addTimelineMarkerAtPlayhead()

        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertEqual(model.undoMenuTitle, "Undo Add Marker")
    }

    func testFRTL012LongAppUndoRedoSequenceRestoresExactProjectState() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        let originalProject = try XCTUnwrap(model.project)
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
        let audioTrack = try XCTUnwrap(sequence.audioTracks.first)
        let linkedSelection = try sampleLinkedSelection(in: model)

        model.setTrackState(
            sequenceID: sequence.id,
            trackID: videoTrack.id,
            hidden: true
        )
        model.setTrackState(
            sequenceID: sequence.id,
            trackID: audioTrack.id,
            muted: true
        )
        model.scrub(to: 12)
        model.addTimelineMarkerAtPlayhead()
        model.updateSelectedMarker(
            name: "Undo checkpoint",
            color: .green,
            note: "FR-TL-012"
        )
        model.selectClip(
            trackID: linkedSelection.videoTrackID,
            clipID: linkedSelection.videoClip.id,
            mode: .replace
        )
        XCTAssertTrue(model.moveSelectedClip(toStartFrame: 6))
        XCTAssertTrue(model.detachAudioForSelectedClip())

        let editedProject = try XCTUnwrap(model.project)
        XCTAssertNotEqual(editedProject, originalProject)
        XCTAssertEqual(model.undoMenuTitle, "Undo Detach Audio")

        for _ in 0..<6 {
            XCTAssertTrue(model.canUndo)
            model.undo()
        }

        XCTAssertEqual(model.project, originalProject)
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canRedo)

        for _ in 0..<6 {
            XCTAssertTrue(model.canRedo)
            model.redo()
        }

        XCTAssertEqual(model.project, editedProject)
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
    }

    func testFRTL011SequenceTabsAddCloseAndUndoThroughEditHistory() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        let originalProject = try XCTUnwrap(model.project)
        let originalSequenceID = try XCTUnwrap(model.activeSequenceID)

        XCTAssertEqual(model.sequenceTabs.map(\.title), ["Sample Playback Sequence"])
        XCTAssertFalse(model.canCloseActiveSequence)

        XCTAssertTrue(model.addSequence())
        let addedSequenceID = try XCTUnwrap(model.activeSequenceID)

        XCTAssertNotEqual(addedSequenceID, originalSequenceID)
        XCTAssertEqual(model.activeSequenceName, "Sequence 2")
        XCTAssertEqual(model.project?.sequences.count, 2)
        XCTAssertTrue(model.canCloseActiveSequence)
        XCTAssertEqual(model.undoMenuTitle, "Undo Add Sequence")

        XCTAssertTrue(model.closeActiveSequence())

        XCTAssertEqual(model.activeSequenceID, originalSequenceID)
        XCTAssertEqual(model.project?.sequences.count, 1)
        XCTAssertEqual(model.undoMenuTitle, "Undo Remove Sequence")

        model.undo()

        XCTAssertEqual(model.project?.sequences.count, 2)
        XCTAssertTrue(model.canCloseActiveSequence)

        model.undo()

        XCTAssertEqual(model.project, originalProject)
        XCTAssertEqual(model.activeSequenceID, originalSequenceID)
        XCTAssertFalse(model.canCloseActiveSequence)
    }

    func testFRTL011SequenceTabsRestorePerSequenceEditingContext() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        let firstSequenceID = try XCTUnwrap(model.activeSequenceID)
        let firstVideoTrack = try XCTUnwrap(model.activeSequence?.videoTracks.first)
        let firstClipLayout = try XCTUnwrap(model.timelineClipLayouts(for: firstVideoTrack).first)

        model.scrub(to: 12)
        model.selectClip(
            trackID: firstClipLayout.reference.trackID,
            clipID: firstClipLayout.reference.clipID,
            mode: .replace
        )
        model.zoomTimelineIn()
        let firstPixelsPerFrame = model.timelineState.pixelsPerFrame

        XCTAssertTrue(model.addSequence())
        let secondSequenceID = try XCTUnwrap(model.activeSequenceID)

        XCTAssertNotEqual(firstSequenceID, secondSequenceID)
        XCTAssertEqual(model.playheadFrame, 0)
        XCTAssertEqual(model.timelineSelectedClipCount, 0)
        XCTAssertTrue(model.timelineSnappingEnabled)

        model.scrub(to: 5)
        model.setTimelineSnappingEnabled(false)
        model.zoomTimelineOut()

        XCTAssertTrue(model.selectSequence(firstSequenceID))

        XCTAssertEqual(model.playheadFrame, 12)
        XCTAssertEqual(model.timelineSelectedClipCount, 1)
        XCTAssertTrue(model.timelineSnappingEnabled)
        XCTAssertEqual(model.timelineState.pixelsPerFrame, firstPixelsPerFrame)

        XCTAssertTrue(model.selectSequence(secondSequenceID))

        XCTAssertEqual(model.playheadFrame, 0)
        XCTAssertFalse(model.timelineSnappingEnabled)
    }

    func testFRTL010TimelineTimeMappingAndZoomClamps() {
        XCTAssertEqual(
            TimelineInteraction.xPosition(frame: 12, pixelsPerFrame: 4),
            48
        )
        XCTAssertEqual(
            TimelineInteraction.frame(atX: 49, pixelsPerFrame: 4, durationFrames: 20),
            12
        )
        XCTAssertEqual(
            TimelineInteraction.frame(atX: -25, pixelsPerFrame: 4, durationFrames: 20),
            0
        )
        XCTAssertEqual(
            TimelineInteraction.frame(atX: 200, pixelsPerFrame: 4, durationFrames: 20),
            19
        )
        XCTAssertEqual(
            TimelineInteraction.fittedPixelsPerFrame(durationFrames: 100, availableWidth: 500),
            5
        )
        XCTAssertEqual(
            TimelineInteraction.zoomedPixelsPerFrame(100, factor: 2),
            TimelineInteractionState.maximumPixelsPerFrame
        )
        XCTAssertEqual(
            TimelineInteraction.zoomedLaneHeight(10, factor: 0.5),
            TimelineInteractionState.minimumLaneHeight
        )
    }

    func testFRTL010TimelineClipLayoutsScaleTimelineItems() throws {
        let sequence = try makeInteractionSequence()
        let track = try XCTUnwrap(sequence.videoTracks.first)

        let layouts = TimelineInteraction.clipLayouts(
            for: track,
            frameRate: sequence.timebase,
            pixelsPerFrame: 2
        )

        XCTAssertEqual(layouts.count, 3)
        XCTAssertEqual(layouts[0].startFrame, 0)
        XCTAssertEqual(layouts[0].endFrame, 30)
        XCTAssertEqual(layouts[0].xPosition, 0)
        XCTAssertEqual(layouts[0].width, 60)
        XCTAssertEqual(layouts[1].startFrame, 45)
        XCTAssertEqual(layouts[1].width, 30)
    }

    func testFRTL007SelectionReducerSupportsReplaceToggleAndRange() throws {
        let sequence = try makeInteractionSequence()
        let references = TimelineInteraction.clipReferences(in: sequence)
        let first = try XCTUnwrap(references.first)
        let second = try XCTUnwrap(references.dropFirst().first)
        let third = try XCTUnwrap(references.dropFirst(2).first)

        let replaced = TimelineInteraction.reducedSelection(
            currentSelection: [],
            anchor: nil,
            visibleClipReferences: references,
            reference: first,
            mode: .replace
        )
        XCTAssertEqual(replaced.selectedClips, [first])
        XCTAssertEqual(replaced.anchor, first)

        let toggled = TimelineInteraction.reducedSelection(
            currentSelection: replaced.selectedClips,
            anchor: replaced.anchor,
            visibleClipReferences: references,
            reference: second,
            mode: .toggle
        )
        XCTAssertEqual(toggled.selectedClips, [first, second])

        let ranged = TimelineInteraction.reducedSelection(
            currentSelection: toggled.selectedClips,
            anchor: first,
            visibleClipReferences: references,
            reference: third,
            mode: .rangeOnTrack
        )
        XCTAssertEqual(ranged.selectedClips, [first, second, third])
        XCTAssertEqual(ranged.anchor, first)
    }

    func testFRTL006SnappingUsesPlayheadClipEdgesAndMarkers() throws {
        let sequence = try makeInteractionSequence()
        let targets = TimelineInteraction.snapTargets(in: sequence, playheadFrame: 10)

        XCTAssertEqual(
            TimelineInteraction.snappedFrame(
                proposedFrame: 11,
                targets: targets,
                toleranceFrames: 2
            ),
            10
        )
        XCTAssertEqual(
            TimelineInteraction.snappedFrame(
                proposedFrame: 31,
                targets: targets,
                toleranceFrames: 2
            ),
            30
        )
        XCTAssertEqual(
            TimelineInteraction.snappedFrame(
                proposedFrame: 59,
                targets: targets,
                toleranceFrames: 2
            ),
            60
        )
        XCTAssertEqual(
            TimelineInteraction.snappedFrame(
                proposedFrame: 25,
                targets: targets,
                toleranceFrames: 2
            ),
            25
        )
    }

    func testFRTL006FRTL007FRTL010AppTimelineInteractionState() throws {
        let model = EditorAjarAppModel()
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
        let clipLayout = try XCTUnwrap(model.timelineClipLayouts(for: videoTrack).first)

        XCTAssertTrue(model.timelineSnappingEnabled)
        model.selectClip(
            trackID: clipLayout.reference.trackID,
            clipID: clipLayout.reference.clipID,
            mode: .replace
        )
        XCTAssertTrue(model.isClipSelected(clipLayout.reference))
        XCTAssertEqual(model.timelineSelectedClipCount, 1)

        model.setTimelineRangeIn()
        model.scrubTimeline(xPosition: 16, snappingDisabled: true)
        model.setTimelineRangeOut()
        XCTAssertEqual(model.timelineRangeDescription, "Range 0-2")

        let initialPixelsPerFrame = model.timelineState.pixelsPerFrame
        model.zoomTimelineIn()
        XCTAssertGreaterThan(model.timelineState.pixelsPerFrame, initialPixelsPerFrame)
        model.fitTimeline(toWidth: 450)
        XCTAssertEqual(model.timelineContentWidth(minimumWidth: 450), 450)
        model.zoomTimelineToSelection(toWidth: 300)
        XCTAssertGreaterThan(model.timelineState.pixelsPerFrame, 1)

        model.setTimelineSnappingEnabled(false)
        XCTAssertFalse(model.timelineSnappingEnabled)
    }

    func testFRTL009AppLinkedMoveAndMomentaryUnlinkRouteThroughEditHistory() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        let selection = try sampleLinkedSelection(in: model)

        XCTAssertEqual(selection.videoClip.linkGroupID, selection.audioClip.linkGroupID)
        model.selectClip(
            trackID: selection.videoTrackID,
            clipID: selection.videoClip.id,
            mode: .replace
        )
        XCTAssertTrue(model.selectedClipIsLinked)

        XCTAssertTrue(model.moveSelectedClip(toStartFrame: 12, linkedClipEditMode: .linked))
        let linkedMoveSelection = try sampleLinkedSelection(in: model)
        try assertFrameRange(
            linkedMoveSelection.videoClip.timelineRange,
            startFrame: 12,
            durationFrames: 90,
            frameRate: linkedMoveSelection.frameRate
        )
        try assertFrameRange(
            linkedMoveSelection.audioClip.timelineRange,
            startFrame: 12,
            durationFrames: 90,
            frameRate: linkedMoveSelection.frameRate
        )

        model.undo()
        XCTAssertTrue(model.moveSelectedClip(toStartFrame: 12, linkedClipEditMode: .unlinked))
        let unlinkedMoveSelection = try sampleLinkedSelection(in: model)
        try assertFrameRange(
            unlinkedMoveSelection.videoClip.timelineRange,
            startFrame: 12,
            durationFrames: 90,
            frameRate: unlinkedMoveSelection.frameRate
        )
        try assertFrameRange(
            unlinkedMoveSelection.audioClip.timelineRange,
            startFrame: 0,
            durationFrames: 90,
            frameRate: unlinkedMoveSelection.frameRate
        )
    }

    func testFRTL009AppTrimAndDetachAudioRouteThroughEditHistory() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        let selection = try sampleLinkedSelection(in: model)

        model.selectClip(
            trackID: selection.videoTrackID,
            clipID: selection.videoClip.id,
            mode: .replace
        )
        XCTAssertTrue(
            model.trimSelectedClip(
                sourceStartFrame: 4,
                timelineStartFrame: 4,
                durationFrames: 70,
                linkedClipEditMode: .linked
            )
        )
        let trimmedSelection = try sampleLinkedSelection(in: model)
        try assertFrameRange(
            trimmedSelection.videoClip.sourceRange,
            startFrame: 4,
            durationFrames: 70,
            frameRate: trimmedSelection.frameRate
        )
        try assertFrameRange(
            trimmedSelection.audioClip.sourceRange,
            startFrame: 4,
            durationFrames: 70,
            frameRate: trimmedSelection.frameRate
        )

        XCTAssertTrue(model.detachAudioForSelectedClip())
        let detachedSelection = try sampleLinkedSelection(in: model)
        XCTAssertNil(detachedSelection.videoClip.linkGroupID)
        XCTAssertNil(detachedSelection.audioClip.linkGroupID)

        model.undo()
        let relinkedSelection = try sampleLinkedSelection(in: model)
        XCTAssertEqual(relinkedSelection.videoClip.linkGroupID, selection.videoClip.linkGroupID)
        XCTAssertEqual(relinkedSelection.audioClip.linkGroupID, selection.audioClip.linkGroupID)
    }

    func testFRTL008AppMarkerActionsRouteThroughEditHistoryAndUndo() throws {
        let model = EditorAjarAppModel()
        let initialMarkerCount = model.activeSequence?.markers.count ?? 0

        model.scrub(to: 12)
        model.addTimelineMarkerAtPlayhead()

        let addedMarker = try XCTUnwrap(model.selectedMarker)
        XCTAssertEqual(model.activeSequence?.markers.count, initialMarkerCount + 1)
        XCTAssertEqual(
            try addedMarker.time.frameIndex(
                at: try XCTUnwrap(model.activeSequence?.timebase),
                rounding: .nearestOrAwayFromZero
            ),
            12
        )
        XCTAssertTrue(model.canUndo)

        model.updateSelectedMarker(
            name: "Scene beat",
            color: .green,
            note: "Check the cut before export"
        )

        let updatedMarker = try XCTUnwrap(model.selectedMarker)
        XCTAssertEqual(updatedMarker.name, "Scene beat")
        XCTAssertEqual(updatedMarker.color, .green)
        XCTAssertEqual(updatedMarker.note, "Check the cut before export")
        XCTAssertEqual(model.timelineMarkerLayouts().first?.name, "Scene beat")

        model.deleteSelectedMarker()
        XCTAssertNil(model.selectedMarker)
        XCTAssertEqual(model.activeSequence?.markers.count, initialMarkerCount)

        model.undo()
        XCTAssertEqual(model.activeSequence?.markers.count, initialMarkerCount + 1)
        XCTAssertEqual(model.activeSequence?.markers.first?.name, "Scene beat")
    }

    func testFRPLAY002AppJumpsBetweenMarkers() throws {
        let model = EditorAjarAppModel()

        model.scrub(to: 10)
        model.addTimelineMarkerAtPlayhead()
        let firstMarker = try XCTUnwrap(model.selectedMarker)
        model.updateSelectedMarker(name: "First marker")

        model.scrub(to: 24)
        model.addTimelineMarkerAtPlayhead()
        let secondMarker = try XCTUnwrap(model.selectedMarker)
        model.updateSelectedMarker(name: "Second marker")

        model.scrub(to: 0)
        model.jumpToNextMarker()
        XCTAssertEqual(model.playheadFrame, 10)
        XCTAssertEqual(model.selectedMarker?.id, firstMarker.id)

        model.jumpToNextMarker()
        XCTAssertEqual(model.playheadFrame, 24)
        XCTAssertEqual(model.selectedMarker?.id, secondMarker.id)

        model.jumpToPreviousMarker()
        XCTAssertEqual(model.playheadFrame, 10)
        XCTAssertEqual(model.selectedMarker?.id, firstMarker.id)
    }

    func testFRXFORM007TransformInspectorFieldsRouteThroughEditHistoryAndUndo() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        try selectSampleVideoClip(in: model)
        let originalProject = try XCTUnwrap(model.project)

        XCTAssertEqual(model.transformFieldValue(.positionX), "0")
        XCTAssertTrue(model.updateSelectedTransformField(.positionX, rawValue: "12.5"))

        let editedTransform = try XCTUnwrap(model.selectedTransformInspector?.transform)
        XCTAssertEqual(editedTransform.position.x.doubleValue, 12.5, accuracy: 0.000_001)
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Clip Transform")

        model.undo()

        XCTAssertEqual(model.project, originalProject)
        XCTAssertEqual(model.transformFieldValue(.positionX), "0")
    }

    func testFRXFORM007BlendFlipAndCanvasGestureRouteThroughEditHistory() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        try selectSampleVideoClip(in: model)

        XCTAssertTrue(model.updateSelectedClipBlendMode(.screen))
        XCTAssertEqual(model.selectedTransformInspector?.transform.blendMode, .screen)

        XCTAssertTrue(model.updateSelectedClipFlip(horizontal: true))
        XCTAssertEqual(model.selectedTransformInspector?.transform.flip.horizontal, true)

        XCTAssertTrue(
            model.applyCanvasTransformGesture(
                CanvasTransformGesture(
                    handle: .move,
                    translationX: 20,
                    translationY: 10,
                    canvasScale: 2
                )
            )
        )
        let movedTransform = try XCTUnwrap(model.selectedTransformInspector?.transform)
        XCTAssertEqual(movedTransform.position.x.doubleValue, 10, accuracy: 0.000_001)
        XCTAssertEqual(movedTransform.position.y.doubleValue, 5, accuracy: 0.000_001)
        XCTAssertTrue(model.canUndo)
    }

    func testFRCOL007AppCopiesAndPastesGradeThroughUndoableHistory() throws {
        let fixture = try makeGradeAppFixture()
        let loaded = try loadGradeAppModel(project: fixture.project, named: "CopyPasteGrade.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model

        XCTAssertFalse(model.canCopyGrade)
        XCTAssertFalse(model.canPasteGrade)
        model.selectClip(
            trackID: fixture.source.trackID,
            clipID: fixture.source.clipID,
            mode: .replace
        )

        XCTAssertTrue(model.canCopyGrade)
        XCTAssertTrue(model.copyGradeFromSelectedClip())
        XCTAssertEqual(model.copiedGradeSource, fixture.source)

        model.selectClip(
            trackID: fixture.target.trackID,
            clipID: fixture.target.clipID,
            mode: .replace
        )
        XCTAssertTrue(model.canPasteGrade)
        XCTAssertTrue(model.pasteGradeToSelectedClip())
        XCTAssertEqual(model.undoMenuTitle, "Undo Copy Grade")

        let source = try projectClip(fixture.source, in: XCTUnwrap(model.project))
        let pasted = try projectClip(fixture.target, in: XCTUnwrap(model.project))
        XCTAssertEqual(
            pasted.effectStack.grade.nodes.map(\.definition),
            source.effectStack.grade.nodes.map(\.definition)
        )
        XCTAssertNotEqual(
            pasted.effectStack.grade.nodes.map(\.id),
            source.effectStack.grade.nodes.map(\.id)
        )
        let pastedIDs = pasted.effectStack.grade.nodes.map(\.id)

        model.undo()
        XCTAssertTrue(
            try projectClip(fixture.target, in: XCTUnwrap(model.project))
                .effectStack.grade.nodes.isEmpty
        )

        model.redo()
        XCTAssertEqual(
            try projectClip(fixture.target, in: XCTUnwrap(model.project))
                .effectStack.grade.nodes.map(\.id),
            pastedIDs
        )
    }

    func testFRCOL007AppSavesUniqueLookAndAppliesItToSelectedClip() throws {
        let fixture = try makeGradeAppFixture()
        let existingLook = ProjectLook(
            id: try appTestUUID("00000000-0000-0000-0000-000000007104"),
            name: " look 1 ",
            grade: ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: try appTestUUID("00000000-0000-0000-0000-000000007105"),
                        definition: .invert(.identity)
                    )
                ]
            )
        )
        let project = Project(
            schemaVersion: fixture.project.schemaVersion,
            schemaMinor: fixture.project.schemaMinor,
            settings: fixture.project.settings,
            mediaPool: fixture.project.mediaPool,
            sequences: fixture.project.sequences,
            looks: [existingLook]
        )
        let loaded = try loadGradeAppModel(project: project, named: "SaveApplyLook.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model

        model.selectClip(
            trackID: fixture.source.trackID,
            clipID: fixture.source.clipID,
            mode: .replace
        )
        XCTAssertTrue(model.canSaveLook)
        XCTAssertTrue(model.saveLookFromSelectedClip())
        XCTAssertEqual(model.savedLooks.map(\.name), [" look 1 ", "Look 2"])
        XCTAssertEqual(model.undoMenuTitle, "Undo Save Look")
        let savedLook = try XCTUnwrap(model.savedLooks.last)

        model.selectClip(
            trackID: fixture.target.trackID,
            clipID: fixture.target.clipID,
            mode: .replace
        )
        XCTAssertTrue(model.canApplyLook)
        XCTAssertTrue(model.applyLookToSelectedClip(lookID: savedLook.id))
        XCTAssertEqual(model.undoMenuTitle, "Undo Apply Look")

        let applied = try projectClip(fixture.target, in: XCTUnwrap(model.project))
        XCTAssertEqual(
            applied.effectStack.grade.nodes.map(\.definition),
            savedLook.grade.nodes.map(\.definition)
        )
        XCTAssertNotEqual(
            applied.effectStack.grade.nodes.map(\.id),
            savedLook.grade.nodes.map(\.id)
        )

        model.undo()
        XCTAssertTrue(
            try projectClip(fixture.target, in: XCTUnwrap(model.project))
                .effectStack.grade.nodes.isEmpty
        )
        model.undo()
        XCTAssertEqual(model.savedLooks, [existingLook])
    }

    func testFRCOMP006TrackCompositingInspectorRoutesThroughEditHistoryAndUndo() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)

        XCTAssertNil(model.selectedTrackCompositingInspector)
        XCTAssertFalse(model.updateSelectedTrackOpacityPercent(rawValue: "45"))
        XCTAssertFalse(model.updateSelectedTrackBlendMode(.difference))

        try selectSampleVideoClip(in: model)
        let originalProject = try XCTUnwrap(model.project)

        XCTAssertEqual(model.selectedTrackCompositingInspector?.trackName, "Video track 1")
        XCTAssertEqual(model.selectedTrackCompositingInspector?.blendMode, .normal)
        XCTAssertEqual(model.selectedTrackOpacityPercentValue(), "100")

        XCTAssertTrue(model.updateSelectedTrackOpacityPercent(rawValue: "45"))
        let editedOpacity = try XCTUnwrap(model.selectedTrackCompositingInspector?.opacity)
        XCTAssertEqual(
            editedOpacity.doubleValue,
            0.45,
            accuracy: 0.000_001
        )
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Track Compositing")

        model.undo()

        XCTAssertEqual(model.project, originalProject)
        XCTAssertEqual(model.selectedTrackOpacityPercentValue(), "100")

        XCTAssertTrue(model.updateSelectedTrackBlendMode(.difference))
        XCTAssertEqual(model.selectedTrackCompositingInspector?.blendMode, .difference)
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Track Compositing")

        model.undo()

        XCTAssertEqual(model.project, originalProject)
        XCTAssertEqual(model.selectedTrackCompositingInspector?.blendMode, .normal)
    }

    func testFRKEY005TransformKeyframeToggleLaneMoveAndDeleteRouteThroughEditHistory() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        try selectSampleVideoClip(in: model)
        model.scrub(to: 10)
        let selectedTransformReference = try XCTUnwrap(model.selectedTransformClipReference)

        XCTAssertFalse(model.selectedTransformHasKeyframe(.position))
        XCTAssertTrue(model.toggleSelectedTransformKeyframe(.position))
        XCTAssertTrue(model.selectedTransformHasKeyframe(.position))
        XCTAssertEqual(model.selectedTransformClipReference, selectedTransformReference)
        XCTAssertEqual(
            model.selectedTransformKeyframeLanes.filter { !$0.keyframes.isEmpty }.map(\.parameter),
            [.position]
        )
        XCTAssertEqual(try positionLane(in: model).keyframes.map(\.frame), [10])
        XCTAssertEqual(model.undoMenuTitle, "Undo Add Transform Keyframe")

        XCTAssertTrue(model.moveSelectedTransformKeyframe(parameter: .position, fromFrame: 10, toFrame: 12))
        XCTAssertEqual(try positionLane(in: model).keyframes.map(\.frame), [12])

        XCTAssertTrue(model.deleteSelectedTransformKeyframe(parameter: .position, atFrame: 12))
        XCTAssertEqual(try positionLane(in: model).keyframes, [])

        model.undo()

        XCTAssertEqual(try positionLane(in: model).keyframes.map(\.frame), [12])
    }

    func testFRXFORM007PureTransformFieldAndGestureMappingHelpers() throws {
        let transform = ClipTransform(
            position: CanvasPoint(x: RationalValue(1), y: RationalValue(2)),
            scale: .identity
        )

        let updatedScale = try XCTUnwrap(
            TransformFieldValueMapper.updatedTransform(
                .scaleXPercent,
                rawValue: "125",
                in: transform
            )
        )
        XCTAssertEqual(updatedScale.scale.x.doubleValue, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(
            TransformFieldValueMapper.stringValue(for: .scaleXPercent, in: updatedScale),
            "125"
        )

        let moved = CanvasTransformGestureMapper.updatedTransform(
            from: transform,
            gesture: CanvasTransformGesture(
                handle: .move,
                translationX: 8,
                translationY: -4,
                canvasScale: 2
            ),
            clipSize: PixelDimensions(width: 100, height: 50)
        )
        XCTAssertEqual(moved.position.x.doubleValue, 5, accuracy: 0.000_001)
        XCTAssertEqual(moved.position.y.doubleValue, 0, accuracy: 0.000_001)

        let scaled = CanvasTransformGestureMapper.updatedTransform(
            from: transform,
            gesture: CanvasTransformGesture(
                handle: .scaleBottomRight,
                translationX: 50,
                translationY: 25,
                canvasScale: 1
            ),
            clipSize: PixelDimensions(width: 100, height: 50)
        )
        XCTAssertEqual(scaled.scale.x.doubleValue, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(scaled.scale.y.doubleValue, 1.5, accuracy: 0.000_001)
    }

    func testFRTXT003CanvasTitleTextEditingIsLiveAndOneUndoStep() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        let originalProject = try XCTUnwrap(model.project)
        let firstLayout = try XCTUnwrap(model.visibleCanvasTitleBoxes.first)

        XCTAssertEqual(model.visibleCanvasTitleBoxes.count, 2)
        XCTAssertTrue(model.beginCanvasTitleTextEditing(firstLayout.reference))
        XCTAssertTrue(model.updateCanvasTitleText("Canvas", reference: firstLayout.reference))
        XCTAssertTrue(
            model.updateCanvasTitleText("Canvas edited", reference: firstLayout.reference)
        )
        XCTAssertEqual(
            model.visibleCanvasTitleBoxes.first { $0.reference == firstLayout.reference }?.box.text,
            "Canvas edited"
        )
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Title Text Box")

        model.endCanvasTitleTextEditing()
        model.undo()

        XCTAssertEqual(model.project, originalProject)
        XCTAssertEqual(
            model.visibleCanvasTitleBoxes.first { $0.reference == firstLayout.reference }?.box.text,
            "Edit me"
        )
    }

    func testFRTXT003CanvasTitleDragSnapsAndArrowKeysNudge() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        let firstLayout = try XCTUnwrap(model.visibleCanvasTitleBoxes.first)
        let actionSafeOrigin = CanvasTitlePositioning.draggedOrigin(
            for: firstLayout,
            translationX: -55,
            translationY: -41,
            canvasScale: 1
        )
        XCTAssertEqual(actionSafeOrigin.x.doubleValue, 16, accuracy: 0.000_001)
        XCTAssertEqual(actionSafeOrigin.y.doubleValue, 9, accuracy: 0.000_001)

        XCTAssertTrue(
            model.dragCanvasTitleBox(
                firstLayout.reference,
                translationX: -36,
                translationY: -30,
                canvasScale: 1
            )
        )
        let snapped = try XCTUnwrap(
            model.visibleCanvasTitleBoxes.first { $0.reference == firstLayout.reference }
        )
        XCTAssertEqual(snapped.box.origin.x.doubleValue, 32, accuracy: 0.000_001)
        XCTAssertEqual(snapped.box.origin.y.doubleValue, 18, accuracy: 0.000_001)

        XCTAssertTrue(
            model.dragCanvasTitleBox(
                firstLayout.reference,
                translationX: 35,
                translationY: 0,
                canvasScale: 1
            )
        )
        let centered = try XCTUnwrap(
            model.visibleCanvasTitleBoxes.first { $0.reference == firstLayout.reference }
        )
        XCTAssertEqual(centered.box.origin.x.doubleValue, 70, accuracy: 0.000_001)
        XCTAssertEqual(centered.box.origin.y.doubleValue, 18, accuracy: 0.000_001)

        XCTAssertTrue(
            model.nudgeCanvasTitleBox(
                firstLayout.reference,
                direction: .right,
                largeStep: true
            )
        )
        let nudged = try XCTUnwrap(
            model.visibleCanvasTitleBoxes.first { $0.reference == firstLayout.reference }
        )
        XCTAssertEqual(nudged.box.origin.x.doubleValue, 80, accuracy: 0.000_001)
        XCTAssertEqual(nudged.box.origin.y.doubleValue, 18, accuracy: 0.000_001)
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Title Text Box")
    }

    func testFRTXT003TabMovesEditingToTheNextCanvasTitleBox() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        let layouts = model.visibleCanvasTitleBoxes
        XCTAssertEqual(layouts.count, 2)
        let first = try XCTUnwrap(layouts.first)
        let second = try XCTUnwrap(layouts.last)

        XCTAssertTrue(model.beginCanvasTitleTextEditing(first.reference))
        XCTAssertEqual(
            model.editAdjacentCanvasTitleBox(from: first.reference, reverse: false),
            second.reference
        )
        XCTAssertEqual(model.editingCanvasTitleBoxReference, second.reference)
        XCTAssertEqual(
            model.editAdjacentCanvasTitleBox(from: second.reference, reverse: true),
            first.reference
        )
    }

    func testFRTXT003StaleEndCommitDoesNotClobberOtherBoxEditSession() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        let layouts = model.visibleCanvasTitleBoxes
        XCTAssertEqual(layouts.count, 2)
        let first = try XCTUnwrap(layouts.first)
        let second = try XCTUnwrap(layouts.last)

        XCTAssertTrue(model.beginCanvasTitleTextEditing(first.reference))
        XCTAssertEqual(model.editingCanvasTitleBoxReference, first.reference)

        // Direct click-to-other-box: B starts while A's textDidEndEditing is still pending.
        XCTAssertTrue(model.beginCanvasTitleTextEditing(second.reference))
        XCTAssertEqual(model.editingCanvasTitleBoxReference, second.reference)

        // Late commit from A must be a no-op (reference-scoped teardown).
        model.endCanvasTitleTextEditing(for: first.reference)
        XCTAssertEqual(model.editingCanvasTitleBoxReference, second.reference)

        // Matching commit still ends the active session.
        model.endCanvasTitleTextEditing(for: second.reference)
        XCTAssertNil(model.editingCanvasTitleBoxReference)
    }

    func testFRTXT003SafeAreaGuidesNeverEnterProjectOrRenderedOutput() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        let project = try XCTUnwrap(model.project)
        let sequence = try XCTUnwrap(model.activeSequence)
        let graphBefore = try buildRenderGraph(for: sequence, at: .zero, in: project)
        let outputHashBefore = try XCTUnwrap(graphBefore.outputNode?.contentHash)

        model.toggleCanvasSafeAreaGuides()

        XCTAssertTrue(model.canvasSafeAreaGuidesVisible)
        XCTAssertEqual(model.project, project)
        let projectAfter = try XCTUnwrap(model.project)
        let sequenceAfter = try XCTUnwrap(model.activeSequence)
        let graphAfter = try buildRenderGraph(
            for: sequenceAfter,
            at: .zero,
            in: projectAfter
        )
        XCTAssertEqual(graphAfter, graphBefore)
        XCTAssertEqual(graphAfter.outputNode?.contentHash, outputHashBefore)
    }

    func testFRTL014NFRSTAB002AppLaunchRecoversAutosavePackage() throws {
        let packageURL = try temporaryAutosavePackageURL(named: "LaunchRecovery.ajar")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        let sampleProject = try EditorAjarAppModel.makeSampleProject().get()
        let command = try autosaveTrackStateCommand(project: sampleProject)
        let recoveredProject = try apply(command, to: sampleProject)
        try AjarAutosaveStore.writeSnapshot(
            sampleProject,
            appliedCommandCount: 0,
            openMode: .editable,
            to: packageURL
        )
        try AjarAutosaveStore.appendJournalEntry(
            command: command,
            sequenceNumber: 1,
            to: packageURL
        )

        let model = EditorAjarAppModel(
            autosavePackageURL: packageURL,
            autosaveIntervalSeconds: 0
        )

        XCTAssertEqual(model.project, recoveredProject)
        XCTAssertTrue(model.isProjectEditable)
        XCTAssertFalse(model.isReadOnlyBannerVisible)
        XCTAssertTrue(model.canSaveProject)
    }

    /// Higher-minor recovery opens read-only: banner, save gated, edit refusal once (#196).
    func testFRPROJ005Issue196ReadOnlyOpenSurfacesBannerAndGatesSaveAndEdits() async throws {
        let packageURL = try temporaryAutosavePackageURL(named: "ReadOnlyOpen.ajar")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        let sampleProject = try EditorAjarAppModel.makeSampleProject().get()
        let higherMinor = AjarProjectCodec.currentSchemaMinor + 3
        let reason = AjarProjectReadOnlyReason.newerSchemaMinor(
            found: higherMinor,
            supported: AjarProjectCodec.currentSchemaMinor
        )
        try writeHigherMinorPackage(
            project: sampleProject,
            schemaMinor: higherMinor,
            to: packageURL
        )

        let model = EditorAjarAppModel(
            autosavePackageURL: packageURL,
            autosaveIntervalSeconds: 0
        )

        XCTAssertEqual(model.project?.schemaMinor, higherMinor)
        XCTAssertTrue(model.isProjectReadOnly)
        XCTAssertFalse(model.isProjectEditable)
        XCTAssertEqual(model.projectOpenMode, .readOnly(reason: reason))
        XCTAssertEqual(model.projectReadOnlyReason, reason)
        XCTAssertTrue(model.isReadOnlyBannerVisible)
        XCTAssertEqual(model.readOnlyBannerMessage, reason.message)
        XCTAssertFalse(model.canSaveProject)
        // loadMessage is set to "… (read-only)" during recovery, then immediately overwritten
        // by requestRenderForCurrentFrame() ("Rendering frame …") or Metal setup failure
        // before init returns — so it is not a stable post-init surface. The durable
        // FR-PROJ-005 copy is the banner (asserted above); first edit refusal reasserts
        // reason.message on loadMessage below.

        let sequence = try XCTUnwrap(model.activeSequence)
        let track = try XCTUnwrap(sequence.videoTracks.first)
        let projectBefore = try XCTUnwrap(model.project)

        // First edit refusal surfaces the typed reason once.
        model.setTrackState(
            sequenceID: sequence.id,
            trackID: track.id,
            enabled: false,
            locked: true,
            hidden: true
        )
        XCTAssertEqual(model.project, projectBefore)
        XCTAssertEqual(model.loadMessage, reason.message)
        XCTAssertTrue(model.isReadOnlyBannerVisible)

        // Subsequent edits stay no-ops without spamming loadMessage changes.
        let messageAfterFirstRefusal = model.loadMessage
        model.setTrackState(
            sequenceID: sequence.id,
            trackID: track.id,
            enabled: true,
            locked: false,
            hidden: false
        )
        XCTAssertEqual(model.loadMessage, messageAfterFirstRefusal)
        XCTAssertEqual(model.project, projectBefore)

        // Autosave must not rewrite a higher-minor package.
        await model.autosaveCheckpointForTesting()
        let reloaded = try AjarAutosaveStore.recoverProject(from: packageURL)
        XCTAssertEqual(reloaded.openMode, .readOnly(reason: reason))
        XCTAssertEqual(reloaded.project.schemaMinor, higherMinor)
        XCTAssertEqual(reloaded.project, projectBefore)

        model.dismissReadOnlyBanner()
        XCTAssertFalse(model.isReadOnlyBannerVisible)
        XCTAssertNil(model.readOnlyBannerMessage)

        // A later edit re-presents the banner without changing the one-shot loadMessage.
        model.setTrackState(
            sequenceID: sequence.id,
            trackID: track.id,
            enabled: false,
            locked: false,
            hidden: false
        )
        XCTAssertTrue(model.isReadOnlyBannerVisible)
        XCTAssertEqual(model.loadMessage, messageAfterFirstRefusal)
    }

    func testFRTL014AppAutosavesSignificantEditToRecoverablePackage() async throws {
        let packageURL = try temporaryAutosavePackageURL(named: "EditAutosave.ajar")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        let model = EditorAjarAppModel(
            autosavePackageURL: packageURL,
            autosaveIntervalSeconds: 0
        )
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)

        model.setTrackState(
            sequenceID: sequence.id,
            trackID: videoTrack.id,
            enabled: false,
            locked: true,
            hidden: true
        )
        await model.autosaveCheckpointForTesting()

        let recovered = try AjarAutosaveStore.recoverProject(from: packageURL)
        XCTAssertTrue(recovered.isComplete)
        XCTAssertEqual(recovered.latestCommandCount, 1)
        XCTAssertEqual(recovered.project, model.project)
    }

    private func makeInteractionSequence() throws -> AjarCore.Sequence {
        let frameRate = try FrameRate(frames: 30)
        let trackID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000a001"))
        let markerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000b001"))
        return Sequence(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000c001")),
            name: "Interaction Sequence",
            videoTracks: [
                Track(
                    id: trackID,
                    kind: .video,
                    items: [
                        .clip(try makeInteractionClip(
                            id: "00000000-0000-0000-0000-00000000d001",
                            name: "First",
                            startFrame: 0,
                            durationFrames: 30,
                            frameRate: frameRate
                        )),
                        .clip(try makeInteractionClip(
                            id: "00000000-0000-0000-0000-00000000d002",
                            name: "Second",
                            startFrame: 45,
                            durationFrames: 15,
                            frameRate: frameRate
                        )),
                        .clip(try makeInteractionClip(
                            id: "00000000-0000-0000-0000-00000000d003",
                            name: "Third",
                            startFrame: 60,
                            durationFrames: 30,
                            frameRate: frameRate
                        )),
                    ]
                )
            ],
            audioTracks: [],
            markers: [
                Marker(
                    id: markerID,
                    time: try RationalTime.atFrame(30, frameRate: frameRate),
                    name: "Marker"
                )
            ],
            timebase: frameRate
        )
    }

    private func makeInteractionClip(
        id: String,
        name: String,
        startFrame: Int64,
        durationFrames: Int64,
        frameRate: FrameRate
    ) throws -> Clip {
        let duration = try frameRate.duration(ofFrames: durationFrames)
        return Clip(
            id: try XCTUnwrap(UUID(uuidString: id)),
            source: .media(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000e001"))),
            sourceRange: try TimeRange(start: .zero, duration: duration),
            timelineRange: try TimeRange(
                start: try RationalTime.atFrame(startFrame, frameRate: frameRate),
                duration: duration
            ),
            kind: .video,
            name: name
        )
    }

    private func autosaveTrackStateCommand(project: Project) throws -> EditCommand {
        let sequence = try XCTUnwrap(project.sequences.first)
        let track = try XCTUnwrap(sequence.videoTracks.first)
        return .setTrackState(
            sequenceID: sequence.id,
            trackID: track.id,
            state: TrackStatePatch(enabled: false, locked: true, hidden: true)
        )
    }

    private func temporaryAutosavePackageURL(named name: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-app-autosave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL.appendingPathComponent(name, isDirectory: true)
    }

    /// Writes a higher-minor package without going through encode (which rewrites current minor).
    private func writeHigherMinorPackage(
        project: Project,
        schemaMinor: Int,
        to packageURL: URL
    ) throws {
        let document = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            schemaMinor: schemaMinor,
            settings: project.settings,
            mediaPool: [],
            sequences: project.sequences,
            looks: project.looks
        )
        let manifest = AjarMediaManifest(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            schemaMinor: schemaMinor,
            media: project.mediaPool
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        try encoder.encode(document).write(
            to: packageURL.appendingPathComponent("project.json")
        )
        try encoder.encode(manifest).write(
            to: packageURL.appendingPathComponent("media.json")
        )
    }

    private func makeGradeAppFixture() throws -> GradeAppFixture {
        var project = try EditorAjarAppModel.makeSampleProject().get()
        let sequence = try XCTUnwrap(project.sequences.first)
        let sourceTrack = try XCTUnwrap(sequence.videoTracks.first)
        let targetTrack = try XCTUnwrap(sequence.videoTracks.dropFirst().first)
        let sourceClip = try firstClip(in: sourceTrack)
        let sourceReference = ProjectClipReference(
            sequenceID: sequence.id,
            trackID: sourceTrack.id,
            clipID: sourceClip.id
        )
        let targetReference = ProjectClipReference(
            sequenceID: sequence.id,
            trackID: targetTrack.id,
            clipID: try appTestUUID("00000000-0000-0000-0000-000000007102")
        )
        let gradeNode = ClipEffectNode(
            id: try appTestUUID("00000000-0000-0000-0000-000000007101"),
            definition: .colorAdjust(
                ClipColorAdjustParameters(
                    brightness: try RationalValue(numerator: 1, denominator: 4)
                )
            )
        )
        project = try apply(
            .addClipEffectNode(
                sequenceID: sourceReference.sequenceID,
                trackID: sourceReference.trackID,
                clipID: sourceReference.clipID,
                node: gradeNode
            ),
            to: project
        )
        // V2 already holds the FR-TXT-003 title clip at [0, 60). Abut the grade target
        // at [60, 90) so copy/paste/look tests do not trip itemsOverlap.
        let targetDurationFrames: Int64 = 30
        let targetDuration = try sequence.timebase.duration(ofFrames: targetDurationFrames)
        let targetStart = try trackTimelineEnd(targetTrack)
        let targetSourceRange = try TimeRange(start: .zero, duration: targetDuration)
        let targetTimelineRange = try TimeRange(start: targetStart, duration: targetDuration)
        let targetClip = Clip(
            id: targetReference.clipID,
            source: sourceClip.source,
            sourceRange: targetSourceRange,
            timelineRange: targetTimelineRange,
            kind: .video,
            name: "Grade target"
        )
        project = try apply(
            .addClip(
                sequenceID: targetReference.sequenceID,
                trackID: targetReference.trackID,
                clip: targetClip
            ),
            to: project
        )
        return GradeAppFixture(
            project: project,
            source: sourceReference,
            target: targetReference
        )
    }

    private func trackTimelineEnd(_ track: Track) throws -> RationalTime {
        var end = RationalTime.zero
        for item in track.items {
            guard case .clip(let clip) = item else {
                continue
            }
            let clipEnd = try clip.timelineRange.end()
            if clipEnd > end {
                end = clipEnd
            }
        }
        return end
    }

    private func loadGradeAppModel(
        project: Project,
        named packageName: String
    ) throws -> (model: EditorAjarAppModel, packageDirectory: URL) {
        let packageURL = try temporaryAutosavePackageURL(named: packageName)
        try AjarAutosaveStore.writeSnapshot(
            project,
            appliedCommandCount: 0,
            openMode: .editable,
            to: packageURL
        )
        return (
            EditorAjarAppModel(
                autosavePackageURL: packageURL,
                autosaveIntervalSeconds: 0
            ),
            packageURL.deletingLastPathComponent()
        )
    }

    private func projectClip(
        _ reference: ProjectClipReference,
        in project: Project
    ) throws -> Clip {
        let sequence = try XCTUnwrap(
            project.sequences.first { $0.id == reference.sequenceID }
        )
        let track = try XCTUnwrap(
            (sequence.videoTracks + sequence.audioTracks).first { $0.id == reference.trackID }
        )
        return try XCTUnwrap(
            track.items.compactMap { item -> Clip? in
                guard case .clip(let clip) = item, clip.id == reference.clipID else {
                    return nil
                }
                return clip
            }.first
        )
    }

    private func appTestUUID(_ rawValue: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: rawValue))
    }

    private func sampleLinkedSelection(
        in model: EditorAjarAppModel
    ) throws -> SampleLinkedSelection {
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
        let audioTrack = try XCTUnwrap(sequence.audioTracks.first)
        return SampleLinkedSelection(
            frameRate: sequence.timebase,
            videoTrackID: videoTrack.id,
            audioTrackID: audioTrack.id,
            videoClip: try firstClip(in: videoTrack),
            audioClip: try firstClip(in: audioTrack)
        )
    }

    @discardableResult
    private func selectSampleVideoClip(
        in model: EditorAjarAppModel
    ) throws -> Clip {
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
        let clip = try firstClip(in: videoTrack)
        model.selectClip(trackID: videoTrack.id, clipID: clip.id, mode: .replace)
        return clip
    }

    private func positionLane(in model: EditorAjarAppModel) throws -> TransformKeyframeLane {
        try XCTUnwrap(
            model.selectedTransformKeyframeLanes.first { lane in
                lane.parameter == .position
            }
        )
    }

    private func firstClip(in track: Track) throws -> Clip {
        for item in track.items {
            if case .clip(let clip) = item {
                return clip
            }
        }
        return try XCTUnwrap(nil)
    }

    private func assertFrameRange(
        _ range: TimeRange,
        startFrame: Int64,
        durationFrames: Int64,
        frameRate: FrameRate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try range.start.frameIndex(at: frameRate, rounding: .nearestOrAwayFromZero),
            startFrame,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try range.duration.frameIndex(at: frameRate, rounding: .nearestOrAwayFromZero),
            durationFrames,
            file: file,
            line: line
        )
    }

    private static func durationFrames(for sequence: Sequence) throws -> Int64 {
        var endFrame: Int64 = 1
        for track in sequence.videoTracks + sequence.audioTracks {
            for item in track.items {
                guard case .clip(let clip) = item else {
                    continue
                }
                endFrame = max(
                    endFrame,
                    try clip.timelineRange.end().frameIndex(
                        at: sequence.timebase,
                        rounding: .nearestOrAwayFromZero
                    )
                )
            }
        }
        return endFrame
    }
}

private struct SampleLinkedSelection {
    let frameRate: FrameRate
    let videoTrackID: UUID
    let audioTrackID: UUID
    let videoClip: Clip
    let audioClip: Clip
}

private struct GradeAppFixture {
    let project: Project
    let source: ProjectClipReference
    let target: ProjectClipReference
}

private final class FakeAudioCoordinator: EditorAjarAudioCoordinating {
    private(set) var startedFrames: [Int64] = []
    private(set) var seekFrames: [Int64] = []
    private(set) var ensuredFrames: [Int64] = []
    private(set) var stopCount = 0

    func start(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
        startedFrames.append(playheadFrame)
    }

    func stop() {
        stopCount += 1
    }

    func publishSeek(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
        seekFrames.append(playheadFrame)
    }

    func ensurePlaybackPlan(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
        ensuredFrames.append(playheadFrame)
    }
}

private final class FakeAudioOutputDriver: EditorAjarAudioOutputDriving {
    private(set) var publishedFrameCounts: [Int] = []
    private(set) var publishWasOnMainThread: [Bool] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    var publishCount: Int {
        publishedFrameCounts.count
    }

    func publish(_ plan: RealtimeAudioRenderPlan) throws {
        publishedFrameCounts.append(plan.safetyReport().preparedFrameCount)
        publishWasOnMainThread.append(Thread.isMainThread)
    }

    func start() throws {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func safetyReport() -> RealtimeAudioSafetyReport? {
        nil
    }
}
