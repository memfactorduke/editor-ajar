// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

// MARK: - FR-TXT-001 / 002 / 004 title insert, style inspector, animation presets

extension EditorAjarAppModel {
    // MARK: Inspector state

    /// Snapshot when a single title generator clip is selected.
    var selectedTitleInspector: SelectedTitleInspectorState? {
        guard let sequence = activeSequence,
              let selectedClipReference,
              let selectedClip,
              case .title(let title) = selectedClip.source
        else {
            return nil
        }

        let selectedBoxID: UUID?
        if let selectedCanvasTitleBoxReference,
           selectedCanvasTitleBoxReference.sequenceID == sequence.id,
           selectedCanvasTitleBoxReference.trackID == selectedClipReference.trackID,
           selectedCanvasTitleBoxReference.clipID == selectedClipReference.clipID,
           title.boxes.contains(where: { $0.id == selectedCanvasTitleBoxReference.boxID })
        {
            selectedBoxID = selectedCanvasTitleBoxReference.boxID
        } else if let fallbackID = title.boxes.first?.id {
            // Post-undo / stale canvas ref: fall back and write back so canvas + inspector agree.
            selectedBoxID = fallbackID
            let resolved = CanvasTitleBoxReference(
                sequenceID: sequence.id,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                boxID: fallbackID
            )
            if selectedCanvasTitleBoxReference != resolved {
                selectedCanvasTitleBoxReference = resolved
            }
        } else {
            selectedBoxID = nil
        }

        let selectedBox = selectedBoxID.flatMap { id in
            title.boxes.first { $0.id == id }
        }

        return SelectedTitleInspectorState(
            clipName: selectedClip.name,
            sequenceID: sequence.id,
            trackID: selectedClipReference.trackID,
            clipID: selectedClipReference.clipID,
            title: title,
            selectedBoxID: selectedBoxID,
            selectedBox: selectedBox,
            clipDuration: selectedClip.timelineRange.duration
        )
    }

    var canInsertTitle: Bool {
        isProjectEditable && activeSequence != nil
    }

    // MARK: Insert title (FR-TXT-001)

    /// Inserts a default title clip at the playhead on the topmost unlocked video track.
    ///
    /// Titles overlay the storyline: the chosen track is used only when it has a free range
    /// covering `[playhead, playhead+duration)`. If that range is occupied (e.g. playhead is
    /// inside an existing clip), a new video track is created above and the title lands there —
    /// never rippling into / overlapping an existing clip. Track creation + insert is one undo
    /// step (`EditCommand.transaction` via ``applyEditGroup`` — #240). Remaining failures surface
    /// a typed, localized refusal (no raw `validationFailed(...)` dumps).
    @discardableResult
    func insertTitleAtPlayhead() -> Bool {
        guard isProjectEditable,
              let project,
              let sequence = activeSequence
        else {
            return false
        }

        let start =
            (try? RationalTime.atFrame(playheadFrame, frameRate: sequence.timebase)) ?? .zero
        guard let duration = try? TitleInsertDefaults.duration(),
              let timelineRange = try? TimeRange(start: start, duration: duration)
        else {
            refuseTitleInsert()
            return false
        }

        let canvas = project.settings.resolution
        let title = TitleInsertDefaults.defaultTitleSource(canvas: canvas)
        let clipID = UUID()
        let name = TitleInsertDefaults.clipName

        // Prefer topmost unlocked track only when free for the full insert range.
        if let track = sequence.videoTracks.last(where: { !$0.locked }),
           trackHasFreeRange(track, covering: timelineRange)
        {
            let applied = applyEdit(
                .insertTitleClip(
                    sequenceID: sequence.id,
                    trackID: track.id,
                    clipID: clipID,
                    title: title,
                    timelineRange: timelineRange,
                    name: name
                )
            )
            if applied {
                selectInsertedTitle(
                    sequenceID: sequence.id,
                    trackID: track.id,
                    clipID: clipID,
                    boxID: title.boxes.first?.id
                )
                return true
            }
            refuseTitleInsert()
            return false
        }

        // Occupied (or no unlocked track): create a track above and overlay the title there.
        let trackID = UUID()
        let track = Track(id: trackID, kind: .video, items: [])
        let applied = applyEditGroup([
            .addTrack(sequenceID: sequence.id, track: track),
            .insertTitleClip(
                sequenceID: sequence.id,
                trackID: trackID,
                clipID: clipID,
                title: title,
                timelineRange: timelineRange,
                name: name
            ),
        ])
        if applied {
            selectInsertedTitle(
                sequenceID: sequence.id,
                trackID: trackID,
                clipID: clipID,
                boxID: title.boxes.first?.id
            )
            return true
        }
        refuseTitleInsert()
        return false
    }

