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
            durationFrames = Self.durationFrames(for: initialProject)
            if let sequence = initialProject.sequences.first {
                playbackController = EditorAjarPlaybackController(
                    frameRate: sequence.timebase,
                    durationFrames: durationFrames
                )
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

    var activeSequence: Sequence? {
        project?.sequences.first
    }

    var activeSequenceName: String {
        activeSequence?.name ?? "No Sequence"
    }

    var projectSummary: String {
        guard let project else {
            return "No project"
        }

        let sequenceCount = project.sequences.count
        let mediaCount = project.mediaPool.count
        return "\(sequenceCount) sequence, \(mediaCount) media items"
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
        }
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
    }

    func setTimelineRangeOut() {
        timelineState.selectionOutFrame = playheadFrame
    }

    func clearTimelineRange() {
        timelineState.selectionInFrame = nil
        timelineState.selectionOutFrame = nil
    }

    func setTimelineSnappingEnabled(_ isEnabled: Bool) {
        timelineState.snappingEnabled = isEnabled
    }

    func zoomTimelineIn() {
        timelineState.pixelsPerFrame = TimelineInteraction.zoomedPixelsPerFrame(
            timelineState.pixelsPerFrame,
            factor: 1.25
        )
    }

    func zoomTimelineOut() {
        timelineState.pixelsPerFrame = TimelineInteraction.zoomedPixelsPerFrame(
            timelineState.pixelsPerFrame,
            factor: 0.8
        )
    }

    func zoomTimelineVerticallyIn() {
        timelineState.laneHeight = TimelineInteraction.zoomedLaneHeight(
            timelineState.laneHeight,
            factor: 1.18
        )
    }

    func zoomTimelineVerticallyOut() {
        timelineState.laneHeight = TimelineInteraction.zoomedLaneHeight(
            timelineState.laneHeight,
            factor: 0.85
        )
    }

    func fitTimeline(toWidth availableWidth: Double) {
        timelineState.pixelsPerFrame = TimelineInteraction.fittedPixelsPerFrame(
            durationFrames: durationFrames,
            availableWidth: availableWidth
        )
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

    private static func durationFrames(for project: Project) -> Int64 {
        guard let sequence = project.sequences.first else {
            return 1
        }

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

    @discardableResult
    private func applyEdit(_ command: EditCommand) -> Bool {
        guard var history = editHistory else {
            return false
        }

        do {
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
        self.project = project
        durationFrames = Self.durationFrames(for: project)
        let availableClipIDs = Set(
            project.sequences.first.map(TimelineInteraction.clipReferences(in:)) ?? []
        )
        let availableMarkerIDs = Set(project.sequences.first?.markers.map(\.id) ?? [])
        timelineState.selectedClips = timelineState.selectedClips.intersection(availableClipIDs)
        if let anchor = timelineState.selectionAnchor,
           !availableClipIDs.contains(anchor)
        {
            timelineState.selectionAnchor = timelineState.selectedClips.first
        }
        if let selectedMarkerID = timelineState.selectedMarkerID,
           !availableMarkerIDs.contains(selectedMarkerID)
        {
            timelineState.selectedMarkerID = nil
        }
        requestRenderForCurrentFrame()
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
                await self?.autosaveCurrentProject()
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
