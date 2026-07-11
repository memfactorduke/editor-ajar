// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal
import UniformTypeIdentifiers

// MARK: - FR-COL-001 / 003 / 004 / 007 app wiring

extension EditorAjarAppModel {
    // MARK: Inspector state

    var selectedColorInspector: SelectedColorInspectorState? {
        guard let selectedClip,
              selectedClip.kind == .video
        else {
            return nil
        }
        // Static base snapshot: color keyframe edit commands do not exist yet (v1 static grade).
        let correction = selectedClip.effects.colorCorrection
        let lutNode = selectedClip.effectStack.nodes.first { node in
            if case .lut = node.definition { return true }
            return false
        }
        let lutParameters: ClipLUTEffectParameters?
        if case .lut(let parameters) = lutNode?.definition {
            lutParameters = parameters
        } else {
            lutParameters = nil
        }
        return SelectedColorInspectorState(
            clipName: selectedClip.name,
            correction: correction,
            lutNodeID: lutNode?.id,
            lutStrength: lutParameters?.strength ?? .one,
            lutTitle: lutParameters?.table.title,
            hasLUT: lutNode != nil
        )
    }

    var canImportLUT: Bool {
        isProjectEditable && selectedClip?.kind == .video
    }

    var canConfirmSaveLook: Bool {
        guard canSaveLook else { return false }
        let trimmed = saveLookDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    var lutImportStatusMessage: String? {
        guard let lutImportError else { return nil }
        return AppString.lutImportFailureMessage(for: lutImportError)
    }

    var scopeStatusMessage: String {
        if let scopeAnalysisErrorMessage {
            return scopeAnalysisErrorMessage
        }
        if presentedTexture == nil {
            return AppString.localized("scopes.status.waiting", "Waiting for program frame…")
        }
        return AppString.localized("scopes.status.ready", "Scope ready")
    }

    // MARK: Color correction

    @discardableResult
    func setSelectedColorScalar(
        _ field: ColorInspectorScalarField,
        doubleValue: Double,
        coalesce: Bool = true
    ) -> Bool {
        guard let current = selectedColorInspector?.correction else {
            return false
        }
        let clamped = ColorFieldValueMapper.clamped(doubleValue, to: field.range)
        let value = RationalValue.approximating(clamped)
        let next = ColorCorrectionEditor.setting(field, to: value, in: current)
        return updateSelectedClipColorCorrection(next, coalesce: coalesce)
    }

    @discardableResult
    func setSelectedColorChannel(
        group: ColorInspectorChannelGroup,
        component: ColorInspectorChannelComponent,
        doubleValue: Double,
        coalesce: Bool = true
    ) -> Bool {
        guard let current = selectedColorInspector?.correction else {
            return false
        }
        let clamped = ColorFieldValueMapper.clamped(doubleValue, to: group.range)
        let value = RationalValue.approximating(clamped)
        let next = ColorCorrectionEditor.setting(
            group: group,
            component: component,
            to: value,
            in: current
        )
        return updateSelectedClipColorCorrection(next, coalesce: coalesce)
    }

    @discardableResult
    func resetSelectedColorScalar(_ field: ColorInspectorScalarField) -> Bool {
        guard let current = selectedColorInspector?.correction else {
            return false
        }
        return updateSelectedClipColorCorrection(
            ColorCorrectionEditor.resetting(field, in: current),
            coalesce: false
        )
    }

    @discardableResult
    func resetSelectedColorChannelGroup(_ group: ColorInspectorChannelGroup) -> Bool {
        guard let current = selectedColorInspector?.correction else {
            return false
        }
        return updateSelectedClipColorCorrection(
            ColorCorrectionEditor.resetting(group, in: current),
            coalesce: false
        )
    }

    @discardableResult
    func resetSelectedClipColorCorrection() -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              selectedClip?.kind == .video
        else {
            return false
        }
        colorCorrectionCoalesceActive = false
        return applyEdit(
            .clearClipColorCorrection(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID
            )
        )
    }

    /// Ends a continuous color-slider drag so the next gesture opens a new undo step.
    ///
    /// Called from `Slider` `onEditingChanged` when editing becomes `false`. Discrete
    /// reset paths never set ``colorCorrectionCoalesceActive``, so a Reset cannot absorb
    /// the following drag.
    func endColorCorrectionSliderGesture() {
        colorCorrectionCoalesceActive = false
    }

    // MARK: LUT import / strength (FR-COL-004)

    func presentLUTImporter() {
        guard canImportLUT else { return }
        lutImportError = nil
        isLUTImporterPresented = true
    }

    func dismissLUTImporter() {
        isLUTImporterPresented = false
    }