    // MARK: Box selection / multi-box (sync with canvas)

    @discardableResult
    func selectTitleInspectorBox(id boxID: UUID) -> Bool {
        guard let state = selectedTitleInspector,
              state.title.boxes.contains(where: { $0.id == boxID })
        else {
            return false
        }
        endCanvasTitleTextEditing()
        titleStyleCoalesceActive = false
        selectedCanvasTitleBoxReference = CanvasTitleBoxReference(
            sequenceID: state.sequenceID,
            trackID: state.trackID,
            clipID: state.clipID,
            boxID: boxID
        )
        return true
    }

    @discardableResult
    func addTitleTextBox() -> Bool {
        guard let state = selectedTitleInspector,
              let project,
              isProjectEditable
        else {
            return false
        }
        titleStyleCoalesceActive = false
        let canvas = project.settings.resolution
        let box = TitleInsertDefaults.defaultBox(
            canvas: canvas,
            text: TitleInsertDefaults.text
        )
        let applied = applyEdit(
            .setTitleTextBox(
                sequenceID: state.sequenceID,
                trackID: state.trackID,
                clipID: state.clipID,
                box: box
            )
        )
        if applied {
            selectedCanvasTitleBoxReference = CanvasTitleBoxReference(
                sequenceID: state.sequenceID,
                trackID: state.trackID,
                clipID: state.clipID,
                boxID: box.id
            )
        }
        return applied
    }

    @discardableResult
    func removeSelectedTitleTextBox() -> Bool {
        guard let state = selectedTitleInspector,
              let boxID = state.selectedBoxID,
              isProjectEditable
        else {
            return false
        }
        titleStyleCoalesceActive = false
        let applied = applyEdit(
            .removeTitleTextBox(
                sequenceID: state.sequenceID,
                trackID: state.trackID,
                clipID: state.clipID,
                boxID: boxID
            )
        )
        if applied {
            if selectedCanvasTitleBoxReference?.boxID == boxID {
                selectedCanvasTitleBoxReference = nil
            }
            if let next = selectedTitleInspector?.title.boxes.first {
                selectedCanvasTitleBoxReference = CanvasTitleBoxReference(
                    sequenceID: state.sequenceID,
                    trackID: state.trackID,
                    clipID: state.clipID,
                    boxID: next.id
                )
            }
        }
        return applied
    }

    // MARK: Style mutation (FR-TXT-001/002)

    /// Ends a continuous title-style slider gesture so the next gesture opens a new undo step.
    func endTitleStyleSliderGesture() {
        titleStyleCoalesceActive = false
    }

    @discardableResult
    func setSelectedTitleFontFamily(_ fontFamily: String, coalesce: Bool = false) -> Bool {
        let trimmed = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let box = selectedTitleInspector?.selectedBox else {
            return false
        }
        let next = CanvasTitleBoxEditor.copying(
            box,
            style: TitleStyleEditor.copying(box.style, fontFamily: trimmed)
        )
        return updateSelectedTitleBox(next, coalesce: coalesce)
    }

    @discardableResult
    func setSelectedTitleFontWeight(_ weight: TitleFontWeight) -> Bool {
        guard let box = selectedTitleInspector?.selectedBox else {
            return false
        }
        let next = CanvasTitleBoxEditor.copying(
            box,
            style: TitleStyleEditor.copying(box.style, fontWeight: weight)
        )
        return updateSelectedTitleBox(next, coalesce: false)
    }

