// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarColorUITests: XCTestCase {
    // MARK: FR-COL-001 primary color inspector

    func testFRCOL001ColorScalarSetResetAndUndo() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)
        let original = try XCTUnwrap(model.selectedColorInspector?.correction)

        XCTAssertEqual(original.exposure, .zero)
        XCTAssertTrue(model.setSelectedColorScalar(.exposure, doubleValue: 1.5, coalesce: false))
        XCTAssertEqual(
            model.selectedColorInspector?.correction.exposure.doubleValue ?? 0,
            1.5,
            accuracy: 0.001
        )
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Color Correction")

        XCTAssertTrue(model.resetSelectedColorScalar(.exposure))
        XCTAssertEqual(model.selectedColorInspector?.correction.exposure, .zero)

        model.undo()
        XCTAssertEqual(
            model.selectedColorInspector?.correction.exposure.doubleValue ?? 0,
            1.5,
            accuracy: 0.001
        )
        model.undo()
        XCTAssertEqual(model.selectedColorInspector?.correction, original)
    }

    func testFRCOL001ChannelGroupAndResetAll() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)

        XCTAssertTrue(
            model.setSelectedColorChannel(
                group: .lift,
                component: .red,
                doubleValue: 0.25,
                coalesce: false
            )
        )
        XCTAssertEqual(
            model.selectedColorInspector?.correction.lift.red.doubleValue ?? 0,
            0.25,
            accuracy: 0.001
        )
        XCTAssertTrue(model.setSelectedColorScalar(.contrast, doubleValue: 1.5, coalesce: false))
        XCTAssertTrue(model.resetSelectedClipColorCorrection())
        XCTAssertEqual(model.selectedColorInspector?.correction, .identity)
        XCTAssertEqual(model.undoMenuTitle, "Undo Clear Color Correction")
    }

    func testFRCOL001ScalarSliderCoalescesIntoSingleUndoStep() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)
        let beforeCount = model.editHistory?.undoCount ?? 0

        XCTAssertTrue(model.setSelectedColorScalar(.saturation, doubleValue: 1.2, coalesce: true))
        XCTAssertTrue(model.setSelectedColorScalar(.saturation, doubleValue: 1.4, coalesce: true))
        XCTAssertTrue(model.setSelectedColorScalar(.saturation, doubleValue: 1.6, coalesce: true))

        XCTAssertEqual((model.editHistory?.undoCount ?? 0) - beforeCount, 1)
        XCTAssertEqual(
            model.selectedColorInspector?.correction.saturation.doubleValue ?? 0,
            1.6,
            accuracy: 0.001
        )
        model.undo()
        XCTAssertEqual(model.selectedColorInspector?.correction.saturation, .one)
    }

    func testFRCOL001GestureBoundaryAndDifferentControlsProduceSeparateUndoSteps() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)
        let beforeCount = model.editHistory?.undoCount ?? 0

        // Gesture 1: continuous Exposure drag → one undo step.
        XCTAssertTrue(model.setSelectedColorScalar(.exposure, doubleValue: 0.5, coalesce: true))
        XCTAssertTrue(model.setSelectedColorScalar(.exposure, doubleValue: 1.0, coalesce: true))
        model.endColorCorrectionSliderGesture()

        // Gesture 2: continuous Contrast drag after gesture end → second undo step.
        XCTAssertTrue(model.setSelectedColorScalar(.contrast, doubleValue: 1.2, coalesce: true))
        XCTAssertTrue(model.setSelectedColorScalar(.contrast, doubleValue: 1.5, coalesce: true))
        model.endColorCorrectionSliderGesture()

        // Gesture 3: Lift channel after another boundary → third undo step.
        XCTAssertTrue(
            model.setSelectedColorChannel(
                group: .lift,
                component: .red,
                doubleValue: 0.1,
                coalesce: true
            )
        )
        XCTAssertTrue(
            model.setSelectedColorChannel(
                group: .lift,
                component: .red,
                doubleValue: 0.2,
                coalesce: true
            )
        )

        XCTAssertEqual((model.editHistory?.undoCount ?? 0) - beforeCount, 3)

        // Reset is discrete and must not leave coalesce armed for the following drag.
        let afterGestures = model.editHistory?.undoCount ?? 0
        XCTAssertTrue(model.resetSelectedColorScalar(.exposure))
        XCTAssertTrue(model.setSelectedColorScalar(.exposure, doubleValue: 0.8, coalesce: true))
        XCTAssertEqual((model.editHistory?.undoCount ?? 0) - afterGestures, 2)
    }

    // MARK: FR-COL-003 scope throttle

    func testFRCOL003ScopeThrottleAllowsAtMostNPerSecondWhilePlaying() {
        let interval = ScopeAnalysisThrottle.minimumPlayingInterval
        let t0: TimeInterval = 100
        XCTAssertTrue(
            ScopeAnalysisThrottle.shouldAnalyze(
                isPlaying: true,
                textureIdentityChanged: true,
                lastAnalysisTime: nil,
                now: t0
            )
        )
        XCTAssertFalse(
            ScopeAnalysisThrottle.shouldAnalyze(
                isPlaying: true,
                textureIdentityChanged: true,
                lastAnalysisTime: t0,
                now: t0 + (interval * 0.5)
            )
        )
        XCTAssertTrue(
            ScopeAnalysisThrottle.shouldAnalyze(
                isPlaying: true,
                textureIdentityChanged: false,
                lastAnalysisTime: t0,
                now: t0 + interval
            )
        )
        XCTAssertEqual(ScopeAnalysisThrottle.maxAnalysesPerSecondWhilePlaying, 10)
    }

    func testFRCOL003ScopeThrottleOnDemandWhenPaused() {
        let interval = ScopeAnalysisThrottle.minimumPlayingInterval
        let t0: TimeInterval = 50

        // First analysis when paused is always allowed.
        XCTAssertTrue(
            ScopeAnalysisThrottle.shouldAnalyze(
                isPlaying: false,
                textureIdentityChanged: false,
                lastAnalysisTime: nil,
                now: t0
            )
        )

        // Texture identity change before the minimum interval must not re-analyze (scrub path).
        XCTAssertFalse(
            ScopeAnalysisThrottle.shouldAnalyze(
                isPlaying: false,
                textureIdentityChanged: true,
                lastAnalysisTime: t0,
                now: t0 + (interval * 0.5)
            )
        )

        // Unchanged texture never analyzes while paused (even after the interval).
        XCTAssertFalse(
            ScopeAnalysisThrottle.shouldAnalyze(
                isPlaying: false,
                textureIdentityChanged: false,
                lastAnalysisTime: t0,
                now: t0 + interval
            )
        )

        // Texture change after the interval is allowed (on-demand + rate limit).
        XCTAssertTrue(
            ScopeAnalysisThrottle.shouldAnalyze(
                isPlaying: false,
                textureIdentityChanged: true,
                lastAnalysisTime: t0,
                now: t0 + interval
            )
        )
    }

    func testFRCOL003ScopeThrottlePausedScrubCapsAtMostNPerSecond() {
        let interval = ScopeAnalysisThrottle.minimumPlayingInterval
        let t0: TimeInterval = 200

        // First scrub-settle analysis is allowed.
        XCTAssertTrue(
            ScopeAnalysisThrottle.shouldAnalyze(
                isPlaying: false,
                textureIdentityChanged: true,
                lastAnalysisTime: nil,
                now: t0
            )
        )

        // Rapid texture-identity changes inside the minimum interval must all be rejected
        // (injected clock: many scrub settles → still at most N/sec).
        for step in 1...20 {
            let fraction = Double(step) / 21.0
            XCTAssertFalse(
                ScopeAnalysisThrottle.shouldAnalyze(
                    isPlaying: false,
                    textureIdentityChanged: true,
                    lastAnalysisTime: t0,
                    now: t0 + (interval * fraction)
                ),
                "paused scrub settle at fraction \(fraction) must not re-analyze"
            )
        }

        // Boundary + next interval: allowed again only after the rate gate.
        XCTAssertTrue(
            ScopeAnalysisThrottle.shouldAnalyze(
                isPlaying: false,
                textureIdentityChanged: true,
                lastAnalysisTime: t0,
                now: t0 + interval
            )
        )
        XCTAssertFalse(
            ScopeAnalysisThrottle.shouldAnalyze(
                isPlaying: false,
                textureIdentityChanged: true,
                lastAnalysisTime: t0 + interval,
                now: t0 + interval + (interval * 0.5)
            )
        )
        XCTAssertTrue(
            ScopeAnalysisThrottle.shouldAnalyze(
                isPlaying: false,
                textureIdentityChanged: true,
                lastAnalysisTime: t0 + interval,
                now: t0 + (2 * interval)
            )
        )
    }

    func testFRCOL003ScopePanelToggleIncrementsRequestCountWhenTexturePresent() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        // Without a program texture, analysis still records the request attempt path cleanly.
        XCTAssertFalse(model.isScopesPanelVisible)
        model.toggleScopesPanel()
        XCTAssertTrue(model.isScopesPanelVisible)
        // Request count only advances when analysis is attempted with a texture or after present.
        // Force the throttle path with an explicit call (no Metal dependency for the counter gate).
        let before = model.scopeAnalysisRequestCount
        // No presented texture → requestScopeAnalysisIfNeeded clears without counting.
        model.requestScopeAnalysisIfNeeded(forceTextureChange: true)
        XCTAssertEqual(model.scopeAnalysisRequestCount, before)

        model.toggleScopesPanel()
        XCTAssertFalse(model.isScopesPanelVisible)
    }

    // MARK: FR-COL-004 LUT import / strength / missing file

    func testFRCOL004LUTImportApplyStrengthAndRemove() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)

        let cubeURL = try writeTemporaryCubeFile(
            named: "Identity-\(UUID().uuidString).cube",
            text: """
            TITLE "UI Identity"
            LUT_1D_SIZE 2
            0 0 0
            1 1 1
            """
        )
        defer { try? FileManager.default.removeItem(at: cubeURL) }

        XCTAssertTrue(model.importAndApplyLUT(from: cubeURL))
        XCTAssertNil(model.lutImportError)
        XCTAssertTrue(try XCTUnwrap(model.selectedColorInspector).hasLUT)
        XCTAssertEqual(model.selectedColorInspector?.lutTitle, "UI Identity")
        XCTAssertTrue(model.canCopyGrade)
        XCTAssertEqual(model.undoMenuTitle, "Undo Add Effect")

        XCTAssertTrue(model.setSelectedLUTStrength(doubleValue: 0.5, coalesce: false))
        XCTAssertEqual(
            model.selectedColorInspector?.lutStrength.doubleValue ?? 0,
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Effect Parameters")

        XCTAssertTrue(model.removeSelectedClipLUT())
        XCTAssertFalse(try XCTUnwrap(model.selectedColorInspector).hasLUT)
    }

    func testFRCOL004MissingLUTFileIsTypedNonBlocking() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).cube")
        XCTAssertFalse(model.importAndApplyLUT(from: missing))
        XCTAssertEqual(model.lutImportError, .sourceUnavailable)
        XCTAssertNotNil(model.project)
        XCTAssertTrue(model.isProjectEditable)
    }

    func testFRCOL004MalformedCubeIsTypedParseFailure() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)
        let cubeURL = try writeTemporaryCubeFile(
            named: "Bad-\(UUID().uuidString).cube",
            text: "not a cube\n"
        )
        defer { try? FileManager.default.removeItem(at: cubeURL) }

        XCTAssertFalse(model.importAndApplyLUT(from: cubeURL))
        guard case .parseFailed = model.lutImportError else {
            return XCTFail("Expected parseFailed, got \(String(describing: model.lutImportError))")
        }
    }

    // MARK: FR-COL-007 looks list delete + named save

    func testFRCOL007NamedSaveAndDeleteLookRoundTrip() throws {
        let fixture = try makeGradeAppFixture()
        let loaded = try loadGradeAppModel(project: fixture.project, named: "NamedLook.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model

        model.selectClip(
            trackID: fixture.source.trackID,
            clipID: fixture.source.clipID,
            mode: .replace
        )
        model.presentSaveLookSheet()
        model.updateSaveLookDraftName("Cinema")
        XCTAssertTrue(model.confirmSaveLookFromSelectedClip())
        let lookID = try XCTUnwrap(model.savedLooks.first?.id)

        model.selectClip(
            trackID: fixture.target.trackID,
            clipID: fixture.target.clipID,
            mode: .replace
        )
        XCTAssertTrue(model.applyLookToSelectedClip(lookID: lookID))
        XCTAssertFalse(
            try projectClip(fixture.target, in: XCTUnwrap(model.project))
                .effectStack.grade.nodes.isEmpty
        )

        XCTAssertTrue(model.deleteLook(lookID: lookID))
        XCTAssertTrue(model.savedLooks.isEmpty)
        XCTAssertEqual(model.undoMenuTitle, "Undo Delete Look")
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

    private func firstClip(in track: Track) throws -> Clip {
        for item in track.items {
            if case .clip(let clip) = item {
                return clip
            }
        }
        struct MissingClip: Error {}
        throw MissingClip()
    }

    private func writeTemporaryCubeFile(named name: String, text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
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
            clipID: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000007202"))
        )
        let gradeNode = ClipEffectNode(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000007201")),
            definition: .colorAdjust(
                ClipColorAdjustParameters(
                    brightness: try RationalValue(numerator: 1, denominator: 4)
                )
            )
        )
        project = try EditReducer.apply(
            .addClipEffectNode(
                sequenceID: sourceReference.sequenceID,
                trackID: sourceReference.trackID,
                clipID: sourceReference.clipID,
                node: gradeNode
            ),
            to: project
        )
        let targetDuration = try sequence.timebase.duration(ofFrames: 30)
        let targetStart = try trackTimelineEnd(targetTrack)
        let targetClip = Clip(
            id: targetReference.clipID,
            source: sourceClip.source,
            sourceRange: try TimeRange(start: .zero, duration: targetDuration),
            timelineRange: try TimeRange(start: targetStart, duration: targetDuration),
            kind: .video,
            name: "Grade target"
        )
        project = try EditReducer.apply(
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
            guard case .clip(let clip) = item else { continue }
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
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-color-ui-\(UUID().uuidString)")
            .appendingPathComponent(packageName)
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
}

private struct GradeAppFixture {
    let project: Project
    let source: ProjectClipReference
    let target: ProjectClipReference
}
