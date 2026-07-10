// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import SwiftUI

@MainActor
final class EditorAjarAppModel: ObservableObject {
    @Published private(set) var project: Project?
    @Published private(set) var isPlaying = false
    @Published private(set) var playheadFrame: Int64 = 0
    @Published private(set) var durationFrames: Int64 = 1
    @Published private(set) var presentedTexture: MTLTexture?
    @Published private(set) var loadMessage: String
    @Published private(set) var timelineState = TimelineInteractionState()
    @Published private(set) var activeSequenceID: UUID?
    @Published private(set) var canvasSafeAreaGuidesVisible = false
    @Published private(set) var selectedCanvasTitleBoxReference: CanvasTitleBoxReference?
    @Published private(set) var editingCanvasTitleBoxReference: CanvasTitleBoxReference?

    private var playbackController: EditorAjarPlaybackController?
    private var renderPipeline: EditorAjarRenderPipeline?
    private var displayLinkDriver: EditorAjarDisplayLinkDriver?
    private var editHistory: EditHistory?
    private let autosaveCoordinator: EditorAjarAutosaveCoordinator?
    private let autosaveIntervalSeconds: TimeInterval
    private let audioCoordinator: (any EditorAjarAudioCoordinating)?
    private var autosaveLoopTask: Task<Void, Never>?
    private var autosaveWriteTask: Task<Void, Never>?
    private var autosaveCommandCount = 0
    private var renderGeneration = 0
    private var sequenceContexts: [UUID: SequenceEditingContext] = [:]
    private var canvasTitleEditingUndoBaseline: Int?

    init(
        autosavePackageURL: URL? = nil,
        autosaveIntervalSeconds: TimeInterval = 5.0,
        audioCoordinator: (any EditorAjarAudioCoordinating)? = nil
    ) {
        self.autosaveIntervalSeconds = autosaveIntervalSeconds
        if let autosavePackageURL {
            autosaveCoordinator = EditorAjarAutosaveCoordinator(packageURL: autosavePackageURL)
        } else {
            autosaveCoordinator = nil
        }
        self.audioCoordinator = audioCoordinator ?? Self.makeAudioCoordinator()

        loadMessage = "Loading sample project"

        var initialProject: Project?
        if let autosavePackageURL,
           AjarAutosaveStore.hasRecoverableSnapshot(at: autosavePackageURL)
        {
            do {
                let recovery = try AjarAutosaveStore.recoverProject(from: autosavePackageURL)
                initialProject = recovery.project
                autosaveCommandCount = recovery.latestCommandCount
                loadMessage = recovery.isComplete
                    ? "Recovered autosave"
                    : "Recovered autosave to last good state"
            } catch {
                loadMessage = "Autosave recovery unavailable: \(error)"
            }
        }

        if initialProject == nil {
            switch Self.makeSampleProject() {
            case .success(let project):
                initialProject = project
                loadMessage = "Sample project loaded"
            case .failure(let error):
                loadMessage = "Sample project unavailable: \(error)"
            }
        }

        if let initialProject {
            project = initialProject
            editHistory = EditHistory(project: initialProject)
            if let sequence = initialProject.sequences.first {
                activeSequenceID = sequence.id
                durationFrames = Self.durationFrames(for: sequence)
                playbackController = EditorAjarPlaybackController(
                    frameRate: sequence.timebase,
                    durationFrames: durationFrames
                )
                persistActiveSequenceContext()
            }
        } else {
            project = nil
        }

        do {
            renderPipeline = try EditorAjarRenderPipeline()
            if project != nil, loadMessage == "Loading sample project" {
                loadMessage = "Sample project loaded"
            }
        } catch {
            loadMessage = "Metal playback unavailable: \(error)"
        }

        displayLinkDriver = EditorAjarDisplayLinkDriver { [weak self] deltaSeconds in
            self?.displayLinkTick(deltaSeconds)
        }
        if let project {
            scheduleAutosaveCheckpoint(project: project)
        }
        startAutosaveLoop()
        requestRenderForCurrentFrame()
    }

    deinit {
        audioCoordinator?.stop()
        autosaveLoopTask?.cancel()
        autosaveWriteTask?.cancel()
    }

    var canUndo: Bool {
        (editHistory?.undoCount ?? 0) > 0
    }

    var canRedo: Bool {
        (editHistory?.redoCount ?? 0) > 0
    }

    var undoMenuTitle: String {
        editMenuTitle(prefix: "Undo", command: editHistory?.nextUndoCommand)
    }

    var redoMenuTitle: String {
        editMenuTitle(prefix: "Redo", command: editHistory?.nextRedoCommand)
    }

    var activeSequence: Sequence? {
        guard let project else {
            return nil
        }
        if let activeSequenceID,
           let sequence = project.sequences.first(where: { $0.id == activeSequenceID })
        {
            return sequence
        }
        return project.sequences.first
    }

    var activeSequenceName: String {
        activeSequence?.name ?? "No Sequence"
    }

    var sequenceTabs: [SequenceTab] {
        guard let project else {
            return []
        }
        let activeID = activeSequence?.id
        let canClose = project.sequences.count > 1
        return project.sequences.map { sequence in
            SequenceTab(
                id: sequence.id,
                title: sequence.name,
                isActive: sequence.id == activeID,
                canClose: canClose
            )
        }
    }

    var canCloseActiveSequence: Bool {
        (project?.sequences.count ?? 0) > 1
    }

    var projectSummary: String {
        guard let project else {
            return "No project"
        }

        let sequenceCount = project.sequences.count
        let mediaCount = project.mediaPool.count
        let sequenceLabel = sequenceCount == 1 ? "sequence" : "sequences"
        return "\(sequenceCount) \(sequenceLabel), \(mediaCount) media items"
    }

    var frameRateDescription: String {
        playbackController?.frameRateDescription ?? "--"
    }

    var playheadDescription: String {
        "Frame \(playheadFrame)"
    }

    var timelineSnappingEnabled: Bool {
        timelineState.snappingEnabled
    }

    var timelineSelectedClipCount: Int {
        timelineState.selectedClips.count
    }

    var selectedClipReference: TimelineClipReference? {
        guard timelineState.selectedClips.count == 1 else {
            return nil
        }
        return timelineState.selectedClips.first
    }

    var selectedClip: Clip? {
        guard let selectedClipReference,
              let sequence = activeSequence
        else {
            return nil
        }
        return Self.clip(selectedClipReference, in: sequence)
    }

    var selectedTransformClipReference: TimelineClipReference? {
        guard let selectedClipReference,
              selectedClip?.kind == .video
        else {
            return nil
        }
        return selectedClipReference
    }

    var selectedTransformInspector: SelectedTransformInspectorState? {
        guard let selectedClip,
              selectedClip.kind == .video,
              let sequence = activeSequence,
              let time = playheadTime(in: sequence)
        else {
            return nil
        }

        return SelectedTransformInspectorState(
            clipName: selectedClip.name,
            transform: selectedClip.transformAnimation.value(at: time)
        )
    }

    var selectedTrackCompositingInspector: SelectedTrackCompositingInspectorState? {
        guard let reference = selectedTransformClipReference,
              let sequence = activeSequence,
              let trackIndex = sequence.videoTracks.firstIndex(where: { $0.id == reference.trackID }),
              let time = playheadTime(in: sequence)
        else {
            return nil
        }

        let track = sequence.videoTracks[trackIndex]
        return SelectedTrackCompositingInspectorState(
            trackName: "Video track \(trackIndex + 1)",
            opacity: track.opacity.value(at: time),
            blendMode: track.blendMode
        )
    }

    var selectedTransformKeyframeLanes: [TransformKeyframeLane] {
        guard let selectedClip,
              selectedClip.kind == .video,
              let sequence = activeSequence
        else {
            return []
        }

        return TransformKeyframeLane.makeLanes(
            animation: selectedClip.transformAnimation,
            frameRate: sequence.timebase,
            pixelsPerFrame: timelineState.pixelsPerFrame
        )
    }

    var selectedCanvasTransformLayout: CanvasClipTransformLayout? {
        guard let project,
              let selectedClip,
              selectedClip.kind == .video,
              let sequence = activeSequence,
              let time = playheadTime(in: sequence),
              let clipDimensions = Self.mediaDimensions(for: selectedClip, in: project)
        else {
            return nil
        }

        return CanvasClipTransformLayout(
            canvasSize: project.settings.resolution,
            clipSize: clipDimensions,
            transform: selectedClip.transformAnimation.value(at: time)
        )
    }

    var selectedClipIsLinked: Bool {
        selectedClip?.linkGroupID != nil
    }

    var canvasDimensions: PixelDimensions? {
        project?.settings.resolution
    }

    var canvasAspectRatio: Double {
        guard let canvasDimensions, canvasDimensions.height > 0 else {
            return 16.0 / 9.0
        }
        return Double(canvasDimensions.width) / Double(canvasDimensions.height)
    }