    @discardableResult
    func setSelectedTitleAlignment(_ alignment: TitleTextAlignment) -> Bool {
        guard let box = selectedTitleInspector?.selectedBox else {
            return false
        }
        let next = CanvasTitleBoxEditor.copying(
            box,
            style: TitleStyleEditor.copying(box.style, alignment: alignment)
        )
        return updateSelectedTitleBox(next, coalesce: false)
    }

    @discardableResult
    func setSelectedTitleScalar(
        _ field: TitleStyleScalarField,
        doubleValue: Double,
        coalesce: Bool = true
    ) -> Bool {
        guard let box = selectedTitleInspector?.selectedBox else {
            return false
        }
        let clamped = ColorFieldValueMapper.clamped(doubleValue, to: field.range)
        let value = RationalValue.approximating(clamped)
        let next = TitleStyleEditor.applying(field, value: value, to: box)
        return updateSelectedTitleBox(next, coalesce: coalesce)
    }

    @discardableResult
    func setSelectedTitleColorChannel(
        target: TitleColorTarget,
        component: ColorInspectorChannelComponent,
        doubleValue: Double,
        coalesce: Bool = true
    ) -> Bool {
        guard let box = selectedTitleInspector?.selectedBox else {
            return false
        }
        let clamped = ColorFieldValueMapper.clamped(doubleValue, to: 0...1)
        let value = RationalValue.approximating(clamped)
        let next = TitleStyleEditor.applying(
            colorTarget: target,
            component: component,
            value: value,
            to: box
        )
        return updateSelectedTitleBox(next, coalesce: coalesce)
    }

    @discardableResult
    func setSelectedTitleStrokeEnabled(_ enabled: Bool) -> Bool {
        guard let box = selectedTitleInspector?.selectedBox else {
            return false
        }
        let stroke: TitleStrokeStyle? = enabled ? (box.style.stroke ?? TitleStrokeStyle()) : nil
        let next = CanvasTitleBoxEditor.copying(
            box,
            style: TitleStyleEditor.copying(box.style, stroke: .some(stroke))
        )
        return updateSelectedTitleBox(next, coalesce: false)
    }

    @discardableResult
    func setSelectedTitleStrokeJoin(_ join: TitleStrokeJoin) -> Bool {
        guard let box = selectedTitleInspector?.selectedBox else {
            return false
        }
        let stroke = box.style.stroke ?? TitleStrokeStyle()
        let next = CanvasTitleBoxEditor.copying(
            box,
            style: TitleStyleEditor.copying(
                box.style,
                stroke: .some(TitleStyleEditor.copying(stroke, join: join))
            )
        )
        return updateSelectedTitleBox(next, coalesce: false)
    }

    @discardableResult
    func setSelectedTitleDropShadowEnabled(_ enabled: Bool) -> Bool {
        guard let box = selectedTitleInspector?.selectedBox else {
            return false
        }
        let shadow: TitleDropShadowStyle? =
            enabled ? (box.style.dropShadow ?? TitleDropShadowStyle()) : nil
        let next = CanvasTitleBoxEditor.copying(
            box,
            style: TitleStyleEditor.copying(box.style, dropShadow: .some(shadow))
        )
        return updateSelectedTitleBox(next, coalesce: false)
    }

    @discardableResult
    func setSelectedTitleBackgroundEnabled(_ enabled: Bool) -> Bool {
        guard let box = selectedTitleInspector?.selectedBox else {
            return false
        }
        let background: TitleBackgroundBoxStyle? =
            enabled ? (box.backgroundBox ?? TitleBackgroundBoxStyle()) : nil
        let next = CanvasTitleBoxEditor.copying(box, backgroundBox: .some(background))
        return updateSelectedTitleBox(next, coalesce: false)
    }

