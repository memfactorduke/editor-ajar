// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

// MARK: - FR-FX-001 / 002 / 003 app wiring

extension EditorAjarAppModel {
    // MARK: Inspector state

    var selectedEffectStackInspector: SelectedEffectStackInspectorState? {
        guard let selectedClip,
              selectedClip.kind == .video
        else {
            return nil
        }
        return SelectedEffectStackInspectorState(
            clipName: selectedClip.name,
            nodes: selectedClip.effectStack.nodes
        )
    }

    var selectedVideoTransitionState: SelectedVideoTransitionState? {
        guard let selectedClip,
              selectedClip.kind == .video,
              let selectedClipReference,
              let sequence = activeSequence,
              let track = sequence.videoTracks.first(where: { $0.id == selectedClipReference.trackID })
        else {
            return nil
        }
        let adjacent = Self.trailingAdjacentClip(
            after: selectedClip.id,
            in: track
        )
        return SelectedVideoTransitionState(
            clipName: selectedClip.name,
            hasAdjacentIncoming: adjacent != nil,
            transition: selectedClip.trailingTransition
        )
    }

    var canAddEffectToSelectedClip: Bool {
        isProjectEditable && selectedClip?.kind == .video
    }

    var canApplyVideoTransition: Bool {
        isProjectEditable
            && selectedVideoTransitionState?.hasAdjacentIncoming == true
    }

    var canRemoveVideoTransition: Bool {
        isProjectEditable
            && selectedVideoTransitionState?.transition != nil
    }

    var videoTransitionStatusMessage: String? {
        guard let videoTransitionError else { return nil }
        return AppString.videoTransitionFailureMessage(for: videoTransitionError)
    }

    // MARK: Effects library (FR-FX-002)

    /// Appends a built-in effect (identity defaults) to the selected video clip's stack.
    @discardableResult
    func addEffectToSelectedClip(kind: ClipEffectKind) -> Bool {
        guard isProjectEditable else {
            return false
        }
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              selectedClip?.kind == .video
        else {
            return false
        }
        effectParameterCoalesceActive = false
        effectParameterCoalesceKey = nil
        let node = ClipEffectNode(id: UUID(), definition: .identity(for: kind))
        return applyEdit(
            .addClipEffectNode(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                node: node,
                destinationIndex: nil
            )
        )
    }

    // MARK: Effect stack edits (FR-FX-003)