    var visibleCanvasTitleBoxes: [CanvasTitleBoxLayout] {
        guard let project,
              let sequence = activeSequence,
              let time = playheadTime(in: sequence)
        else {
            return []
        }

        var layouts: [CanvasTitleBoxLayout] = []
        for track in sequence.videoTracks where track.enabled && !track.hidden {
            for item in track.items {
                guard case .clip(let clip) = item,
                      (try? clip.timelineRange.contains(time)) == true,
                      case .title(let title) = clip.source
                else {
                    continue
                }

                let transform = clip.transformAnimation.value(at: time)
                for (boxIndex, box) in title.boxes.enumerated() {
                    layouts.append(
                        CanvasTitleBoxLayout(
                            canvasSize: project.settings.resolution,
                            reference: CanvasTitleBoxReference(
                                sequenceID: sequence.id,
                                trackID: track.id,
                                clipID: clip.id,
                                boxID: box.id
                            ),
                            box: box,
                            boxIndex: boxIndex,
                            clipName: clip.name,
                            clipTransform: transform,
                            isEditable: !track.locked
                        )
                    )
                }
            }
        }
        return layouts
    }

    var selectedMarker: Marker? {
        guard let selectedMarkerID = timelineState.selectedMarkerID else {
            return nil
        }
        return activeSequence?.markers.first { $0.id == selectedMarkerID }
    }

    var timelineRangeDescription: String {
        switch (timelineState.selectionInFrame, timelineState.selectionOutFrame) {
        case (.some(let inFrame), .some(let outFrame)):
            let startFrame = min(inFrame, outFrame)
            let endFrame = max(inFrame, outFrame)
            return "Range \(startFrame)-\(endFrame)"
        case (.some(let inFrame), .none):
            return "Range in \(inFrame)"
        case (.none, .some(let outFrame)):
            return "Range out \(outFrame)"
        case (.none, .none):
            return "No range"
        }
    }

    var metalDevice: MTLDevice? {
        renderPipeline?.device
    }

    func togglePlayback() {
        isPlaying.toggle()
        if isPlaying {
            startAudioPlayback()
            displayLinkDriver?.start()
        } else {
            stopAudioPlayback()
            displayLinkDriver?.stop()
        }
    }

    @discardableResult
    func selectSequence(_ sequenceID: UUID) -> Bool {
        guard let project,
              let sequence = project.sequences.first(where: { $0.id == sequenceID })
        else {
            return false
        }

        persistActiveSequenceContext()
        isPlaying = false
        stopAudioPlayback()
        displayLinkDriver?.stop()
        restoreActiveSequenceContext(for: sequence)
        requestRenderForCurrentFrame()
        return true
    }

    @discardableResult
    func addSequence() -> Bool {
        guard let project else {
            return false
        }

        let sequence = Self.emptySequence(
            name: Self.nextSequenceName(in: project),
            frameRate: project.settings.frameRate
        )
        guard applyEdit(.addSequence(sequence)) else {
            return false
        }

        return selectSequence(sequence.id)
    }

    @discardableResult
    func closeActiveSequence() -> Bool {
        guard let sequenceID = activeSequence?.id else {
            return false
        }
        return closeSequence(sequenceID)
    }

    @discardableResult
    func closeSequence(_ sequenceID: UUID) -> Bool {
        guard let project else {
            return false
        }
        let replacementID = Self.replacementSequenceID(
            afterRemoving: sequenceID,
            from: project
        )
        let isRemovingActiveSequence = activeSequence?.id == sequenceID

        guard applyEdit(.removeSequence(sequenceID: sequenceID)) else {
            return false
        }

        if isRemovingActiveSequence, let replacementID {
            selectSequence(replacementID)
        }
        return true
    }

    func stepBackward() {
        isPlaying = false
        stopAudioPlayback()
        displayLinkDriver?.stop()
        playbackController?.stepBackward()
        syncPlayheadFromController()
        publishAudioPlanForCurrentFrame()
        requestRenderForCurrentFrame()
    }

    func stepForward() {
        isPlaying = false
        stopAudioPlayback()
        displayLinkDriver?.stop()
        playbackController?.stepForward()
        syncPlayheadFromController()
        publishAudioPlanForCurrentFrame()
        requestRenderForCurrentFrame()
    }

    func scrub(to frame: Int64) {
        isPlaying = false
        stopAudioPlayback()
        displayLinkDriver?.stop()
        playbackController?.scrub(to: frame)
        syncPlayheadFromController()
        publishAudioPlanForCurrentFrame()
        requestRenderForCurrentFrame()
    }

    func scrubTimeline(xPosition: Double, snappingDisabled: Bool = false) {
        let proposedFrame = TimelineInteraction.frame(
            atX: xPosition,
            pixelsPerFrame: timelineState.pixelsPerFrame,
            durationFrames: durationFrames
        )
        let frame: Int64
        if timelineState.snappingEnabled && !snappingDisabled, let sequence = activeSequence {
            frame = TimelineInteraction.snappedFrame(
                proposedFrame: proposedFrame,
                targets: TimelineInteraction.snapTargets(
                    in: sequence,
                    playheadFrame: playheadFrame
                ),
                toleranceFrames: timelineState.snapToleranceFrames
            )
        } else {
            frame = proposedFrame
        }
        scrub(to: frame)
    }

    func timelineClipLayouts(for track: Track) -> [TimelineClipLayout] {
        guard let sequence = activeSequence else {
            return []
        }
        return TimelineInteraction.clipLayouts(
            for: track,
            frameRate: sequence.timebase,
            pixelsPerFrame: timelineState.pixelsPerFrame
        )
    }

    func timelineContentWidth(minimumWidth: Double) -> Double {
        TimelineInteraction.contentWidth(
            durationFrames: durationFrames,
            pixelsPerFrame: timelineState.pixelsPerFrame,
            minimumWidth: minimumWidth
        )
    }

    func timelineMarkerLayouts() -> [TimelineMarkerLayout] {
        guard let sequence = activeSequence else {
            return []
        }

        return sequence.markers.compactMap { marker in
            guard let frame = try? marker.time.frameIndex(
                at: sequence.timebase,
                rounding: .nearestOrAwayFromZero
            ) else {
                return nil
            }

            return TimelineMarkerLayout(
                markerID: marker.id,
                name: marker.name,
                note: marker.note,
                color: marker.color,
                frame: frame,
                xPosition: timelineXPosition(for: frame)
            )
        }
    }

    func timelineXPosition(for frame: Int64) -> Double {
        TimelineInteraction.xPosition(frame: frame, pixelsPerFrame: timelineState.pixelsPerFrame)
    }

    func isClipSelected(_ reference: TimelineClipReference) -> Bool {
        timelineState.selectedClips.contains(reference)
    }

    func selectClip(trackID: UUID, clipID: UUID, mode: TimelineSelectionMode) {
        guard let sequence = activeSequence else {
            return
        }
        let reference = TimelineClipReference(trackID: trackID, clipID: clipID)
        let result = TimelineInteraction.reducedSelection(
            currentSelection: timelineState.selectedClips,
            anchor: timelineState.selectionAnchor,
            visibleClipReferences: TimelineInteraction.clipReferences(in: sequence),
            reference: reference,
            mode: mode
        )
        timelineState.selectedClips = result.selectedClips
        timelineState.selectionAnchor = result.anchor
        timelineState.selectedMarkerID = nil
        persistActiveSequenceContext()
    }

    @discardableResult
    func beginCanvasTitleTextEditing(_ reference: CanvasTitleBoxReference) -> Bool {
        guard let layout = canvasTitleLayout(for: reference), layout.isEditable else {
            return false
        }

        selectClip(trackID: reference.trackID, clipID: reference.clipID, mode: .replace)
        selectedCanvasTitleBoxReference = reference
        editingCanvasTitleBoxReference = reference
        canvasTitleEditingUndoBaseline = editHistory?.undoCount
        return true
    }

    func endCanvasTitleTextEditing() {
        editingCanvasTitleBoxReference = nil
        canvasTitleEditingUndoBaseline = nil
    }

    @discardableResult
    func selectCanvasTitleBox(_ reference: CanvasTitleBoxReference) -> Bool {
        guard let layout = canvasTitleLayout(for: reference), layout.isEditable else {
            return false
        }

        if editingCanvasTitleBoxReference != reference {
            endCanvasTitleTextEditing()
        }
        selectClip(trackID: reference.trackID, clipID: reference.clipID, mode: .replace)
        selectedCanvasTitleBoxReference = reference
        return true
    }

    @discardableResult
    func editAdjacentCanvasTitleBox(
        from reference: CanvasTitleBoxReference,
        reverse: Bool
    ) -> CanvasTitleBoxReference? {
        let editable = visibleCanvasTitleBoxes.filter(\.isEditable)
        guard !editable.isEmpty,
              let currentIndex = editable.firstIndex(where: { $0.reference == reference })
        else {
            return nil
        }

        let offset = reverse ? editable.count - 1 : 1
        let nextIndex = (currentIndex + offset) % editable.count
        let nextReference = editable[nextIndex].reference
        endCanvasTitleTextEditing()
        return beginCanvasTitleTextEditing(nextReference) ? nextReference : nil
    }