    func handleLUTImporterResult(_ result: Result<[URL], Error>) {
        isLUTImporterPresented = false
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                // Empty selection is a no-op (same posture as media relink).
                return
            }
            _ = importAndApplyLUT(from: url)
        case .failure:
            lutImportError = .sourceUnavailable
        }
    }

    /// Parses a `.cube` file and applies it as an inline LUT node on the selected video clip.
    ///
    /// ADR-0007 package layout has no `luts/` directory. Tables are stored **inline** on the
    /// effect node (`ClipLUTEffectParameters.table`) per existing FR-COL-004 engine design —
    /// no `schemaMinor` bump. Missing/unreadable source is typed and non-blocking.
    @discardableResult
    func importAndApplyLUT(from url: URL) -> Bool {
        guard project != nil else {
            lutImportError = .noProject
            return false
        }
        guard isProjectEditable else {
            lutImportError = .projectReadOnly
            return false
        }
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              selectedClip?.kind == .video
        else {
            lutImportError = .noVideoClipSelected
            return false
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            lutImportError = .sourceUnavailable
            return false
        }

        let parseResult = CubeLUTParser.parse(data: data)
        let table: CubeLUTTable
        switch parseResult {
        case .success(let parsed):
            table = parsed
        case .failure(let error):
            lutImportError = .parseFailed(error.message)
            return false
        }

        let parameters = ClipLUTEffectParameters(table: table, strength: .one, placement: .look)
        let definition = ClipEffectDefinition.lut(parameters)

        // One undo step: replace parameters on an existing LUT node, otherwise append a new node.
        let applied: Bool
        if let existingID = selectedColorInspector?.lutNodeID {
            applied = applyEdit(
                .setClipEffectNodeParameters(
                    sequenceID: sequenceID,
                    trackID: selectedClipReference.trackID,
                    clipID: selectedClipReference.clipID,
                    nodeID: existingID,
                    definition: definition
                )
            )
        } else {
            let node = ClipEffectNode(id: UUID(), definition: definition)
            applied = applyEdit(
                .addClipEffectNode(
                    sequenceID: sequenceID,
                    trackID: selectedClipReference.trackID,
                    clipID: selectedClipReference.clipID,
                    node: node,
                    destinationIndex: nil
                )
            )
        }
        if applied {
            lutImportError = nil
            lutStrengthCoalesceActive = false
        } else {
            lutImportError = .applyFailed("Could not apply LUT to clip")
        }
        return applied
    }

    @discardableResult
    func setSelectedLUTStrength(doubleValue: Double, coalesce: Bool = true) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              let state = selectedColorInspector,
              let nodeID = state.lutNodeID,
              let selectedClip,
              let node = selectedClip.effectStack.nodes.first(where: { $0.id == nodeID }),
              case .lut(let parameters) = node.definition
        else {
            return false
        }
        let clamped = ColorFieldValueMapper.clamped(doubleValue, to: 0...1)
        let strength = RationalValue.approximating(clamped)
        let definition = ClipEffectDefinition.lut(
            ClipLUTEffectParameters(
                table: parameters.table,
                strength: strength,
                placement: parameters.placement
            )
        )
        let shouldCoalesce =
            coalesce && lutStrengthCoalesceActive
            && editHistory?.nextUndoCommand.map { command in
                if case .setClipEffectNodeParameters(_, _, _, let undoNodeID, _) = command {
                    return undoNodeID == nodeID
                }
                return false
            } == true
        lutStrengthCoalesceActive = true
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
    func removeSelectedClipLUT() -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              let nodeID = selectedColorInspector?.lutNodeID
        else {
            return false
        }
        lutStrengthCoalesceActive = false
        return applyEdit(
            .removeClipEffectNode(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                nodeID: nodeID
            )
        )
    }

    // MARK: Looks naming sheet (FR-COL-007)

    func presentSaveLookSheet() {
        guard canSaveLook, let project else { return }
        saveLookDraftName = Self.nextLookName(in: project)
        isSaveLookSheetPresented = true
    }

    func dismissSaveLookSheet() {
        isSaveLookSheetPresented = false
    }

    func updateSaveLookDraftName(_ name: String) {
        saveLookDraftName = name
    }

    @discardableResult
    func confirmSaveLookFromSelectedClip() -> Bool {
        guard canConfirmSaveLook,
              let source = selectedProjectClipReference
        else {
            return false
        }
        let name = saveLookDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = applyEdit(
            .saveLookFromClip(
                source: source,
                lookID: UUID(),
                name: name
            )
        )
        if saved {
            isSaveLookSheetPresented = false
        }
        return saved
    }

    @discardableResult
    func deleteLook(lookID: UUID) -> Bool {
        guard isProjectEditable else { return false }
        return applyEdit(.deleteLook(lookID: lookID))
    }

    // MARK: Scopes panel (FR-COL-003)

    func toggleScopesPanel() {
        isScopesPanelVisible.toggle()
        if isScopesPanelVisible {
            requestScopeAnalysisIfNeeded(forceTextureChange: true)
        } else {
            clearScopeAnalysisState()
        }
    }

    func selectScopeKind(_ kind: ScopeDisplayKind) {
        selectedScopeKind = kind
        refreshScopeDisplayTextureFromRetainedFrame()
    }

    /// Called when a new program frame is presented. Never blocks the render path.
    func notePresentedTextureForScopes() {
        guard isScopesPanelVisible else { return }
        requestScopeAnalysisIfNeeded(forceTextureChange: true)
    }

    func requestScopeAnalysisIfNeeded(forceTextureChange: Bool = false) {
        guard isScopesPanelVisible else { return }
        guard let texture = presentedTexture else {
            clearScopeAnalysisState()
            return
        }

        let textureID = ObjectIdentifier(texture)
        let identityChanged = forceTextureChange || lastScopeTextureIdentity != textureID
        let now = ProcessInfo.processInfo.systemUptime
        let allowed = ScopeAnalysisThrottle.shouldAnalyze(
            isPlaying: isPlaying,
            textureIdentityChanged: identityChanged,
            lastAnalysisTime: lastScopeAnalysisTime,
            now: now
        )
        guard allowed else { return }

        // Record request time for throttle tests even if Metal setup fails.
        lastScopeAnalysisTime = now
        lastScopeTextureIdentity = textureID
        scopeAnalysisRequestCount += 1

        do {
            let analyzer = try scopeAnalyzerInstance()
            let frame = try analyzer.analyze(displayEncodedTexture: texture)
            retainedScopeFrame = frame
            scopeAnalysisErrorMessage = nil
            refreshScopeDisplayTextureFromRetainedFrame()
        } catch {
            scopeAnalysisErrorMessage = AppString.localized(
                "scopes.error.analyze",
                "Scope analysis unavailable: \(String(describing: error))"
            )
            retainedScopeFrame = nil
            scopeDisplayTexture = nil
        }
    }

    /// Test seam: records whether analysis would be requested under the throttle policy.
    func wouldRequestScopeAnalysis(
        isPlaying: Bool,
        textureIdentityChanged: Bool,
        lastAnalysisTime: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        ScopeAnalysisThrottle.shouldAnalyze(
            isPlaying: isPlaying,
            textureIdentityChanged: textureIdentityChanged,
            lastAnalysisTime: lastAnalysisTime,
            now: now
        )
    }

    // MARK: Private helpers

    private func updateSelectedClipColorCorrection(
        _ correction: ClipColorCorrection,
        coalesce: Bool
    ) -> Bool {
        guard let sequenceID = activeSequence?.id,
              let selectedClipReference,
              selectedClip?.kind == .video
        else {
            return false
        }
        let shouldCoalesce =
            coalesce && colorCorrectionCoalesceActive
            && editHistory?.nextUndoCommand.map { command in
                if case .setClipColorCorrection = command { return true }
                return false
            } == true
        // Continuous slider drags arm coalesce; discrete resets must not — otherwise a Reset
        // leaves the flag set and the next drag merges into the Reset undo step.
        colorCorrectionCoalesceActive = coalesce
        return applyEdit(
            .setClipColorCorrection(
                sequenceID: sequenceID,
                trackID: selectedClipReference.trackID,
                clipID: selectedClipReference.clipID,
                correction: correction
            ),
            coalescingWithPrevious: shouldCoalesce
        )
    }

    private func scopeAnalyzerInstance() throws -> MetalScopeAnalyzer {
        if let scopeAnalyzer {
            return scopeAnalyzer
        }
        let analyzer = try MetalScopeAnalyzer()
        scopeAnalyzer = analyzer
        return analyzer
    }

    private func refreshScopeDisplayTextureFromRetainedFrame() {
        guard let frame = retainedScopeFrame else {
            scopeDisplayTexture = nil
            return
        }
        switch selectedScopeKind {
        case .waveform:
            scopeDisplayTexture = frame.waveformTexture
        case .vectorscope:
            scopeDisplayTexture = frame.vectorscopeTexture
        case .parade:
            scopeDisplayTexture = frame.rgbParadeTexture
        case .histogram:
            scopeDisplayTexture = frame.histogramTexture
        }
    }

    private func clearScopeAnalysisState() {
        retainedScopeFrame = nil
        scopeDisplayTexture = nil
        lastScopeTextureIdentity = nil
        scopeAnalysisErrorMessage = nil
    }
}

extension AppString {
    static func lutImportFailureMessage(for error: EditorAjarLUTImportError) -> String {
        switch error {
        case .noProject:
            return localized("color.lut.error.noProject", "Open a project before importing a LUT.")
        case .projectReadOnly:
            return localized(
                "color.lut.error.readOnly",
                "This project is read-only; LUT import is disabled."
            )
        case .noVideoClipSelected:
            return localized(
                "color.lut.error.noClip",
                "Select a single video clip to apply a LUT."
            )
        case .sourceUnavailable:
            return localized(
                "color.lut.error.missing",
                "The LUT file is missing or cannot be read."
            )
        case .parseFailed(let message):
            return localized(
                "color.lut.error.parse",
                "The .cube LUT could not be parsed: \(message)"
            )
        case .applyFailed(let message):
            return localized("color.lut.error.apply", "LUT could not be applied: \(message)")
        }
    }
}

extension UTType {
    /// `.cube` LUT files (FR-COL-004). Not a system UTI; filename extension based.
    static var cubeLUT: UTType {
        UTType(filenameExtension: "cube") ?? .data
    }
}
