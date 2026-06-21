// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
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
        XCTAssertEqual(model.project?.mediaPool.count, 1)
        XCTAssertEqual(model.activeSequence?.videoTracks.count, 2)
        XCTAssertEqual(model.activeSequence?.audioTracks.count, 2)
        XCTAssertGreaterThan(model.durationFrames, 1)
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

    func testFRTL014NFRSTAB002AppLaunchRecoversAutosavePackage() throws {
        let packageURL = try temporaryAutosavePackageURL(named: "LaunchRecovery.ajar")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        let sampleProject = try EditorAjarAppModel.makeSampleProject().get()
        let command = try autosaveTrackStateCommand(project: sampleProject)
        let recoveredProject = try apply(command, to: sampleProject)
        try AjarAutosaveStore.writeSnapshot(
            sampleProject,
            appliedCommandCount: 0,
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
}