    @discardableResult
    func updateCanvasTitleText(
        _ text: String,
        reference: CanvasTitleBoxReference
    ) -> Bool {
        guard let layout = canvasTitleLayout(for: reference),
              layout.isEditable,
              layout.box.text != text
        else {
            return canvasTitleLayout(for: reference)?.box.text == text
        }

        let replacement = CanvasTitleBoxEditor.copying(layout.box, text: text)
        let undoCount = editHistory?.undoCount ?? 0
        let shouldCoalesce = editingCanvasTitleBoxReference == reference
            && canvasTitleEditingUndoBaseline.map { undoCount > $0 } == true
        let applied = applyEdit(
            .setTitleTextBox(
                sequenceID: reference.sequenceID,
                trackID: reference.trackID,
                clipID: reference.clipID,
                box: replacement
            ),
            coalescingWithPrevious: shouldCoalesce
        )
        return applied
    }

    @discardableResult
    func dragCanvasTitleBox(
        _ reference: CanvasTitleBoxReference,
        translationX: Double,
        translationY: Double,
        canvasScale: Double
    ) -> Bool {
        guard let layout = canvasTitleLayout(for: reference), layout.isEditable else {
            return false
        }

        let origin = CanvasTitlePositioning.draggedOrigin(
            for: layout,
            translationX: translationX,
            translationY: translationY,
            canvasScale: canvasScale
        )
        return setCanvasTitleBoxOrigin(origin, layout: layout)
    }

    @discardableResult
    func nudgeCanvasTitleBox(
        _ reference: CanvasTitleBoxReference,
        direction: CanvasTitleNudgeDirection,
        largeStep: Bool
    ) -> Bool {
        guard let layout = canvasTitleLayout(for: reference), layout.isEditable else {
            return false
        }

        let origin = CanvasTitlePositioning.nudgedOrigin(
            for: layout,
            direction: direction,
            step: largeStep ? 10 : 1
        )
        return setCanvasTitleBoxOrigin(origin, layout: layout)
    }

    func toggleCanvasSafeAreaGuides() {
        canvasSafeAreaGuidesVisible.toggle()
    }

    func selectAllClips(on trackID: UUID) {
        guard let sequence = activeSequence else {
            return
        }
        let selectedClips = TimelineInteraction.clipReferences(in: sequence)
            .filter { $0.trackID == trackID }
        timelineState.selectedClips = Set(selectedClips)
        timelineState.selectionAnchor = selectedClips.first
        timelineState.selectedMarkerID = nil
        persistActiveSequenceContext()
    }

    func transformFieldValue(_ field: TransformInspectorField) -> String {
        guard let transform = selectedTransformInspector?.transform else {
            return ""
        }
        return TransformFieldValueMapper.stringValue(for: field, in: transform)
    }

    func selectedTrackOpacityPercentValue() -> String {
        guard let state = selectedTrackCompositingInspector else {
            return ""
        }
        return TrackCompositingValueMapper.percentString(from: state.opacity)
    }

    @discardableResult
    func updateSelectedTransformField(_ field: TransformInspectorField, rawValue: String) -> Bool {
        guard let transform = selectedTransformInspector?.transform,
              let replacement = TransformFieldValueMapper.updatedTransform(
                field,
                rawValue: rawValue,
                in: transform
              )
        else {
            return false
        }

        return updateSelectedClipTransform(replacement)
    }

    @discardableResult
    func updateSelectedClipBlendMode(_ blendMode: ClipBlendMode) -> Bool {
        guard let transform = selectedTransformInspector?.transform else {
            return false
        }

        return updateSelectedClipTransform(
            TransformEditor.copying(transform, blendMode: blendMode)
        )
    }

    @discardableResult
    func updateSelectedTrackOpacityPercent(rawValue: String) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let reference = selectedTransformClipReference,
              let opacity = TrackCompositingValueMapper.percent(rawValue)
        else {
            return false
        }

