// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarTitleUITests: XCTestCase {
    // MARK: FR-TXT-001 insert title

    func testFRTXT001InsertTitleAtPlayheadIsUndoable() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let sequence = try XCTUnwrap(model.activeSequence)
        let beforeTrackCount = sequence.videoTracks.count
        let beforeClipCount = titleClipCount(in: sequence)
        let beforeUndo = model.editHistory?.undoCount ?? 0

        // Scrub past the sample title so insert lands on free timeline range of V2.
        model.scrub(to: 90)
        XCTAssertTrue(model.insertTitleAtPlayhead())
        XCTAssertEqual((model.editHistory?.undoCount ?? 0) - beforeUndo, 1)
        XCTAssertEqual(model.undoMenuTitle, "Undo Insert Title")

        let after = try XCTUnwrap(model.activeSequence)
        XCTAssertEqual(titleClipCount(in: after), beforeClipCount + 1)
        // Topmost unlocked track already exists in sample project — no new track.
        XCTAssertEqual(after.videoTracks.count, beforeTrackCount)

        let selected = try XCTUnwrap(model.selectedClip)
        guard case .title(let title) = selected.source else {
            return XCTFail("expected title source")
        }
        XCTAssertEqual(title.boxes.count, 1)
        XCTAssertEqual(title.boxes.first?.text, TitleInsertDefaults.text)
        XCTAssertEqual(selected.timelineRange.duration, try TitleInsertDefaults.duration())
        XCTAssertNotNil(model.selectedTitleInspector)
        XCTAssertEqual(model.selectedClipInspectorTab, .title)

        model.undo()
        XCTAssertEqual(titleClipCount(in: try XCTUnwrap(model.activeSequence)), beforeClipCount)
    }

    func testFRTXT001InsertTitleCreatesTrackWhenAllVideoTracksLocked() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let sequence = try XCTUnwrap(model.activeSequence)
        let beforeTrackCount = sequence.videoTracks.count

        // Lock every video track so insert must add a new track + title in one undo step.
        for track in sequence.videoTracks {
            model.setTrackState(
                sequenceID: sequence.id,
                trackID: track.id,
                locked: true
            )
        }
        let afterLocks = model.editHistory?.undoCount ?? 0
        XCTAssertTrue(model.insertTitleAtPlayhead())
        // One undo step for the multi-command insert (add track + insert title).
        XCTAssertEqual((model.editHistory?.undoCount ?? 0) - afterLocks, 1)

        let after = try XCTUnwrap(model.activeSequence)
        XCTAssertEqual(after.videoTracks.count, beforeTrackCount + 1)
        XCTAssertFalse(try XCTUnwrap(after.videoTracks.last).locked)
        guard case .title = model.selectedClip?.source else {
            return XCTFail("expected title selection")
        }

        model.undo()
        XCTAssertEqual(
            try XCTUnwrap(model.activeSequence).videoTracks.count,
            beforeTrackCount
        )
    }

    /// Playhead inside an existing clip on the topmost unlocked track must NOT ripple-overlap;
    /// titles overlay by creating a track above (one undo step).
    func testFRTXT001InsertTitleWhenPlayheadInsideClipCreatesTrackAbove() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let sequence = try XCTUnwrap(model.activeSequence)
        let beforeTrackCount = sequence.videoTracks.count
        let beforeClipCount = titleClipCount(in: sequence)
        let beforeUndo = model.editHistory?.undoCount ?? 0

        // Sample title occupies frames [0, 60) on V2 (topmost unlocked) — playhead inside it.
        model.scrub(to: 30)
        XCTAssertTrue(model.insertTitleAtPlayhead())
        XCTAssertEqual((model.editHistory?.undoCount ?? 0) - beforeUndo, 1)
        XCTAssertEqual(model.undoMenuTitle, "Undo Insert Title")

        let after = try XCTUnwrap(model.activeSequence)
        XCTAssertEqual(after.videoTracks.count, beforeTrackCount + 1)
        XCTAssertEqual(titleClipCount(in: after), beforeClipCount + 1)

        // Title lands on the new topmost track, not on the occupied track below.
        let topTrack = try XCTUnwrap(after.videoTracks.last)
        let insertedOnTop = topTrack.items.contains { item in
            guard case .clip(let clip) = item, case .title = clip.source else {
                return false
            }
            return clip.id == model.selectedClip?.id
        }
        XCTAssertTrue(insertedOnTop, "inserted title should land on the new track above")
        guard case .title = model.selectedClip?.source else {
            return XCTFail("expected title selection")
        }
        // Existing sample title track must be undisturbed (no ripple displacement).
        XCTAssertEqual(
            after.videoTracks[beforeTrackCount - 1].items.count,
            sequence.videoTracks[beforeTrackCount - 1].items.count
        )

        model.undo()
        let undone = try XCTUnwrap(model.activeSequence)
        XCTAssertEqual(undone.videoTracks.count, beforeTrackCount)
        XCTAssertEqual(titleClipCount(in: undone), beforeClipCount)
    }

    // MARK: Style inspector round-trips + coalescing

    func testFRTXT001StyleTypographyRoundTripAndUndo() throws {
        let model = try makeModelWithSampleTitleSelected()
        let original = try XCTUnwrap(model.selectedTitleInspector?.selectedBox?.style)

        XCTAssertTrue(model.setSelectedTitleFontWeight(.bold))
        XCTAssertEqual(model.selectedTitleInspector?.selectedBox?.style.fontWeight, .bold)

        XCTAssertTrue(model.setSelectedTitleAlignment(.center))
        XCTAssertEqual(model.selectedTitleInspector?.selectedBox?.style.alignment, .center)

        XCTAssertTrue(
            model.setSelectedTitleScalar(.fontSize, doubleValue: 64, coalesce: false)
        )
        XCTAssertEqual(
            model.selectedTitleInspector?.selectedBox?.style.fontSize.doubleValue ?? 0,
            64,
            accuracy: 0.01
        )

        XCTAssertTrue(
            model.setSelectedTitleColorChannel(
                target: .fill,
                component: .red,
                doubleValue: 0.25,
                coalesce: false
            )
        )
        XCTAssertEqual(
            model.selectedTitleInspector?.selectedBox?.style.color.red.doubleValue ?? 0,
            0.25,
            accuracy: 0.001
        )

        // Undo back to original style (4 discrete steps).
        model.undo()
        model.undo()
        model.undo()
        model.undo()
        XCTAssertEqual(model.selectedTitleInspector?.selectedBox?.style, original)
    }

    func testFRTXT002StrokeShadowBackgroundGradientRoundTrip() throws {
        let model = try makeModelWithSampleTitleSelected()

        XCTAssertTrue(model.setSelectedTitleStrokeEnabled(true))
        XCTAssertNotNil(model.selectedTitleInspector?.selectedBox?.style.stroke)
        XCTAssertTrue(
            model.setSelectedTitleScalar(.strokeWidth, doubleValue: 3, coalesce: false)
        )
        XCTAssertEqual(
            model.selectedTitleInspector?.selectedBox?.style.stroke?.width.doubleValue ?? 0,
            3,
            accuracy: 0.01
        )
        XCTAssertTrue(model.setSelectedTitleStrokeJoin(.round))
        XCTAssertEqual(model.selectedTitleInspector?.selectedBox?.style.stroke?.join, .round)

        XCTAssertTrue(model.setSelectedTitleDropShadowEnabled(true))
        XCTAssertTrue(
            model.setSelectedTitleScalar(.shadowBlur, doubleValue: 12, coalesce: false)
        )
        XCTAssertEqual(
            model.selectedTitleInspector?.selectedBox?.style.dropShadow?.blurRadius.doubleValue
                ?? 0,
            12,
            accuracy: 0.01
        )

        XCTAssertTrue(model.setSelectedTitleBackgroundEnabled(true))
        XCTAssertTrue(
            model.setSelectedTitleScalar(.backgroundPadding, doubleValue: 16, coalesce: false)
        )
        XCTAssertEqual(
            model.selectedTitleInspector?.selectedBox?.backgroundBox?.padding.doubleValue ?? 0,
            16,
            accuracy: 0.01
        )

        XCTAssertTrue(model.setSelectedTitleGradientEnabled(true))
        XCTAssertTrue(
            model.setSelectedTitleScalar(.gradientAngle, doubleValue: 90, coalesce: false)
        )
        XCTAssertEqual(
            model.selectedTitleInspector?.selectedBox?.style.gradientFill?.angleDegrees
                .doubleValue ?? 0,
            90,
            accuracy: 0.01
        )
        XCTAssertTrue(
            model.setSelectedTitleColorChannel(
                target: .gradientStart,
                component: .green,
                doubleValue: 0.5,
                coalesce: false
            )
        )
        XCTAssertEqual(
            model.selectedTitleInspector?.selectedBox?.style.gradientFill?.startColor.green
                .doubleValue ?? 0,
            0.5,
            accuracy: 0.001
        )

        // Discrete disables clear optional styling.
        XCTAssertTrue(model.setSelectedTitleGradientEnabled(false))
        XCTAssertNil(model.selectedTitleInspector?.selectedBox?.style.gradientFill)
        XCTAssertTrue(model.setSelectedTitleBackgroundEnabled(false))
        XCTAssertNil(model.selectedTitleInspector?.selectedBox?.backgroundBox)
        XCTAssertTrue(model.setSelectedTitleDropShadowEnabled(false))
        XCTAssertNil(model.selectedTitleInspector?.selectedBox?.style.dropShadow)
        XCTAssertTrue(model.setSelectedTitleStrokeEnabled(false))
        XCTAssertNil(model.selectedTitleInspector?.selectedBox?.style.stroke)
    }

    func testFRTXT001StyleSliderCoalescesIntoSingleUndoStep() throws {
        let model = try makeModelWithSampleTitleSelected()
        let beforeCount = model.editHistory?.undoCount ?? 0
        let originalSize =
            model.selectedTitleInspector?.selectedBox?.style.fontSize.doubleValue ?? 0

        XCTAssertTrue(model.setSelectedTitleScalar(.fontSize, doubleValue: 30, coalesce: true))
        XCTAssertTrue(model.setSelectedTitleScalar(.fontSize, doubleValue: 40, coalesce: true))
        XCTAssertTrue(model.setSelectedTitleScalar(.fontSize, doubleValue: 50, coalesce: true))
        model.endTitleStyleSliderGesture()

        XCTAssertEqual((model.editHistory?.undoCount ?? 0) - beforeCount, 1)
        XCTAssertEqual(
            model.selectedTitleInspector?.selectedBox?.style.fontSize.doubleValue ?? 0,
            50,
            accuracy: 0.01
        )
        model.undo()
        XCTAssertEqual(
            model.selectedTitleInspector?.selectedBox?.style.fontSize.doubleValue ?? 0,
            originalSize,
            accuracy: 0.01
        )
    }

    func testFRTXT001GestureBoundaryProducesSeparateUndoSteps() throws {
        let model = try makeModelWithSampleTitleSelected()
        let beforeCount = model.editHistory?.undoCount ?? 0

        // Gesture 1: continuous tracking drag → one undo step.
        XCTAssertTrue(model.setSelectedTitleScalar(.tracking, doubleValue: 2, coalesce: true))
        XCTAssertTrue(model.setSelectedTitleScalar(.tracking, doubleValue: 4, coalesce: true))
        model.endTitleStyleSliderGesture()

        // Gesture 2: continuous leading drag after gesture end → second undo step.
        XCTAssertTrue(model.setSelectedTitleScalar(.leading, doubleValue: 6, coalesce: true))
        XCTAssertTrue(model.setSelectedTitleScalar(.leading, doubleValue: 8, coalesce: true))
        model.endTitleStyleSliderGesture()

        // Gesture 3: continuous font-size drag → third undo step.
        XCTAssertTrue(model.setSelectedTitleScalar(.fontSize, doubleValue: 30, coalesce: true))
        XCTAssertTrue(model.setSelectedTitleScalar(.fontSize, doubleValue: 36, coalesce: true))
        model.endTitleStyleSliderGesture()

        // Contract: one drag = one step; three separate gestures = three steps.
        XCTAssertEqual((model.editHistory?.undoCount ?? 0) - beforeCount, 3)

        // Discrete weight is its own control/step and must not leave coalesce armed for a
        // following drag (mirrors FR-COL-001). Real focus-loss also disarms (P3b); no-op
        // focus re-fires for the same editor id must not invent extra steps.
        let afterGestures = model.editHistory?.undoCount ?? 0
        let editorID = UUID()
        XCTAssertTrue(model.textEditorFocusChanged(id: editorID, isFocused: true))
        // Spurious re-gain for the same id is a no-op (must not side-effect coalescing).
        XCTAssertFalse(model.textEditorFocusChanged(id: editorID, isFocused: true))
        XCTAssertTrue(model.setSelectedTitleFontWeight(.medium))
        // No-op blur while already blurred (e.g. disappear after onChange) must not split.
        XCTAssertTrue(model.textEditorFocusChanged(id: editorID, isFocused: false))
        XCTAssertFalse(model.textEditorFocusChanged(id: editorID, isFocused: false))
        XCTAssertTrue(model.setSelectedTitleScalar(.fontSize, doubleValue: 48, coalesce: true))
        XCTAssertEqual((model.editHistory?.undoCount ?? 0) - afterGestures, 2)
    }

    // MARK: Multi-box sync

    func testFRTXT001BoxAddRemoveSelectSyncsWithCanvasSelection() throws {
        let model = try makeModelWithSampleTitleSelected()
        let initialCount = try XCTUnwrap(model.selectedTitleInspector?.title.boxes.count)
        XCTAssertGreaterThanOrEqual(initialCount, 1)

        let firstID = try XCTUnwrap(model.selectedTitleInspector?.selectedBoxID)
        XCTAssertTrue(model.addTitleTextBox())
        let addedID = try XCTUnwrap(model.selectedTitleInspector?.selectedBoxID)
        XCTAssertNotEqual(addedID, firstID)
        XCTAssertEqual(model.selectedCanvasTitleBoxReference?.boxID, addedID)
        XCTAssertEqual(
            model.selectedTitleInspector?.title.boxes.count,
            initialCount + 1
        )

        XCTAssertTrue(model.selectTitleInspectorBox(id: firstID))
        XCTAssertEqual(model.selectedCanvasTitleBoxReference?.boxID, firstID)
        XCTAssertEqual(model.selectedTitleInspector?.selectedBoxID, firstID)

        XCTAssertTrue(model.removeSelectedTitleTextBox())
        XCTAssertEqual(
            model.selectedTitleInspector?.title.boxes.count,
            initialCount
        )
        XCTAssertFalse(
            model.selectedTitleInspector?.title.boxes.contains(where: { $0.id == firstID })
                ?? true
        )
        // Selection moves to a remaining box.
        XCTAssertNotNil(model.selectedTitleInspector?.selectedBoxID)

        model.undo() // restore removed box
        model.undo() // remove added box path partial — add was separate
        // At minimum, add then remove are each undoable steps.
    }

    // MARK: FR-TXT-004 presets

    func testFRTXT004ApplyPresetAndUndo() throws {
        let model = try makeModelWithSampleTitleSelected()
        let beforeAnimation = try XCTUnwrap(model.selectedClip?.transformAnimation)
        let beforeCount = model.editHistory?.undoCount ?? 0

        XCTAssertTrue(model.applyTitleAnimationPresetToSelection(kind: .fade))
        XCTAssertEqual((model.editHistory?.undoCount ?? 0) - beforeCount, 1)
        XCTAssertEqual(model.undoMenuTitle, "Undo Apply Title Animation")

        let after = try XCTUnwrap(model.selectedClip?.transformAnimation)
        XCTAssertNotEqual(after.opacity.keyframes.count, beforeAnimation.opacity.keyframes.count)
        XCTAssertFalse(after.opacity.keyframes.isEmpty)

        model.undo()
        XCTAssertEqual(
            model.selectedClip?.transformAnimation,
            beforeAnimation
        )
    }

    func testFRTXT004ApplyTypewriterPresetSetsReveal() throws {
        let model = try makeModelWithSampleTitleSelected()
        XCTAssertTrue(model.applyTitleAnimationPresetToSelection(kind: .typewriter))
        guard case .title(let title) = model.selectedClip?.source else {
            return XCTFail("expected title")
        }
        XCTAssertFalse(title.revealFraction.keyframes.isEmpty)
    }

    // MARK: Helpers

    private func makeModelWithSampleTitleSelected() throws -> EditorAjarAppModel {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        // Sample title occupies frames [0, 60) on V2.
        model.scrub(to: 0)
        let sequence = try XCTUnwrap(model.activeSequence)
        let titleTrack = try XCTUnwrap(sequence.videoTracks.dropFirst().first)
        let titleClip = try firstTitleClip(in: titleTrack)
        model.selectClip(trackID: titleTrack.id, clipID: titleClip.id, mode: .replace)
        model.selectedClipInspectorTab = .title
        if let boxID = model.selectedTitleInspector?.title.boxes.first?.id {
            model.selectedCanvasTitleBoxReference = CanvasTitleBoxReference(
                sequenceID: sequence.id,
                trackID: titleTrack.id,
                clipID: titleClip.id,
                boxID: boxID
            )
        }
        XCTAssertNotNil(model.selectedTitleInspector)
        return model
    }

    private func firstTitleClip(in track: Track) throws -> Clip {
        for item in track.items {
            if case .clip(let clip) = item, case .title = clip.source {
                return clip
            }
        }
        struct MissingTitle: Error {}
        throw MissingTitle()
    }

    private func titleClipCount(in sequence: Sequence) -> Int {
        sequence.videoTracks.reduce(0) { count, track in
            count
                + track.items.reduce(0) { inner, item in
                    guard case .clip(let clip) = item, case .title = clip.source else {
                        return inner
                    }
                    return inner + 1
                }
        }
    }
}