    @discardableResult
    func removeSelectedEffectNode(nodeID: UUID) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              selectedClip?.kind == .video
        else {
            return false
        }
        effectParameterCoalesceActive = false
        effectParameterCoalesceKey = nil
        return applyEdit(
            .removeClipEffectNode(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                nodeID: nodeID
            )
        )
    }

    @discardableResult
    func setSelectedEffectNodeEnabled(nodeID: UUID, enabled: Bool) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              selectedClip?.kind == .video
        else {
            return false
        }
        effectParameterCoalesceActive = false
        effectParameterCoalesceKey = nil
        return applyEdit(
            .setClipEffectNodeEnabled(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                nodeID: nodeID,
                enabled: enabled
            )
        )
    }

    /// Moves a stack node one step toward the start (earlier application) or end.
    @discardableResult
    func moveSelectedEffectNode(nodeID: UUID, delta: Int) -> Bool {
        guard delta == -1 || delta == 1,
              let sequenceID = activeSequence?.id,
              let selectedClipReference,
              let stack = selectedEffectStackInspector,
              let sourceIndex = stack.nodes.firstIndex(where: { $0.id == nodeID })
        else {
            return false
        }
        let destinationIndex = sourceIndex + delta
        guard stack.nodes.indices.contains(destinationIndex) else {
            return false
        }
        effectParameterCoalesceActive = false
        effectParameterCoalesceKey = nil
        return applyEdit(
            .moveClipEffectNode(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                nodeID: nodeID,
                destinationIndex: destinationIndex
            )
        )
    }

    @discardableResult
    func resetSelectedEffectNode(nodeID: UUID) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              selectedClip?.kind == .video
        else {
            return false
        }
        effectParameterCoalesceActive = false
        effectParameterCoalesceKey = nil
        return applyEdit(
            .resetClipEffectNode(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                nodeID: nodeID
            )
        )
    }

    @discardableResult
    func resetSelectedEffectStack() -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              selectedClip?.kind == .video
        else {
            return false
        }
        effectParameterCoalesceActive = false
        effectParameterCoalesceKey = nil
        return applyEdit(
            .resetClipEffectStack(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID
            )
        )
    }

    /// Sets one scalar parameter on a stack node (coalescable for continuous slider drags).
    @discardableResult
    func setSelectedEffectScalar(
        nodeID: UUID,
        parameterID: String,
        doubleValue: Double,
        coalesce: Bool = true
    ) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              let selectedClip,
              let node = selectedClip.effectStack.nodes.first(where: { $0.id == nodeID })
        else {
            return false
        }
        let layout = EffectParameterCatalog.layout(for: node.kind)
        guard let spec = layout.scalars.first(where: { $0.id == parameterID }) else {
            return false
        }
        let clamped = ColorFieldValueMapper.clamped(doubleValue, to: spec.range)
        let value = RationalValue.approximating(clamped)
        guard let definition = EffectParameterCatalog.settingScalar(
            parameterID: parameterID,
            to: value,
            in: node.definition
        ) else {
            return false
        }
        let coalesceKey = "\(nodeID.uuidString):\(parameterID)"
        let shouldCoalesce =
            coalesce
            && effectParameterCoalesceActive
            && effectParameterCoalesceKey == coalesceKey
            && editHistory?.nextUndoCommand.map { command in
                if case .setClipEffectNodeParameters(_, _, _, let undoNodeID, _) = command {
                    return undoNodeID == nodeID
                }
                return false
            } == true
        effectParameterCoalesceActive = true
        effectParameterCoalesceKey = coalesceKey
        return applyEdit(
            .setClipEffectNodeParameters(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                nodeID: nodeID,
                definition: definition
            ),
            coalescingWithPrevious: shouldCoalesce
        )
    }

    @discardableResult
    func setSelectedEffectMirrorAxis(nodeID: UUID, axis: ClipMirrorAxis) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              let selectedClip,
              let node = selectedClip.effectStack.nodes.first(where: { $0.id == nodeID }),
              let definition = EffectParameterCatalog.settingMirrorAxis(axis, in: node.definition)
        else {
            return false
        }
        effectParameterCoalesceActive = false
        effectParameterCoalesceKey = nil
        return applyEdit(
            .setClipEffectNodeParameters(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                nodeID: nodeID,
                definition: definition
            )
        )
    }

    /// Ends a continuous effect-parameter slider drag so the next gesture is a new undo step.
    func endEffectParameterSliderGesture() {
        effectParameterCoalesceActive = false
        effectParameterCoalesceKey = nil
    }

    // MARK: Video transitions (FR-FX-001)

    /// Default transition duration in frames (half second at 30 fps sample projects).
    static let defaultVideoTransitionDurationFrames: Int64 = 15

    @discardableResult
    func applyVideoTransitionToSelectedCut(
        kind: ClipVideoTransitionKind,
        durationFrames: Int64? = nil,
        direction: ClipVideoTransitionDirection? = nil
    ) -> Bool {
        videoTransitionError = nil
        guard project != nil else {
            videoTransitionError = .noProject
            return false
        }
        guard isProjectEditable else {
            videoTransitionError = .projectReadOnly
            return false
        }
        guard let sequence = activeSequence,
              let selectedClipReference,
              let selectedClip,
              selectedClip.kind == .video
        else {
            videoTransitionError = .noVideoClipSelected
            return false
        }
        guard selectedVideoTransitionState?.hasAdjacentIncoming == true else {
            videoTransitionError = .requiresAdjacentClips
            return false
        }
        let frames = durationFrames ?? Self.defaultVideoTransitionDurationFrames
        guard frames > 0 else {
            videoTransitionError = .invalidDuration
            return false
        }
        guard let duration = try? sequence.timebase.duration(ofFrames: frames) else {
            videoTransitionError = .invalidDuration
            return false
        }
        // Menu-apply can leave draft direction stale (e.g. wipe diagonal → push).
        // Clamp to the chosen kind's allowed set before building the command.
        let candidateDirection = direction ?? videoTransitionDraftDirection
        let allowedDirections = ClipVideoTransitionDirection.options(for: kind)
        let resolvedDirection: ClipVideoTransitionDirection
        if allowedDirections.contains(candidateDirection) {
            resolvedDirection = candidateDirection
        } else if let first = allowedDirections.first {
            resolvedDirection = first
        } else {
            resolvedDirection = candidateDirection
        }
        let applied = applyEdit(
            .setClipVideoTransition(
                sequenceID: sequence.id,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                duration: duration,
                kind: kind,
                color: nil,
                direction: kind.usesDirection ? resolvedDirection : nil
            )
        )
        if !applied {
            videoTransitionError = .applyFailed(
                AppString.localized(
                    "transition.error.applyGeneric",
                    "Could not apply the transition to this cut."
                )
            )
            return false
        }
        // Engine silently clamps duration to available handles — keep the field honest.
        resyncVideoTransitionDraftDurationFromResult()
        return true
    }

    /// Updates the duration draft from the transition that actually landed after apply.
    private func resyncVideoTransitionDraftDurationFromResult() {
        guard let existing = selectedVideoTransitionState?.transition,
              let sequence = activeSequence,
              let frames = try? existing.duration.frameIndex(
                at: sequence.timebase,
                rounding: .nearestOrAwayFromZero
              )
        else {
            return
        }
        videoTransitionDraftDurationFrames = "\(frames)"
    }

    @discardableResult
    func removeVideoTransitionFromSelectedCut() -> Bool {
        videoTransitionError = nil
        guard project != nil else {
            videoTransitionError = .noProject
            return false
        }
        guard isProjectEditable else {
            videoTransitionError = .projectReadOnly
            return false
        }
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              selectedClip?.kind == .video
        else {
            videoTransitionError = .noVideoClipSelected
            return false
        }
        guard selectedVideoTransitionState?.transition != nil else {
            videoTransitionError = .transitionNotFound
            return false
        }
        let applied = applyEdit(
            .removeClipVideoTransition(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID
            )
        )
        if !applied {
            videoTransitionError = .applyFailed(
                AppString.localized(
                    "transition.error.removeGeneric",
                    "Could not remove the transition from this cut."
                )
            )
        }
        return applied
    }

    /// Parses the draft duration field and applies/replaces the selected kind on the cut.
    @discardableResult
    func applyDraftVideoTransitionToSelectedCut() -> Bool {
        guard let frames = Self.parseDurationFrames(videoTransitionDraftDurationFrames) else {
            videoTransitionError = .invalidDuration
            return false
        }
        return applyVideoTransitionToSelectedCut(
            kind: videoTransitionDraftKind,
            durationFrames: frames,
            direction: videoTransitionDraftDirection
        )
    }

    func updateVideoTransitionDraftKind(_ kind: ClipVideoTransitionKind) {
        videoTransitionDraftKind = kind
        let options = ClipVideoTransitionDirection.options(for: kind)
        if !options.isEmpty, !options.contains(videoTransitionDraftDirection) {
            videoTransitionDraftDirection = options[0]
        }
    }

    func updateVideoTransitionDraftDurationFrames(_ raw: String) {
        videoTransitionDraftDurationFrames = raw
    }

    func updateVideoTransitionDraftDirection(_ direction: ClipVideoTransitionDirection) {
        videoTransitionDraftDirection = direction
    }

    /// Syncs draft fields from an existing transition when the selection changes.
    func refreshVideoTransitionDraftFromSelection() {
        if let existing = selectedVideoTransitionState?.transition,
           let sequence = activeSequence,
           let frames = try? existing.duration.frameIndex(
            at: sequence.timebase,
            rounding: .nearestOrAwayFromZero
           )
        {
            videoTransitionDraftKind = existing.kind
            videoTransitionDraftDirection = existing.direction
            videoTransitionDraftDurationFrames = "\(frames)"
        } else if selectedVideoTransitionState != nil {
            // Keep draft kind/direction; reset duration to default when no transition exists.
            if selectedVideoTransitionState?.transition == nil {
                videoTransitionDraftDurationFrames =
                    "\(Self.defaultVideoTransitionDurationFrames)"
            }
        }
    }

    // MARK: Helpers

    static func trailingAdjacentClip(after clipID: UUID, in track: Track) -> Clip? {
        let clips: [(index: Int, clip: Clip)] = track.items.enumerated().compactMap { index, item in
            guard case .clip(let clip) = item else {
                return nil
            }
            return (index, clip)
        }
        guard let source = clips.first(where: { $0.clip.id == clipID }) else {
            return nil
        }
        let nextIndex = source.index + 1
        guard nextIndex < track.items.count,
              case .clip(let incoming) = track.items[nextIndex]
        else {
            return nil
        }
        let outgoingEnd = try? source.clip.timelineRange.end()
        guard let outgoingEnd, outgoingEnd == incoming.timelineRange.start else {
            return nil
        }
        return incoming
    }

    static func parseDurationFrames(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int64(trimmed), value > 0 else {
            return nil
        }
        return value
    }
}

extension AppString {
    static func videoTransitionFailureMessage(for error: EditorAjarVideoTransitionError) -> String {
        switch error {
        case .noProject:
            return localized(
                "transition.error.noProject",
                "Open a project before applying a transition."
            )
        case .projectReadOnly:
            return localized(
                "transition.error.readOnly",
                "This project is read-only; transitions cannot be edited."
            )
        case .noVideoClipSelected:
            return localized(
                "transition.error.noClip",
                "Select a single video clip that owns the cut (the outgoing clip)."
            )
        case .requiresAdjacentClips:
            return localized(
                "transition.error.notAdjacent",
                "A transition needs two abutting clips on the same video track."
            )
        case .transitionNotFound:
            return localized(
                "transition.error.notFound",
                "There is no transition on the cut after the selected clip."
            )
        case .invalidDuration:
            return localized(
                "transition.error.invalidDuration",
                "Enter a positive duration in frames."
            )
        case .applyFailed(let message):
            return localized("transition.error.apply", "\(message)")
        }
    }
}