        return applyEdit(
            .setTrackCompositing(
                sequenceID: sequenceID,
                trackID: reference.trackID,
                compositing: TrackCompositingPatch(opacity: .constant(opacity))
            )
        )
    }

    @discardableResult
    func updateSelectedTrackBlendMode(_ blendMode: ClipBlendMode) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let reference = selectedTransformClipReference
        else {
            return false
        }

        return applyEdit(
            .setTrackCompositing(
                sequenceID: sequenceID,
                trackID: reference.trackID,
                compositing: TrackCompositingPatch(blendMode: blendMode)
            )
        )
    }

    @discardableResult
    func updateSelectedClipFlip(horizontal: Bool? = nil, vertical: Bool? = nil) -> Bool {
        guard let transform = selectedTransformInspector?.transform else {
            return false
        }
        let flip = ClipFlip(
            horizontal: horizontal ?? transform.flip.horizontal,
            vertical: vertical ?? transform.flip.vertical
        )
        return updateSelectedClipTransform(TransformEditor.copying(transform, flip: flip))
    }

    @discardableResult
    func applyCanvasTransformGesture(_ gesture: CanvasTransformGesture) -> Bool {
        guard let layout = selectedCanvasTransformLayout else {
            return false
        }

        let transform = CanvasTransformGestureMapper.updatedTransform(
            from: layout.transform,
            gesture: gesture,
            clipSize: layout.clipSize
        )
        return updateSelectedClipTransform(transform)
    }

    func selectedTransformHasKeyframe(_ parameter: ClipTransformParameter) -> Bool {
        guard let sequence = activeSequence,
              let time = playheadTime(in: sequence),
              let selectedClip
        else {
            return false
        }

        return TransformKeyframeLookup.keyframe(
            parameter: parameter,
            at: time,
            in: selectedClip.transformAnimation
        ) != nil
    }

    @discardableResult
    func toggleSelectedTransformKeyframe(_ parameter: ClipTransformParameter) -> Bool {
        guard let sequence = activeSequence,
              let time = playheadTime(in: sequence)
        else {
            return false
        }

        if selectedTransformHasKeyframe(parameter) {
            return deleteSelectedTransformKeyframe(parameter: parameter, at: time)
        }
        return addSelectedTransformKeyframe(parameter: parameter, at: time)
    }

    @discardableResult
    func addSelectedTransformKeyframe(
        parameter: ClipTransformParameter,
        atFrame frame: Int64
    ) -> Bool {
        guard let sequence = activeSequence,
              let time = try? RationalTime.atFrame(frame, frameRate: sequence.timebase)
        else {
            return false
        }
        return addSelectedTransformKeyframe(parameter: parameter, at: time)
    }

    @discardableResult
    func moveSelectedTransformKeyframe(
        parameter: ClipTransformParameter,
        fromFrame: Int64,
        toFrame: Int64
    ) -> Bool {
        guard let sequence = activeSequence,
              let fromTime = try? RationalTime.atFrame(fromFrame, frameRate: sequence.timebase),
              let toTime = try? RationalTime.atFrame(
                max(0, min(toFrame, max(0, durationFrames - 1))),
                frameRate: sequence.timebase
              )
        else {
            return false
        }

        return moveSelectedTransformKeyframe(parameter: parameter, from: fromTime, to: toTime)
    }

    @discardableResult
    func deleteSelectedTransformKeyframe(
        parameter: ClipTransformParameter,
        atFrame frame: Int64
    ) -> Bool {
        guard let sequence = activeSequence,
              let time = try? RationalTime.atFrame(frame, frameRate: sequence.timebase)
        else {
            return false
        }

        return deleteSelectedTransformKeyframe(parameter: parameter, at: time)
    }

    func isMarkerSelected(_ markerID: UUID) -> Bool {
        timelineState.selectedMarkerID == markerID
    }

    func selectMarker(_ markerID: UUID) {
        guard activeSequence?.markers.contains(where: { $0.id == markerID }) == true else {
            return
        }

        timelineState.selectedMarkerID = markerID
        timelineState.selectedClips = []
        timelineState.selectionAnchor = nil
        persistActiveSequenceContext()
    }

    func addTimelineMarkerAtPlayhead() {
        guard let sequence = activeSequence,
              let markerTime = try? RationalTime.atFrame(playheadFrame, frameRate: sequence.timebase)
        else {
            return
        }

        let marker = Marker(
            id: UUID(),
            time: markerTime,
            name: "Marker \(sequence.markers.count + 1)",
            color: .blue,
            note: "",
            anchor: .timeline
        )

        if applyEdit(.addMarker(sequenceID: sequence.id, marker: marker)) {
            selectMarker(marker.id)
        }
    }

    func deleteSelectedMarker() {
        guard let sequenceID = activeSequence?.id,
              let markerID = timelineState.selectedMarkerID
        else {
            return
        }

        if applyEdit(.removeMarker(sequenceID: sequenceID, markerID: markerID)) {
            timelineState.selectedMarkerID = nil
            persistActiveSequenceContext()
        }
    }

    func updateSelectedMarker(
        name: String? = nil,
        color: MarkerColor? = nil,
        note: String? = nil
    ) {
        guard let sequence = activeSequence,
              let selectedMarker
        else {
            return
        }

        let marker = Marker(
            id: selectedMarker.id,
            time: selectedMarker.time,
            name: name ?? selectedMarker.name,
            color: color ?? selectedMarker.color,
            note: note ?? selectedMarker.note,
            anchor: selectedMarker.anchor
        )

        if applyEdit(.updateMarker(sequenceID: sequence.id, marker: marker)) {
            timelineState.selectedMarkerID = marker.id
            persistActiveSequenceContext()
        }
    }

    @discardableResult
    func detachAudioForSelectedClip() -> Bool {
        guard let sequenceID = activeSequence?.id,
              let linkGroupID = selectedClip?.linkGroupID
        else {
            return false
        }

        return applyEdit(.unlinkClips(sequenceID: sequenceID, linkGroupID: linkGroupID))
    }

    @discardableResult
    func moveSelectedClip(
        toStartFrame startFrame: Int64,
        linkedClipEditMode: LinkedClipEditMode = .linked
    ) -> Bool {
        guard let sequence = activeSequence,
              let selectedClipReference,
              let selectedClip,
              let start = try? RationalTime.atFrame(startFrame, frameRate: sequence.timebase),
              let timelineRange = try? TimeRange(
                start: start,
                duration: selectedClip.timelineRange.duration
              )
        else {
            return false
        }

        return applyEdit(
            .moveClip(
                sequenceID: sequence.id,
                sourceTrackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                destinationTrackID: selectedClipReference.trackID,
                timelineRange: timelineRange,
                linkedClipEditMode: linkedClipEditMode
            )
        )
    }

    @discardableResult
    func trimSelectedClip(
        sourceStartFrame: Int64,
        timelineStartFrame: Int64,
        durationFrames: Int64,
        linkedClipEditMode: LinkedClipEditMode = .linked
    ) -> Bool {
        guard durationFrames > 0,
              let sequence = activeSequence,
              let selectedClipReference,
              let sourceStart = try? RationalTime.atFrame(
                sourceStartFrame,
                frameRate: sequence.timebase
              ),
              let timelineStart = try? RationalTime.atFrame(
                timelineStartFrame,
                frameRate: sequence.timebase
              ),
              let duration = try? sequence.timebase.duration(ofFrames: durationFrames),
              let sourceRange = try? TimeRange(start: sourceStart, duration: duration),
              let timelineRange = try? TimeRange(start: timelineStart, duration: duration)
        else {
            return false
        }

        return applyEdit(
            .trimClip(
                sequenceID: sequence.id,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                sourceRange: sourceRange,
                timelineRange: timelineRange,
                linkedClipEditMode: linkedClipEditMode
            )
        )
    }

    func jumpToNextMarker() {
        guard let sequence = activeSequence,
              let currentTime = try? RationalTime.atFrame(playheadFrame, frameRate: sequence.timebase),
              let marker = MarkerNavigation.nextMarker(in: sequence, after: currentTime)
        else {
            return
        }

        jump(to: marker, in: sequence)
    }

    func jumpToPreviousMarker() {
        guard let sequence = activeSequence,
              let currentTime = try? RationalTime.atFrame(playheadFrame, frameRate: sequence.timebase),
              let marker = MarkerNavigation.previousMarker(in: sequence, before: currentTime)
        else {
            return
        }

        jump(to: marker, in: sequence)
    }

    func setTimelineRangeIn() {
        timelineState.selectionInFrame = playheadFrame
        persistActiveSequenceContext()
    }

    func setTimelineRangeOut() {
        timelineState.selectionOutFrame = playheadFrame
        persistActiveSequenceContext()
    }

    func clearTimelineRange() {
        timelineState.selectionInFrame = nil
        timelineState.selectionOutFrame = nil
        persistActiveSequenceContext()
    }

    func setTimelineSnappingEnabled(_ isEnabled: Bool) {
        timelineState.snappingEnabled = isEnabled
        persistActiveSequenceContext()
    }

    func zoomTimelineIn() {
        timelineState.pixelsPerFrame = TimelineInteraction.zoomedPixelsPerFrame(
            timelineState.pixelsPerFrame,
            factor: 1.25
        )
        persistActiveSequenceContext()
    }

    func zoomTimelineOut() {
        timelineState.pixelsPerFrame = TimelineInteraction.zoomedPixelsPerFrame(
            timelineState.pixelsPerFrame,
            factor: 0.8
        )
        persistActiveSequenceContext()
    }

    func zoomTimelineVerticallyIn() {
        timelineState.laneHeight = TimelineInteraction.zoomedLaneHeight(
            timelineState.laneHeight,
            factor: 1.18
        )
        persistActiveSequenceContext()
    }

    func zoomTimelineVerticallyOut() {
        timelineState.laneHeight = TimelineInteraction.zoomedLaneHeight(
            timelineState.laneHeight,
            factor: 0.85
        )
        persistActiveSequenceContext()
    }

    func fitTimeline(toWidth availableWidth: Double) {
        timelineState.pixelsPerFrame = TimelineInteraction.fittedPixelsPerFrame(
            durationFrames: durationFrames,
            availableWidth: availableWidth
        )
        persistActiveSequenceContext()
    }

    func zoomTimelineToSelection(toWidth availableWidth: Double) {
        guard let sequence = activeSequence,
              let frameRange = TimelineInteraction.selectedFrameRange(
                in: sequence,
                selectedClips: timelineState.selectedClips
              )
        else {
            return
        }
        timelineState.pixelsPerFrame = TimelineInteraction.fittedPixelsPerFrame(
            durationFrames: frameRange.durationFrames,
            availableWidth: availableWidth
        )
        persistActiveSequenceContext()
    }

    func setTrackState(
        sequenceID: UUID,
        trackID: UUID,
        enabled: Bool? = nil,
        locked: Bool? = nil,
        muted: Bool? = nil,
        solo: Bool? = nil,
        hidden: Bool? = nil
    ) {
        applyEdit(
            .setTrackState(
                sequenceID: sequenceID,
                trackID: trackID,
                state: TrackStatePatch(
                    enabled: enabled,
                    locked: locked,
                    muted: muted,
                    solo: solo,
                    hidden: hidden
                )
            )
        )
    }

    @discardableResult
    private func updateSelectedClipTransform(_ transform: ClipTransform) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference
        else {
            return false
        }

        return applyEdit(
            .setClipTransform(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                transform: transform
            )
        )
    }

    @discardableResult
    private func addSelectedTransformKeyframe(
        parameter: ClipTransformParameter,
        at time: RationalTime
    ) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              let selectedClip
        else {
            return false
        }

        let transform = selectedClip.transformAnimation.value(at: time)
        let keyframe = ClipTransformKeyframe(
            time: time,
            value: TransformKeyframeLookup.value(parameter: parameter, in: transform),
            interpolation: .linear
        )

        return applyEdit(
            .addClipTransformKeyframe(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                parameter: parameter,
                keyframe: keyframe
            )
        )
    }

    @discardableResult
    private func moveSelectedTransformKeyframe(
        parameter: ClipTransformParameter,
        from fromTime: RationalTime,
        to toTime: RationalTime
    ) -> Bool {
        guard fromTime != toTime,
              let sequenceID = activeSequence?.id,
              let selectedClipReference,
              let selectedClip,
              let existingKeyframe = TransformKeyframeLookup.keyframe(
                parameter: parameter,
                at: fromTime,
                in: selectedClip.transformAnimation
              )
        else {
            return false
        }

        let movedKeyframe = ClipTransformKeyframe(
            time: toTime,
            value: existingKeyframe.value,
            interpolation: existingKeyframe.interpolation
        )
        return applyEdit(
            .moveClipTransformKeyframe(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                parameter: parameter,
                fromTime: fromTime,
                keyframe: movedKeyframe
            )
        )
    }

    @discardableResult
    private func deleteSelectedTransformKeyframe(
        parameter: ClipTransformParameter,
        at time: RationalTime
    ) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference
        else {
            return false
        }

        return applyEdit(
            .deleteClipTransformKeyframe(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                parameter: parameter,
                time: time
            )
        )
    }

    func undo() {
        endCanvasTitleTextEditing()
        guard var history = editHistory, let project = history.undo() else {
            return
        }

        editHistory = history
        updateProject(project)
        scheduleAutosaveCheckpoint(project: project)
    }

    func redo() {
        endCanvasTitleTextEditing()
        guard var history = editHistory else {
            return
        }

        do {
            guard let project = try history.redo() else {
                return
            }
            editHistory = history
            updateProject(project)
            scheduleAutosaveCheckpoint(project: project)
        } catch {
            loadMessage = "Redo failed: \(error)"
        }
    }

    static func makeSampleProject() -> Result<Project, Error> {
        do {
            return .success(try EditorAjarSampleProjectFactory.makeSampleProject())
        } catch {
            return .failure(error)
        }
    }

    static func defaultAutosavePackageURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return supportDirectory
            .appendingPathComponent("EditorAjar", isDirectory: true)
            .appendingPathComponent("Autosave.ajar", isDirectory: true)
    }

    private static func makeAudioCoordinator() -> (any EditorAjarAudioCoordinating)? {
        do {
            return try EditorAjarLiveAudioCoordinator()
        } catch {
            return nil
        }
    }

    func autosaveCheckpointForTesting() async {
        await autosaveWriteTask?.value
        await autosaveCurrentProjectAndWait()
    }

    private func displayLinkTick(_ deltaSeconds: Double) {
        guard isPlaying, playbackController?.advance(by: deltaSeconds) == true else {
            return
        }

        syncPlayheadFromController()
        ensureAudioPlanForPlayback()
        requestRenderForCurrentFrame()
    }

    private func syncPlayheadFromController() {
        playheadFrame = playbackController?.playheadFrame ?? 0
        persistActiveSequenceContext()
    }

    private func startAudioPlayback() {
        guard let audioCoordinator,
              let project,
              let sequence = activeSequence
        else {
            return
        }

        do {
            try audioCoordinator.start(
                project: project,
                sequence: sequence,
                playheadFrame: playheadFrame,
                durationFrames: durationFrames
            )
        } catch {
            loadMessage = "Audio playback unavailable: \(error)"
        }
    }

    private func stopAudioPlayback() {
        audioCoordinator?.stop()
    }

    private func publishAudioPlanForCurrentFrame() {
        guard isPlaying,
              let audioCoordinator,
              let project,
              let sequence = activeSequence
        else {
            return
        }

        do {
            try audioCoordinator.publishSeek(
                project: project,
                sequence: sequence,
                playheadFrame: playheadFrame,
                durationFrames: durationFrames
            )
        } catch {
            loadMessage = "Audio seek unavailable: \(error)"
        }
    }

    private func ensureAudioPlanForPlayback() {
        guard isPlaying,
              let audioCoordinator,
              let project,
              let sequence = activeSequence
        else {
            return
        }

        do {
            try audioCoordinator.ensurePlaybackPlan(
                project: project,
                sequence: sequence,
                playheadFrame: playheadFrame,
                durationFrames: durationFrames
            )
        } catch {
            loadMessage = "Audio playback unavailable: \(error)"
        }
    }

    private func requestRenderForCurrentFrame() {
        guard let project,
              let sequence = activeSequence,
              let renderPipeline
        else {
            return
        }

        renderGeneration += 1
        let generation = renderGeneration
        let frame = playheadFrame
        loadMessage = "Rendering frame \(frame)"

        Task { [weak self, project, sequence, renderPipeline, frame, generation] in
            do {
                let texture = try await renderPipeline.renderFrame(
                    project: project,
                    sequence: sequence,
                    frame: frame
                )
                await MainActor.run {
                    guard self?.renderGeneration == generation else {
                        return
                    }
                    self?.presentedTexture = texture
                    self?.loadMessage = "Rendered \(sequence.name), frame \(frame)"
                }
            } catch {
                await MainActor.run {
                    guard self?.renderGeneration == generation else {
                        return
                    }
                    self?.loadMessage = "Render failed at frame \(frame): \(error)"
                }
            }
        }
    }

    private static func durationFrames(for sequence: Sequence) -> Int64 {
        let frameRate = sequence.timebase
        var lastFrame: Int64 = 1
        for track in sequence.videoTracks + sequence.audioTracks {
            for item in track.items {
                guard let endTime = try? item.timelineRange.end(),
                      let endFrame = try? endTime.frameIndex(at: frameRate, rounding: .up)
                else {
                    continue
                }
                lastFrame = max(lastFrame, endFrame)
            }
        }
        return max(1, lastFrame)
    }

    private static func emptySequence(name: String, frameRate: FrameRate) -> Sequence {
        Sequence(
            id: UUID(),
            name: name,
            videoTracks: [Track(id: UUID(), kind: .video, items: [])],
            audioTracks: [Track(id: UUID(), kind: .audio, items: [])],
            markers: [],
            timebase: frameRate
        )
    }

    private static func nextSequenceName(in project: Project) -> String {
        let existingNames = Set(project.sequences.map(\.name))
        var index = project.sequences.count + 1
        while existingNames.contains("Sequence \(index)") {
            index += 1
        }
        return "Sequence \(index)"
    }

    private static func replacementSequenceID(
        afterRemoving sequenceID: UUID,
        from project: Project
    ) -> UUID? {
        guard let index = project.sequences.firstIndex(where: { $0.id == sequenceID }) else {
            return activeSequenceFallbackID(in: project)
        }
        let nextIndex = project.sequences.index(after: index)
        if nextIndex < project.sequences.endIndex {
            return project.sequences[nextIndex].id
        }
        if index > project.sequences.startIndex {
            let previousIndex = project.sequences.index(before: index)
            return project.sequences[previousIndex].id
        }
        return nil
    }

    private static func activeSequenceFallbackID(in project: Project) -> UUID? {
        project.sequences.first?.id
    }

    private static func clip(_ reference: TimelineClipReference, in sequence: Sequence) -> Clip? {
        for track in sequence.videoTracks + sequence.audioTracks {
            guard track.id == reference.trackID else {
                continue
            }
            for item in track.items {
                if case .clip(let clip) = item, clip.id == reference.clipID {
                    return clip
                }
            }
        }
        return nil
    }

    private static func mediaDimensions(for clip: Clip, in project: Project) -> PixelDimensions? {
        guard case .media(let mediaID) = clip.source else {
            return nil
        }
        return project.mediaPool.first { $0.id == mediaID }?.metadata.pixelDimensions
    }

    private func playheadTime(in sequence: Sequence) -> RationalTime? {
        try? RationalTime.atFrame(playheadFrame, frameRate: sequence.timebase)
    }

    private func editMenuTitle(prefix: String, command: EditCommand?) -> String {
        guard let command else {
            return prefix
        }
        return "\(prefix) \(command.actionName)"
    }

    @discardableResult
    private func applyEdit(
        _ command: EditCommand,
        coalescingWithPrevious: Bool = false
    ) -> Bool {
        guard var history = editHistory else {
            return false
        }

        do {
            persistActiveSequenceContext()
            let project: Project
            if coalescingWithPrevious {
                project = try history.applyCoalescingWithPrevious(command)
            } else {
                project = try history.apply(command)
            }
            editHistory = history
            updateProject(project)
            scheduleAutosave(command: command, project: project)
            return true
        } catch {
            loadMessage = "Edit failed: \(error)"
            return false
        }
    }

    private func canvasTitleLayout(
        for reference: CanvasTitleBoxReference
    ) -> CanvasTitleBoxLayout? {
        visibleCanvasTitleBoxes.first { $0.reference == reference }
    }

    private func setCanvasTitleBoxOrigin(
        _ origin: CanvasPoint,
        layout: CanvasTitleBoxLayout
    ) -> Bool {
        guard origin != layout.box.origin else {
            return true
        }

        endCanvasTitleTextEditing()
        selectedCanvasTitleBoxReference = layout.reference
        selectClip(
            trackID: layout.reference.trackID,
            clipID: layout.reference.clipID,
            mode: .replace
        )
        return applyEdit(
            .setTitleTextBox(
                sequenceID: layout.reference.sequenceID,
                trackID: layout.reference.trackID,
                clipID: layout.reference.clipID,
                box: CanvasTitleBoxEditor.copying(layout.box, origin: origin)
            )
        )
    }

    private func jump(to marker: Marker, in sequence: Sequence) {
        guard let frame = try? marker.time.frameIndex(
            at: sequence.timebase,
            rounding: .nearestOrAwayFromZero
        ) else {
            return
        }

        scrub(to: frame)
        selectMarker(marker.id)
    }

    private func updateProject(_ project: Project) {
        persistActiveSequenceContext()
        self.project = project
        let sequenceIDs = Set(project.sequences.map(\.id))
        sequenceContexts = sequenceContexts.filter { sequenceIDs.contains($0.key) }

        if let activeSequenceID,
           let sequence = project.sequences.first(where: { $0.id == activeSequenceID })
        {
            restoreActiveSequenceContext(for: sequence)
        } else if let sequence = project.sequences.first {
            restoreActiveSequenceContext(for: sequence)
        } else {
            activeSequenceID = nil
            durationFrames = 1
            playheadFrame = 0
            timelineState = TimelineInteractionState()
            playbackController = nil
            presentedTexture = nil
        }
        requestRenderForCurrentFrame()
        ensureAudioPlanForPlayback()
    }

    private func persistActiveSequenceContext() {
        guard let activeSequenceID else {
            return
        }

        sequenceContexts[activeSequenceID] = SequenceEditingContext(
            playheadFrame: playheadFrame,
            timelineState: timelineState
        )
    }

    private func restoreActiveSequenceContext(for sequence: Sequence) {
        let context = sequenceContexts[sequence.id] ?? SequenceEditingContext()
        let nextDurationFrames = Self.durationFrames(for: sequence)
        activeSequenceID = sequence.id
        durationFrames = nextDurationFrames
        playheadFrame = min(max(0, context.playheadFrame), max(0, nextDurationFrames - 1))
        timelineState = Self.validTimelineState(context.timelineState, for: sequence)
        playbackController = EditorAjarPlaybackController(
            frameRate: sequence.timebase,
            durationFrames: nextDurationFrames,
            playheadFrame: playheadFrame
        )
        persistActiveSequenceContext()
    }

    private static func validTimelineState(
        _ state: TimelineInteractionState,
        for sequence: Sequence
    ) -> TimelineInteractionState {
        var nextState = state
        let availableClipIDs = Set(TimelineInteraction.clipReferences(in: sequence))
        let availableMarkerIDs = Set(sequence.markers.map(\.id))
        nextState.selectedClips = nextState.selectedClips.intersection(availableClipIDs)
        if let anchor = nextState.selectionAnchor,
           !availableClipIDs.contains(anchor)
        {
            nextState.selectionAnchor = nextState.selectedClips.first
        }
        if let selectedMarkerID = nextState.selectedMarkerID,
           !availableMarkerIDs.contains(selectedMarkerID)
        {
            nextState.selectedMarkerID = nil
        }
        return nextState
    }

    private func startAutosaveLoop() {
        guard autosaveCoordinator != nil,
              autosaveIntervalSeconds.isFinite,
              autosaveIntervalSeconds > 0
        else {
            return
        }

        let nanoseconds = UInt64(max(0.1, autosaveIntervalSeconds) * 1_000_000_000)
        autosaveLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                self?.autosaveCurrentProject()
            }
        }
    }

    private func scheduleAutosave(command: EditCommand, project: Project) {
        guard let autosaveCoordinator else {
            return
        }

        autosaveCommandCount += 1
        let commandCount = autosaveCommandCount
        let previousWriteTask = autosaveWriteTask
        autosaveWriteTask = Task {
            [weak self, autosaveCoordinator, command, commandCount, project, previousWriteTask] in
            await previousWriteTask?.value
            let message = await autosaveCoordinator.recordSignificantEdit(
                command: command,
                sequenceNumber: commandCount,
                project: project
            )
            await MainActor.run {
                if let message {
                    self?.loadMessage = message
                }
            }
        }
    }

    private func scheduleAutosaveCheckpoint(project: Project) {
        guard let autosaveCoordinator else {
            return
        }

        let commandCount = autosaveCommandCount
        let previousWriteTask = autosaveWriteTask
        autosaveWriteTask = Task { [weak self, autosaveCoordinator, commandCount, project, previousWriteTask] in
            await previousWriteTask?.value
            let message = await autosaveCoordinator.writeSnapshot(
                project: project,
                appliedCommandCount: commandCount
            )
            await MainActor.run {
                if let message {
                    self?.loadMessage = message
                }
            }
        }
    }

    private func autosaveCurrentProject() {
        guard let project else {
            return
        }
        scheduleAutosaveCheckpoint(project: project)
    }

    private func autosaveCurrentProjectAndWait() async {
        guard let project,
              let autosaveCoordinator
        else {
            return
        }

        await autosaveWriteTask?.value
        let message = await autosaveCoordinator.writeSnapshot(
            project: project,
            appliedCommandCount: autosaveCommandCount
        )
        if let message {
            loadMessage = message
        }
    }
}

