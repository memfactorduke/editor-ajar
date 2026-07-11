// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarEffectsUITests: XCTestCase {
    // MARK: FR-FX-002 library

    func testFRFX002LibraryFilterMatchesNameAndCategory() {
        let all = EffectLibraryItem.filtered(searchText: "")
        XCTAssertEqual(all.count, EffectLibraryItem.all.count)
        XCTAssertFalse(all.contains { $0.kind == .placeholder })
        // LUT import is Color-tab only; identity LUT in Effects library is a dead-end.
        XCTAssertFalse(all.contains { $0.kind == .lut })

        let blur = EffectLibraryItem.filtered(searchText: "blur")
        XCTAssertTrue(blur.contains { $0.kind == .gaussianBlur })
        XCTAssertTrue(blur.contains { $0.kind == .boxBlur })
        XCTAssertTrue(blur.contains { $0.kind == .zoomBlur })
        XCTAssertFalse(blur.contains { $0.kind == .invert })

        let colorCategory = EffectLibraryItem.filtered(searchText: "Color")
        XCTAssertTrue(colorCategory.contains { $0.kind == .colorAdjust })
        XCTAssertTrue(colorCategory.contains { $0.kind == .posterize })

        let none = EffectLibraryItem.filtered(searchText: "zzzz-no-such-effect")
        XCTAssertTrue(none.isEmpty)
    }

    func testFRFX002AddEffectToSelectedClipIsUndoable() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.count, 0)

        XCTAssertTrue(model.addEffectToSelectedClip(kind: .gaussianBlur))
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.count, 1)
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.first?.kind, .gaussianBlur)
        XCTAssertEqual(model.undoMenuTitle, "Undo Add Effect")

        model.undo()
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.count, 0)
        model.redo()
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.count, 1)
    }

    // MARK: FR-FX-003 stack inspector actions

    func testFRFX003RemoveReorderEnableParamResetAndUndoSymmetry() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)

        XCTAssertTrue(model.addEffectToSelectedClip(kind: .gaussianBlur))
        XCTAssertTrue(model.addEffectToSelectedClip(kind: .sharpen))
        let nodes = try XCTUnwrap(model.selectedEffectStackInspector?.nodes)
        XCTAssertEqual(nodes.count, 2)
        let blurID = nodes[0].id
        let sharpenID = nodes[1].id

        // Enable toggle
        XCTAssertTrue(model.setSelectedEffectNodeEnabled(nodeID: blurID, enabled: false))
        XCTAssertEqual(
            model.selectedEffectStackInspector?.nodes.first(where: { $0.id == blurID })?.enabled,
            false
        )
        XCTAssertEqual(model.undoMenuTitle, "Undo Toggle Effect")
        model.undo()
        XCTAssertEqual(
            model.selectedEffectStackInspector?.nodes.first(where: { $0.id == blurID })?.enabled,
            true
        )
        model.redo()

        // Reorder: move sharpen up
        XCTAssertTrue(model.moveSelectedEffectNode(nodeID: sharpenID, delta: -1))
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.map(\.id), [sharpenID, blurID])
        XCTAssertEqual(model.undoMenuTitle, "Undo Reorder Effect")
        model.undo()
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.map(\.id), [blurID, sharpenID])
        model.redo()

        // Parameter set (discrete, no coalesce)
        XCTAssertTrue(
            model.setSelectedEffectScalar(
                nodeID: blurID,
                parameterID: "radius",
                doubleValue: 12,
                coalesce: false
            )
        )
        let radius = try XCTUnwrap(
            model.selectedEffectStackInspector?.nodes
                .first(where: { $0.id == blurID })
                .flatMap { node -> RationalValue? in
                    if case .gaussianBlur(let p) = node.definition { return p.radius }
                    return nil
                }
        )
        XCTAssertEqual(radius.doubleValue, 12, accuracy: 0.001)
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Effect Parameters")

        // Reset node
        XCTAssertTrue(model.resetSelectedEffectNode(nodeID: blurID))
        let resetRadius = try XCTUnwrap(
            model.selectedEffectStackInspector?.nodes
                .first(where: { $0.id == blurID })
                .flatMap { node -> RationalValue? in
                    if case .gaussianBlur(let p) = node.definition { return p.radius }
                    return nil
                }
        )
        XCTAssertEqual(resetRadius, .zero)
        XCTAssertEqual(model.undoMenuTitle, "Undo Reset Effect")
        model.undo()
        let restored = try XCTUnwrap(
            model.selectedEffectStackInspector?.nodes
                .first(where: { $0.id == blurID })
                .flatMap { node -> RationalValue? in
                    if case .gaussianBlur(let p) = node.definition { return p.radius }
                    return nil
                }
        )
        XCTAssertEqual(restored.doubleValue, 12, accuracy: 0.001)

        // Remove
        XCTAssertTrue(model.removeSelectedEffectNode(nodeID: sharpenID))
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.count, 1)
        XCTAssertEqual(model.undoMenuTitle, "Undo Remove Effect")
        model.undo()
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.count, 2)
    }

    func testFRFX003ParameterSliderCoalescesIntoSingleUndoStep() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)
        XCTAssertTrue(model.addEffectToSelectedClip(kind: .glow))
        let nodeID = try XCTUnwrap(model.selectedEffectStackInspector?.nodes.first?.id)
        let beforeCount = model.editHistory?.undoCount ?? 0

        XCTAssertTrue(
            model.setSelectedEffectScalar(
                nodeID: nodeID,
                parameterID: "amount",
                doubleValue: 0.2,
                coalesce: true
            )
        )
        XCTAssertTrue(
            model.setSelectedEffectScalar(
                nodeID: nodeID,
                parameterID: "amount",
                doubleValue: 0.4,
                coalesce: true
            )
        )
        XCTAssertTrue(
            model.setSelectedEffectScalar(
                nodeID: nodeID,
                parameterID: "amount",
                doubleValue: 0.6,
                coalesce: true
            )
        )
        XCTAssertEqual((model.editHistory?.undoCount ?? 0) - beforeCount, 1)

        model.endEffectParameterSliderGesture()
        XCTAssertTrue(
            model.setSelectedEffectScalar(
                nodeID: nodeID,
                parameterID: "radius",
                doubleValue: 8,
                coalesce: true
            )
        )
        XCTAssertEqual((model.editHistory?.undoCount ?? 0) - beforeCount, 2)
    }

    func testFRFX003ResetStackClearsAllNodes() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)
        XCTAssertTrue(model.addEffectToSelectedClip(kind: .vignette))
        XCTAssertTrue(model.addEffectToSelectedClip(kind: .mirror))
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.count, 2)
        XCTAssertTrue(model.resetSelectedEffectStack())
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.count, 0)
        XCTAssertEqual(model.undoMenuTitle, "Undo Reset Effects Stack")
        model.undo()
        XCTAssertEqual(model.selectedEffectStackInspector?.nodes.count, 2)
    }

    // MARK: FR-FX-001 transitions

    func testFRFX001ApplyReplaceRemoveTransitionAndUndo() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let outgoing = try makeAdjacentVideoCut(in: model)

        XCTAssertTrue(model.canApplyVideoTransition)
        XCTAssertNil(model.selectedVideoTransitionState?.transition)

        XCTAssertTrue(
            model.applyVideoTransitionToSelectedCut(
                kind: .crossDissolve,
                durationFrames: 10
            )
        )
        XCTAssertEqual(
            model.selectedVideoTransitionState?.transition?.kind,
            .crossDissolve
        )
        XCTAssertEqual(model.undoMenuTitle, "Undo Add Transition")

        // Replace
        XCTAssertTrue(
            model.applyVideoTransitionToSelectedCut(
                kind: .wipe,
                durationFrames: 8,
                direction: .topLeft
            )
        )
        XCTAssertEqual(model.selectedVideoTransitionState?.transition?.kind, .wipe)
        XCTAssertEqual(
            model.selectedVideoTransitionState?.transition?.direction,
            .topLeft
        )

        model.undo()
        XCTAssertEqual(
            model.selectedVideoTransitionState?.transition?.kind,
            .crossDissolve
        )
        model.redo()
        XCTAssertEqual(model.selectedVideoTransitionState?.transition?.kind, .wipe)

        XCTAssertTrue(model.removeVideoTransitionFromSelectedCut())
        XCTAssertNil(model.selectedVideoTransitionState?.transition)
        XCTAssertEqual(model.undoMenuTitle, "Undo Remove Transition")
        model.undo()
        XCTAssertEqual(model.selectedVideoTransitionState?.transition?.kind, .wipe)

        // Outgoing still selected
        XCTAssertEqual(model.selectedClip?.id, outgoing.id)
    }

    func testFRFX001AdjacencyRefusalIsTypedAndNonBlocking() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        // Single sample clip has no abutting neighbor.
        try selectSampleVideoClip(in: model)
        XCTAssertFalse(model.canApplyVideoTransition)
        XCTAssertFalse(
            model.applyVideoTransitionToSelectedCut(kind: .fade, durationFrames: 10)
        )
        XCTAssertEqual(model.videoTransitionError, .requiresAdjacentClips)
        XCTAssertNotNil(model.videoTransitionStatusMessage)
        // Session remains usable.
        XCTAssertNotNil(model.project)
        XCTAssertTrue(model.isProjectEditable)
    }

    func testFRFX001DraftApplyUsesDurationField() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        _ = try makeAdjacentVideoCut(in: model)
        model.updateVideoTransitionDraftKind(.slide)
        model.updateVideoTransitionDraftDirection(.right)
        model.updateVideoTransitionDraftDurationFrames("12")
        XCTAssertTrue(model.applyDraftVideoTransitionToSelectedCut())
        let transition = try XCTUnwrap(model.selectedVideoTransitionState?.transition)
        XCTAssertEqual(transition.kind, .slide)
        XCTAssertEqual(transition.direction, .right)
        let sequence = try XCTUnwrap(model.activeSequence)
        let frames = try transition.duration.frameIndex(
            at: sequence.timebase,
            rounding: .nearestOrAwayFromZero
        )
        XCTAssertEqual(frames, 12)

        model.updateVideoTransitionDraftDurationFrames("0")
        XCTAssertFalse(model.applyDraftVideoTransitionToSelectedCut())
        XCTAssertEqual(model.videoTransitionError, .invalidDuration)
    }

    /// Menu-apply Push must not reuse a stale wipe diagonal from the draft direction.
    func testFRFX001MenuApplyPushSanitizesStaleDiagonalDirection() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        _ = try makeAdjacentVideoCut(in: model)

        XCTAssertTrue(
            model.applyVideoTransitionToSelectedCut(
                kind: .wipe,
                durationFrames: 10,
                direction: .topLeft
            )
        )
        XCTAssertEqual(
            model.selectedVideoTransitionState?.transition?.direction,
            .topLeft
        )
        // Selection refresh (and/or prior apply) leaves diagonal in the draft.
        model.refreshVideoTransitionDraftFromSelection()
        XCTAssertEqual(model.videoTransitionDraftDirection, .topLeft)

        // Menu path: kind only — same as Clip → Transition → Push.
        XCTAssertTrue(model.applyVideoTransitionToSelectedCut(kind: .push))
        let applied = try XCTUnwrap(model.selectedVideoTransitionState?.transition)
        XCTAssertEqual(applied.kind, .push)
        XCTAssertTrue(applied.direction.isLinear)
        XCTAssertEqual(applied.direction, .left)
    }

    /// Successful apply rewrites the duration field from the engine-clamped result.
    func testFRFX001ApplyResyncsDraftDurationFromResult() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        _ = try makeAdjacentVideoCut(in: model)
        // Request more frames than a short outgoing half can support; engine clamps.
        model.updateVideoTransitionDraftDurationFrames("100")
        XCTAssertTrue(
            model.applyVideoTransitionToSelectedCut(
                kind: .crossDissolve,
                durationFrames: 100
            )
        )
        let transition = try XCTUnwrap(model.selectedVideoTransitionState?.transition)
        let sequence = try XCTUnwrap(model.activeSequence)
        let appliedFrames = try transition.duration.frameIndex(
            at: sequence.timebase,
            rounding: .nearestOrAwayFromZero
        )
        XCTAssertLessThan(appliedFrames, 100)
        XCTAssertEqual(model.videoTransitionDraftDurationFrames, "\(appliedFrames)")
    }

    // MARK: Helpers

    @discardableResult
    private func selectSampleVideoClip(in model: EditorAjarAppModel) throws -> Clip {
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
        let clip = try firstClip(in: videoTrack)
        model.selectClip(trackID: videoTrack.id, clipID: clip.id, mode: .replace)
        return clip
    }

    /// Blades the sample video clip so the outgoing piece owns an abutting cut; selects outgoing.
    @discardableResult
    private func makeAdjacentVideoCut(in model: EditorAjarAppModel) throws -> Clip {
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
        let original = try firstClip(in: videoTrack)
        model.selectClip(trackID: videoTrack.id, clipID: original.id, mode: .replace)
        model.scrub(to: 30)
        XCTAssertTrue(model.bladeSelectedClipAtPlayhead())

        let refreshedTrack = try XCTUnwrap(
            model.activeSequence?.videoTracks.first(where: { $0.id == videoTrack.id })
        )
        let videoClips = refreshedTrack.items.compactMap { item -> Clip? in
            guard case .clip(let clip) = item, clip.kind == .video else { return nil }
            return clip
        }
        XCTAssertGreaterThanOrEqual(videoClips.count, 2)
        // Earliest timeline clip is the outgoing owner of the cut.
        let outgoing = try XCTUnwrap(
            videoClips.min { lhs, rhs in
                lhs.timelineRange.start < rhs.timelineRange.start
            }
        )
        model.selectClip(trackID: videoTrack.id, clipID: outgoing.id, mode: .replace)
        XCTAssertTrue(model.selectedVideoTransitionState?.hasAdjacentIncoming == true)
        return outgoing
    }

    private func firstClip(in track: Track) throws -> Clip {
        for item in track.items {
            if case .clip(let clip) = item {
                return clip
            }
        }
        struct MissingClip: Error {}
        throw MissingClip()
    }
}
