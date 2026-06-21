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

    private var playbackController: EditorAjarPlaybackController?
    private var renderPipeline: EditorAjarRenderPipeline?
    private var displayLinkDriver: EditorAjarDisplayLinkDriver?
    private var editHistory: EditHistory?
    private let autosaveCoordinator: EditorAjarAutosaveCoordinator?
    private let autosaveIntervalSeconds: TimeInterval
    private var autosaveLoopTask: Task<Void, Never>?
    private var autosaveWriteTask: Task<Void, Never>?
    private var autosaveCommandCount = 0
    private var renderGeneration = 0
    private var sequenceContexts: [UUID: SequenceEditingContext] = [:]

    init(autosavePackageURL: URL? = nil, autosaveIntervalSeconds: TimeInterval = 5.0) {
        self.autosaveIntervalSeconds = autosaveIntervalSeconds
        if let autosavePackageURL {
            autosaveCoordinator = EditorAjarAutosaveCoordinator(packageURL: autosavePackageURL)
        } else {
            autosaveCoordinator = nil
        }

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

    var selectedClipIsLinked: Bool {
        selectedClip?.linkGroupID != nil
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
            displayLinkDriver?.start()
        } else {
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
        displayLinkDriver?.stop()
        playbackController?.stepBackward()
        syncPlayheadFromController()
        requestRenderForCurrentFrame()
    }

    func stepForward() {
        isPlaying = false
        displayLinkDriver?.stop()
        playbackController?.stepForward()
        syncPlayheadFromController()
        requestRenderForCurrentFrame()
    }

    func scrub(to frame: Int64) {
        isPlaying = false
        displayLinkDriver?.stop()
        playbackController?.scrub(to: frame)
        syncPlayheadFromController()
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

    func undo() {
        guard var history = editHistory, let project = history.undo() else {
            return
        }

        editHistory = history
        updateProject(project)
        scheduleAutosaveCheckpoint(project: project)
    }

    func redo() {
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

    func autosaveCheckpointForTesting() async {
        await autosaveWriteTask?.value
        await autosaveCurrentProjectAndWait()
    }

    private func displayLinkTick(_ deltaSeconds: Double) {
        guard isPlaying, playbackController?.advance(by: deltaSeconds) == true else {
            return
        }

        syncPlayheadFromController()
        requestRenderForCurrentFrame()
    }

    private func syncPlayheadFromController() {
        playheadFrame = playbackController?.playheadFrame ?? 0
        persistActiveSequenceContext()
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

    private func editMenuTitle(prefix: String, command: EditCommand?) -> String {
        guard let command else {
            return prefix
        }
        return "\(prefix) \(command.actionName)"
    }

    @discardableResult
    private func applyEdit(_ command: EditCommand) -> Bool {
        guard var history = editHistory else {
            return false
        }

        do {
            persistActiveSequenceContext()
            let project = try history.apply(command)
            editHistory = history
            updateProject(project)
            scheduleAutosave(command: command, project: project)
            return true
        } catch {
            loadMessage = "Edit failed: \(error)"
            return false
        }
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