private actor EditorAjarAutosaveCoordinator {
    private let packageURL: URL

    init(packageURL: URL) {
        self.packageURL = packageURL
    }

    func recordSignificantEdit(
        command: EditCommand,
        sequenceNumber: Int,
        project: Project
    ) -> String? {
        do {
            try AjarAutosaveStore.appendJournalEntry(
                command: command,
                sequenceNumber: sequenceNumber,
                to: packageURL
            )
            try AjarAutosaveStore.writeSnapshot(
                project,
                appliedCommandCount: sequenceNumber,
                openMode: .editable,
                to: packageURL
            )
            return nil
        } catch {
            return "Autosave failed: \(error)"
        }
    }

    func writeSnapshot(project: Project, appliedCommandCount: Int) -> String? {
        do {
            try AjarAutosaveStore.writeSnapshot(
                project,
                appliedCommandCount: appliedCommandCount,
                openMode: .editable,
                to: packageURL
            )
            return nil
        } catch {
            return "Autosave failed: \(error)"
        }
    }
}

struct SequenceTab: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let isActive: Bool
    let canClose: Bool
}

private struct SequenceEditingContext: Equatable, Sendable {
    var playheadFrame: Int64
    var timelineState: TimelineInteractionState

    init(
        playheadFrame: Int64 = 0,
        timelineState: TimelineInteractionState = TimelineInteractionState()
    ) {
        self.playheadFrame = playheadFrame
        self.timelineState = timelineState
    }
}