    @discardableResult
    func setSelectedTitleGradientEnabled(_ enabled: Bool) -> Bool {
        guard let box = selectedTitleInspector?.selectedBox else {
            return false
        }
        let gradient: TitleLinearGradientFill? =
            enabled ? (box.style.gradientFill ?? TitleLinearGradientFill()) : nil
        let next = CanvasTitleBoxEditor.copying(
            box,
            style: TitleStyleEditor.copying(box.style, gradientFill: .some(gradient))
        )
        return updateSelectedTitleBox(next, coalesce: false)
    }

    // MARK: Animation presets (FR-TXT-004)

    /// Applies a built-in animation preset to the selected title clip (one undoable edit).
    @discardableResult
    func applyTitleAnimationPresetToSelection(
        kind: TitleAnimationPresetKind,
        direction: TitleAnimationDirection? = nil,
        durationFraction: Double = 0.25
    ) -> Bool {
        guard let state = selectedTitleInspector, isProjectEditable else {
            return false
        }
        titleStyleCoalesceActive = false

        let clipSeconds = max(state.clipDuration.seconds, 0.001)
        let requested = max(0.05, min(clipSeconds, clipSeconds * durationFraction))
        let duration: RationalTime
        if let approximated = try? RationalTime(
            value: Int64((requested * 1_000).rounded()),
            timescale: 1_000
        ),
            approximated > .zero,
            approximated <= state.clipDuration
        {
            duration = approximated
        } else {
            // Fallback: one frame or full clip if shorter.
            guard let sequence = activeSequence,
                  let frame = try? sequence.timebase.duration(ofFrames: 1)
            else {
                return false
            }
            duration = Swift.min(frame, state.clipDuration)
        }

        let preset = TitleAnimationPreset(
            kind: kind,
            duration: duration,
            direction: direction
        )
        return applyEdit(
            .applyTitleAnimationPreset(
                sequenceID: state.sequenceID,
                trackID: state.trackID,
                clipID: state.clipID,
                preset: preset
            )
        )
    }

    // MARK: Private helpers

    private func updateSelectedTitleBox(_ box: TitleTextBox, coalesce: Bool) -> Bool {
        guard let state = selectedTitleInspector, isProjectEditable else {
            return false
        }
        let shouldCoalesce =
            coalesce && titleStyleCoalesceActive
            && editHistory?.nextUndoCommand.map { command in
                if case .setTitleTextBox(
                    let sequenceID,
                    let trackID,
                    let clipID,
                    let previousBox
                ) = command {
                    return sequenceID == state.sequenceID
                        && trackID == state.trackID
                        && clipID == state.clipID
                        && previousBox.id == box.id
                }
                return false
            } == true
        // Continuous gestures arm coalesce; discrete toggles/pickers must not.
        titleStyleCoalesceActive = coalesce
        let applied = applyEdit(
            .setTitleTextBox(
                sequenceID: state.sequenceID,
                trackID: state.trackID,
                clipID: state.clipID,
                box: box
            ),
            coalescingWithPrevious: shouldCoalesce
        )
        if applied {
            selectedCanvasTitleBoxReference = CanvasTitleBoxReference(
                sequenceID: state.sequenceID,
                trackID: state.trackID,
                clipID: state.clipID,
                boxID: box.id
            )
        }
        return applied
    }

    /// True when no timeline item on `track` intersects `range` (half-open free gap).
    private func trackHasFreeRange(_ track: Track, covering range: TimeRange) -> Bool {
        for item in track.items {
            if (try? item.timelineRange.intersects(range)) == true {
                return false
            }
        }
        return true
    }

    private func selectInsertedTitle(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        boxID: UUID?
    ) {
        selectClip(trackID: trackID, clipID: clipID, mode: .replace)
        selectedClipInspectorTab = .title
        if let boxID {
            selectedCanvasTitleBoxReference = CanvasTitleBoxReference(
                sequenceID: sequenceID,
                trackID: trackID,
                clipID: clipID,
                boxID: boxID
            )
        }
    }

    /// Typed, localized refusal — never surface raw `validationFailed(...)` engine dumps.
    private func refuseTitleInsert() {
        surfaceLocalizedEditRefusal(
            "title.insert.failed",
            "Could not insert a title at the playhead."
        )
    }
}