struct TimelineInteractionState: Equatable, Sendable {
    static let minimumPixelsPerFrame = 1.0
    static let maximumPixelsPerFrame = 48.0
    static let minimumLaneHeight = 36.0
    static let maximumLaneHeight = 96.0

    var pixelsPerFrame: Double
    var laneHeight: Double
    var snappingEnabled: Bool
    var snapToleranceFrames: Int64
    var selectedClips: Set<TimelineClipReference>
    var selectionAnchor: TimelineClipReference?
    var selectedMarkerID: UUID?
    var selectionInFrame: Int64?
    var selectionOutFrame: Int64?

    init(
        pixelsPerFrame: Double = 8.0,
        laneHeight: Double = 46.0,
        snappingEnabled: Bool = true,
        snapToleranceFrames: Int64 = 2,
        selectedClips: Set<TimelineClipReference> = [],
        selectionAnchor: TimelineClipReference? = nil,
        selectedMarkerID: UUID? = nil,
        selectionInFrame: Int64? = nil,
        selectionOutFrame: Int64? = nil
    ) {
        self.pixelsPerFrame = pixelsPerFrame
        self.laneHeight = laneHeight
        self.snappingEnabled = snappingEnabled
        self.snapToleranceFrames = snapToleranceFrames
        self.selectedClips = selectedClips
        self.selectionAnchor = selectionAnchor
        self.selectedMarkerID = selectedMarkerID
        self.selectionInFrame = selectionInFrame
        self.selectionOutFrame = selectionOutFrame
    }
}

struct TimelineClipReference: Hashable, Sendable {
    let trackID: UUID
    let clipID: UUID
}

struct SelectedTransformInspectorState: Equatable, Sendable {
    let clipName: String
    let transform: ClipTransform
}

struct SelectedTrackCompositingInspectorState: Equatable, Sendable {
    let trackName: String
    let opacity: RationalValue
    let blendMode: ClipBlendMode
}

struct CanvasClipTransformLayout: Equatable, Sendable {
    let canvasSize: PixelDimensions
    let clipSize: PixelDimensions
    let transform: ClipTransform
}

enum TransformInspectorField: String, CaseIterable, Identifiable, Sendable {
    case positionX
    case positionY
    case scaleXPercent
    case scaleYPercent
    case anchorX
    case anchorY
    case rotationDegrees
    case opacityPercent
    case cropLeft
    case cropTop
    case cropRight
    case cropBottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .positionX:
            return "Position X"
        case .positionY:
            return "Position Y"
        case .scaleXPercent:
            return "Scale X %"
        case .scaleYPercent:
            return "Scale Y %"
        case .anchorX:
            return "Anchor X"
        case .anchorY:
            return "Anchor Y"
        case .rotationDegrees:
            return "Rotation"
        case .opacityPercent:
            return "Opacity %"
        case .cropLeft:
            return "Crop Left"
        case .cropTop:
            return "Crop Top"
        case .cropRight:
            return "Crop Right"
        case .cropBottom:
            return "Crop Bottom"
        }
    }

    var accessibilityIdentifier: String {
        "Transform \(title)"
    }
}

enum TransformFieldValueMapper {
    static func stringValue(for field: TransformInspectorField, in transform: ClipTransform) -> String {
        switch field {
        case .positionX:
            return string(from: transform.position.x)
        case .positionY:
            return string(from: transform.position.y)
        case .scaleXPercent:
            return percentString(from: transform.scale.x)
        case .scaleYPercent:
            return percentString(from: transform.scale.y)
        case .anchorX:
            return string(from: transform.anchorPoint.x)
        case .anchorY:
            return string(from: transform.anchorPoint.y)
        case .rotationDegrees:
            return string(from: transform.rotation.degrees)
        case .opacityPercent:
            return percentString(from: transform.opacity)
        case .cropLeft:
            return "\(transform.crop.left)"
        case .cropTop:
            return "\(transform.crop.top)"
        case .cropRight:
            return "\(transform.crop.right)"
        case .cropBottom:
            return "\(transform.crop.bottom)"
        }
    }

    static func updatedTransform(
        _ field: TransformInspectorField,
        rawValue: String,
        in transform: ClipTransform
    ) -> ClipTransform? {
        switch field {
        case .positionX:
            return rational(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    position: CanvasPoint(x: value, y: transform.position.y)
                )
            }
        case .positionY:
            return rational(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    position: CanvasPoint(x: transform.position.x, y: value)
                )
            }
        case .scaleXPercent:
            return percent(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    scale: ClipScale(x: value, y: transform.scale.y)
                )
            }
        case .scaleYPercent:
            return percent(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    scale: ClipScale(x: transform.scale.x, y: value)
                )
            }
        case .anchorX:
            return rational(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    anchorPoint: CanvasPoint(x: value, y: transform.anchorPoint.y)
                )
            }
        case .anchorY:
            return rational(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    anchorPoint: CanvasPoint(x: transform.anchorPoint.x, y: value)
                )
            }
        case .rotationDegrees:
            return rational(rawValue).map { value in
                TransformEditor.copying(transform, rotation: ClipRotation(degrees: value))
            }
        case .opacityPercent:
            return percent(rawValue).map { value in
                TransformEditor.copying(transform, opacity: value)
            }
        case .cropLeft:
            return int64(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    crop: ClipCropInsets(
                        left: value,
                        top: transform.crop.top,
                        right: transform.crop.right,
                        bottom: transform.crop.bottom
                    )
                )
            }
        case .cropTop:
            return int64(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    crop: ClipCropInsets(
                        left: transform.crop.left,
                        top: value,
                        right: transform.crop.right,
                        bottom: transform.crop.bottom
                    )
                )
            }
        case .cropRight:
            return int64(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    crop: ClipCropInsets(
                        left: transform.crop.left,
                        top: transform.crop.top,
                        right: value,
                        bottom: transform.crop.bottom
                    )
                )
            }
        case .cropBottom:
            return int64(rawValue).map { value in
                TransformEditor.copying(
                    transform,
                    crop: ClipCropInsets(
                        left: transform.crop.left,
                        top: transform.crop.top,
                        right: transform.crop.right,
                        bottom: value
                    )
                )
            }
        }
    }

    private static func string(from value: RationalValue) -> String {
        formatted(value.doubleValue)
    }

    private static func percentString(from value: RationalValue) -> String {
        formatted(value.doubleValue * 100.0)
    }

    private static func formatted(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.000_001 {
            return "\(Int64(value.rounded()))"
        }
        return String(format: "%.2f", value)
    }

    private static func rational(_ rawValue: String) -> RationalValue? {
        double(rawValue).map(RationalValue.approximating)
    }

    private static func percent(_ rawValue: String) -> RationalValue? {
        double(rawValue).map { RationalValue.approximating($0 / 100.0) }
    }

    private static func int64(_ rawValue: String) -> Int64? {
        double(rawValue).map { Int64($0.rounded()) }
    }

    private static func double(_ rawValue: String) -> Double? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              let value = Double(trimmedValue),
              value.isFinite
        else {
            return nil
        }
        return value
    }
}

enum TrackCompositingValueMapper {
    static func percentString(from value: RationalValue) -> String {
        formatted(value.doubleValue * 100.0)
    }

    static func percent(_ rawValue: String) -> RationalValue? {
        double(rawValue).map { RationalValue.approximating($0 / 100.0) }
    }

    private static func formatted(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.000_001 {
            return "\(Int64(value.rounded()))"
        }
        return String(format: "%.2f", value)
    }

    private static func double(_ rawValue: String) -> Double? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              let value = Double(trimmedValue),
              value.isFinite
        else {
            return nil
        }
        return value
    }
}

enum TransformEditor {
    static func copying(
        _ transform: ClipTransform,
        position: CanvasPoint? = nil,
        scale: ClipScale? = nil,
        anchorPoint: CanvasPoint? = nil,
        rotation: ClipRotation? = nil,
        opacity: RationalValue? = nil,
        blendMode: ClipBlendMode? = nil,
        crop: ClipCropInsets? = nil,
        flip: ClipFlip? = nil
    ) -> ClipTransform {
        ClipTransform(
            position: position ?? transform.position,
            scale: scale ?? transform.scale,
            anchorPoint: anchorPoint ?? transform.anchorPoint,
            rotation: rotation ?? transform.rotation,
            opacity: opacity ?? transform.opacity,
            blendMode: blendMode ?? transform.blendMode,
            crop: crop ?? transform.crop,
            flip: flip ?? transform.flip
        )
    }
}

enum CanvasTransformHandle: String, CaseIterable, Identifiable, Sendable {
    case move
    case scaleBottomRight
    case rotate
    case anchor

    var id: String { rawValue }
}

struct CanvasTransformGesture: Equatable, Sendable {
    let handle: CanvasTransformHandle
    let translationX: Double
    let translationY: Double
    let canvasScale: Double
}

enum CanvasTransformGestureMapper {
    static func updatedTransform(
        from transform: ClipTransform,
        gesture: CanvasTransformGesture,
        clipSize: PixelDimensions
    ) -> ClipTransform {
        switch gesture.handle {
        case .move:
            return moved(transform, gesture: gesture)
        case .scaleBottomRight:
            return scaled(transform, gesture: gesture, clipSize: clipSize)
        case .rotate:
            return rotated(transform, gesture: gesture)
        case .anchor:
            return anchored(transform, gesture: gesture)
        }
    }

    private static func moved(
        _ transform: ClipTransform,
        gesture: CanvasTransformGesture
    ) -> ClipTransform {
        TransformEditor.copying(
            transform,
            position: CanvasPoint(
                x: offset(transform.position.x, gesture.translationX, canvasScale: gesture.canvasScale),
                y: offset(transform.position.y, gesture.translationY, canvasScale: gesture.canvasScale)
            )
        )
    }

    private static func scaled(
        _ transform: ClipTransform,
        gesture: CanvasTransformGesture,
        clipSize: PixelDimensions
    ) -> ClipTransform {
        let width = max(1.0, Double(clipSize.width))
        let height = max(1.0, Double(clipSize.height))
        let scaleX = max(0.01, transform.scale.x.doubleValue + gesture.translationX / gesture.canvasScale / width)
        let scaleY = max(0.01, transform.scale.y.doubleValue + gesture.translationY / gesture.canvasScale / height)
        return TransformEditor.copying(
            transform,
            scale: ClipScale(
                x: RationalValue.approximating(scaleX),
                y: RationalValue.approximating(scaleY)
            )
        )
    }

    private static func rotated(
        _ transform: ClipTransform,
        gesture: CanvasTransformGesture
    ) -> ClipTransform {
        let degrees = transform.rotation.degrees.doubleValue + gesture.translationX / 2.0
        return TransformEditor.copying(
            transform,
            rotation: ClipRotation(degrees: RationalValue.approximating(degrees))
        )
    }

    private static func anchored(
        _ transform: ClipTransform,
        gesture: CanvasTransformGesture
    ) -> ClipTransform {
        TransformEditor.copying(
            transform,
            anchorPoint: CanvasPoint(
                x: offset(transform.anchorPoint.x, gesture.translationX, canvasScale: gesture.canvasScale),
                y: offset(transform.anchorPoint.y, gesture.translationY, canvasScale: gesture.canvasScale)
            )
        )
    }

    private static func offset(
        _ value: RationalValue,
        _ delta: Double,
        canvasScale: Double
    ) -> RationalValue {
        RationalValue.approximating(value.doubleValue + delta / max(0.000_001, canvasScale))
    }
}

struct TransformKeyframeLane: Identifiable, Equatable, Sendable {
    let parameter: ClipTransformParameter
    let title: String
    let keyframes: [TransformKeyframePoint]

    var id: String { parameter.rawValue }

    static func makeLanes(
        animation: AnimatableClipTransform,
        frameRate: FrameRate,
        pixelsPerFrame: Double
    ) -> [TransformKeyframeLane] {
        ClipTransformParameter.allCases.map { parameter in
            TransformKeyframeLane(
                parameter: parameter,
                title: parameter.displayName,
                keyframes: TransformKeyframeLookup.keyframes(
                    parameter: parameter,
                    in: animation,
                    frameRate: frameRate,
                    pixelsPerFrame: pixelsPerFrame
                )
            )
        }
    }
}

struct TransformKeyframePoint: Identifiable, Equatable, Sendable {
    let parameter: ClipTransformParameter
    let frame: Int64
    let xPosition: Double
    let keyframe: ClipTransformKeyframe

    var id: String {
        "\(parameter.rawValue)-\(frame)"
    }
}

enum TransformKeyframeLookup {
    static func keyframes(
        parameter: ClipTransformParameter,
        in animation: AnimatableClipTransform,
        frameRate: FrameRate,
        pixelsPerFrame: Double
    ) -> [TransformKeyframePoint] {
        keyframes(parameter: parameter, in: animation).compactMap { keyframe in
            guard let frame = try? keyframe.time.frameIndex(
                at: frameRate,
                rounding: .nearestOrAwayFromZero
            ) else {
                return nil
            }
            return TransformKeyframePoint(
                parameter: parameter,
                frame: frame,
                xPosition: TimelineInteraction.xPosition(
                    frame: frame,
                    pixelsPerFrame: pixelsPerFrame
                ),
                keyframe: keyframe
            )
        }
    }

    static func keyframe(
        parameter: ClipTransformParameter,
        at time: RationalTime,
        in animation: AnimatableClipTransform
    ) -> ClipTransformKeyframe? {
        keyframes(parameter: parameter, in: animation).first { $0.time == time }
    }

    static func value(
        parameter: ClipTransformParameter,
        in transform: ClipTransform
    ) -> ClipTransformKeyframeValue {
        switch parameter {
        case .position:
            return .position(transform.position)
        case .scale:
            return .scale(transform.scale)
        case .anchorPoint:
            return .anchorPoint(transform.anchorPoint)
        case .rotation:
            return .rotation(transform.rotation)
        case .opacity:
            return .opacity(transform.opacity)
        case .crop:
            return .crop(transform.crop)
        }
    }

    private static func keyframes(
        parameter: ClipTransformParameter,
        in animation: AnimatableClipTransform
    ) -> [ClipTransformKeyframe] {
        switch parameter {
        case .position:
            return animation.position.keyframes.map { keyframe in
                ClipTransformKeyframe(
                    time: keyframe.time,
                    value: .position(keyframe.value),
                    interpolation: keyframe.interpolation
                )
            }
        case .scale:
            return animation.scale.keyframes.map { keyframe in
                ClipTransformKeyframe(
                    time: keyframe.time,
                    value: .scale(keyframe.value),
                    interpolation: keyframe.interpolation
                )
            }
        case .anchorPoint:
            return animation.anchorPoint.keyframes.map { keyframe in
                ClipTransformKeyframe(
                    time: keyframe.time,
                    value: .anchorPoint(keyframe.value),
                    interpolation: keyframe.interpolation
                )
            }
        case .rotation:
            return animation.rotation.keyframes.map { keyframe in
                ClipTransformKeyframe(
                    time: keyframe.time,
                    value: .rotation(keyframe.value),
                    interpolation: keyframe.interpolation
                )
            }
        case .opacity:
            return animation.opacity.keyframes.map { keyframe in
                ClipTransformKeyframe(
                    time: keyframe.time,
                    value: .opacity(keyframe.value),
                    interpolation: keyframe.interpolation
                )
            }
        case .crop:
            return animation.crop.keyframes.map { keyframe in
                ClipTransformKeyframe(
                    time: keyframe.time,
                    value: .crop(keyframe.value),
                    interpolation: keyframe.interpolation
                )
            }
        }
    }
}

extension ClipTransformParameter {
    var displayName: String {
        switch self {
        case .position:
            return "Position"
        case .scale:
            return "Scale"
        case .anchorPoint:
            return "Anchor"
        case .rotation:
            return "Rotation"
        case .opacity:
            return "Opacity"
        case .crop:
            return "Crop"
        }
    }
}

struct TimelineClipLayout: Equatable, Sendable {
    let reference: TimelineClipReference
    let name: String
    let startFrame: Int64
    let endFrame: Int64
    let xPosition: Double
    let width: Double

    var durationFrames: Int64 {
        max(0, endFrame - startFrame)
    }
}

struct TimelineMarkerLayout: Equatable, Sendable {
    let markerID: UUID
    let name: String
    let note: String
    let color: MarkerColor
    let frame: Int64
    let xPosition: Double
}

enum TimelineSelectionMode: Equatable, Sendable {
    case replace
    case toggle
    case rangeOnTrack
}

struct TimelineSelectionResult: Equatable, Sendable {
    let selectedClips: Set<TimelineClipReference>
    let anchor: TimelineClipReference?
}

struct TimelineFrameRange: Equatable, Sendable {
    let startFrame: Int64
    let endFrame: Int64

    var durationFrames: Int64 {
        max(1, endFrame - startFrame)
    }
}

enum TimelineSnapTargetKind: Equatable, Sendable {
    case playhead
    case marker(UUID)
    case clipEdge(TimelineClipReference)
}

struct TimelineSnapTarget: Equatable, Sendable {
    let frame: Int64
    let kind: TimelineSnapTargetKind
}

enum TimelineInteraction {
    static func xPosition(frame: Int64, pixelsPerFrame: Double) -> Double {
        Double(max(0, frame)) * max(TimelineInteractionState.minimumPixelsPerFrame, pixelsPerFrame)
    }

    static func frame(atX xPosition: Double, pixelsPerFrame: Double, durationFrames: Int64) -> Int64 {
        guard xPosition.isFinite, pixelsPerFrame.isFinite, pixelsPerFrame > 0 else {
            return 0
        }

        let roundedFrame = Int64((xPosition / pixelsPerFrame).rounded())
        return min(max(0, roundedFrame), max(0, durationFrames - 1))
    }

    static func contentWidth(
        durationFrames: Int64,
        pixelsPerFrame: Double,
        minimumWidth: Double
    ) -> Double {
        max(minimumWidth, Double(max(1, durationFrames)) * pixelsPerFrame)
    }

    static func zoomedPixelsPerFrame(_ currentValue: Double, factor: Double) -> Double {
        clamped(
            currentValue * factor,
            minimum: TimelineInteractionState.minimumPixelsPerFrame,
            maximum: TimelineInteractionState.maximumPixelsPerFrame
        )
    }

    static func zoomedLaneHeight(_ currentValue: Double, factor: Double) -> Double {
        clamped(
            currentValue * factor,
            minimum: TimelineInteractionState.minimumLaneHeight,
            maximum: TimelineInteractionState.maximumLaneHeight
        )
    }

    static func fittedPixelsPerFrame(durationFrames: Int64, availableWidth: Double) -> Double {
        guard availableWidth.isFinite, availableWidth > 0 else {
            return TimelineInteractionState.minimumPixelsPerFrame
        }

        return clamped(
            availableWidth / Double(max(1, durationFrames)),
            minimum: TimelineInteractionState.minimumPixelsPerFrame,
            maximum: TimelineInteractionState.maximumPixelsPerFrame
        )
    }

    static func clipLayouts(
        for track: Track,
        frameRate: FrameRate,
        pixelsPerFrame: Double
    ) -> [TimelineClipLayout] {
        track.items.compactMap { item in
            guard case .clip(let clip) = item,
                  let startFrame = try? clip.timelineRange.start.frameIndex(
                    at: frameRate,
                    rounding: .down
                  ),
                  let endTime = try? clip.timelineRange.end(),
                  let endFrame = try? endTime.frameIndex(at: frameRate, rounding: .up)
            else {
                return nil
            }

            let durationFrames = max(1, endFrame - startFrame)
            return TimelineClipLayout(
                reference: TimelineClipReference(trackID: track.id, clipID: clip.id),
                name: clip.name,
                startFrame: startFrame,
                endFrame: endFrame,
                xPosition: xPosition(frame: startFrame, pixelsPerFrame: pixelsPerFrame),
                width: Double(durationFrames) * pixelsPerFrame
            )
        }
    }

    static func clipReferences(in sequence: Sequence) -> [TimelineClipReference] {
        (sequence.videoTracks + sequence.audioTracks).flatMap { track in
            track.items.compactMap { item in
                guard case .clip(let clip) = item else {
                    return nil
                }
                return TimelineClipReference(trackID: track.id, clipID: clip.id)
            }
        }
    }

    static func reducedSelection(
        currentSelection: Set<TimelineClipReference>,
        anchor: TimelineClipReference?,
        visibleClipReferences: [TimelineClipReference],
        reference: TimelineClipReference,
        mode: TimelineSelectionMode
    ) -> TimelineSelectionResult {
        switch mode {
        case .replace:
            return TimelineSelectionResult(selectedClips: [reference], anchor: reference)
        case .toggle:
            var nextSelection = currentSelection
            if nextSelection.contains(reference) {
                nextSelection.remove(reference)
            } else {
                nextSelection.insert(reference)
            }
            let nextAnchor = nextSelection.contains(reference) ? reference : nextSelection.first
            return TimelineSelectionResult(selectedClips: nextSelection, anchor: nextAnchor)
        case .rangeOnTrack:
            guard let anchor,
                  anchor.trackID == reference.trackID,
                  let anchorIndex = visibleClipReferences.firstIndex(of: anchor),
                  let referenceIndex = visibleClipReferences.firstIndex(of: reference)
            else {
                return TimelineSelectionResult(selectedClips: [reference], anchor: reference)
            }

            let lowerIndex = min(anchorIndex, referenceIndex)
            let upperIndex = max(anchorIndex, referenceIndex)
            let selectedRange = visibleClipReferences[lowerIndex...upperIndex]
                .filter { $0.trackID == reference.trackID }
            return TimelineSelectionResult(selectedClips: Set(selectedRange), anchor: anchor)
        }
    }

    static func snapTargets(in sequence: Sequence, playheadFrame: Int64) -> [TimelineSnapTarget] {
        var targets = [TimelineSnapTarget(frame: playheadFrame, kind: .playhead)]
        for marker in sequence.markers {
            guard let frame = try? marker.time.frameIndex(at: sequence.timebase, rounding: .nearestOrAwayFromZero)
            else {
                continue
            }
            targets.append(TimelineSnapTarget(frame: frame, kind: .marker(marker.id)))
        }

        for track in sequence.videoTracks + sequence.audioTracks {
            for layout in clipLayouts(
                for: track,
                frameRate: sequence.timebase,
                pixelsPerFrame: 1.0
            ) {
                targets.append(TimelineSnapTarget(frame: layout.startFrame, kind: .clipEdge(layout.reference)))
                targets.append(TimelineSnapTarget(frame: layout.endFrame, kind: .clipEdge(layout.reference)))
            }
        }
        return targets
    }

    static func snappedFrame(
        proposedFrame: Int64,
        targets: [TimelineSnapTarget],
        toleranceFrames: Int64
    ) -> Int64 {
        var nearestFrame = proposedFrame
        var nearestDistance = max(0, toleranceFrames) + 1

        for target in targets {
            let distance = abs(target.frame - proposedFrame)
            if distance <= toleranceFrames,
               distance < nearestDistance
                   || (distance == nearestDistance && target.frame < nearestFrame)
            {
                nearestDistance = distance
                nearestFrame = target.frame
            }
        }

        return nearestFrame
    }

    static func selectedFrameRange(
        in sequence: Sequence,
        selectedClips: Set<TimelineClipReference>
    ) -> TimelineFrameRange? {
        let layouts = (sequence.videoTracks + sequence.audioTracks)
            .flatMap { clipLayouts(for: $0, frameRate: sequence.timebase, pixelsPerFrame: 1.0) }
            .filter { selectedClips.contains($0.reference) }

        guard let firstLayout = layouts.first else {
            return nil
        }

        var startFrame = firstLayout.startFrame
        var endFrame = firstLayout.endFrame
        for layout in layouts.dropFirst() {
            startFrame = min(startFrame, layout.startFrame)
            endFrame = max(endFrame, layout.endFrame)
        }
        return TimelineFrameRange(startFrame: startFrame, endFrame: endFrame)
    }

    private static func clamped(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(max(minimum, value), maximum)
    }
}
