// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import Foundation
import XCTest

@testable import EditorAjar

/// FR-AUD-001/002/003 app UI wiring tests.
///
/// Uses audio-only project fixtures (no sample movie) so CI/agent sandboxes that cannot create
/// CVPixelBuffers still validate mixer/clip/fade/crossfade command paths.
@MainActor
final class AudioMixUITests: XCTestCase {
    func testFRAUD003MixerTrackGainRoundTripsThroughUndo() throws {
        let fixture = try makeAudioProjectFixture(clipCount: 1)
        let loaded = try loadAudioFixture(project: fixture.project, named: "Gain.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model
        let originalProject = try XCTUnwrap(model.project)

        XCTAssertTrue(
            model.setTrackGainDB(
                sequenceID: fixture.sequenceID,
                trackID: fixture.trackID,
                gainDB: -6,
                gesturePhase: .discrete
            )
        )
        let updated = try XCTUnwrap(
            model.activeSequence?.audioTracks.first(where: { $0.id == fixture.trackID })
        )
        XCTAssertEqual(
            AudioMixUISupport.gainDB(fromLinear: updated.audioGain.base.doubleValue),
            -6,
            accuracy: 0.15
        )
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Track Audio Mix")

        model.undo()
        XCTAssertEqual(model.project, originalProject)
    }

    func testFRAUD003MixerTrackGainGestureCoalescesToOneUndo() throws {
        let fixture = try makeAudioProjectFixture(clipCount: 1)
        let loaded = try loadAudioFixture(project: fixture.project, named: "GainGesture.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model

        XCTAssertTrue(
            model.setTrackGainDB(
                sequenceID: fixture.sequenceID,
                trackID: fixture.trackID,
                gainDB: -3,
                gesturePhase: .began
            )
        )
        XCTAssertTrue(
            model.setTrackGainDB(
                sequenceID: fixture.sequenceID,
                trackID: fixture.trackID,
                gainDB: -6,
                gesturePhase: .changed
            )
        )
        XCTAssertTrue(
            model.setTrackGainDB(
                sequenceID: fixture.sequenceID,
                trackID: fixture.trackID,
                gainDB: -9,
                gesturePhase: .ended
            )
        )

        model.undo()
        let restored = try XCTUnwrap(
            model.activeSequence?.audioTracks.first(where: { $0.id == fixture.trackID })
        )
        XCTAssertEqual(restored.audioGain.base.doubleValue, 1.0, accuracy: 0.001)
    }

    func testFRAUD003MixerTrackPanRoundTripsThroughUndo() throws {
        let fixture = try makeAudioProjectFixture(clipCount: 1)
        let loaded = try loadAudioFixture(project: fixture.project, named: "Pan.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model

        XCTAssertTrue(
            model.setTrackPan(
                sequenceID: fixture.sequenceID,
                trackID: fixture.trackID,
                pan: -0.5,
                gesturePhase: .discrete
            )
        )
        let updated = try XCTUnwrap(
            model.activeSequence?.audioTracks.first(where: { $0.id == fixture.trackID })
        )
        XCTAssertEqual(updated.audioPan.base.doubleValue, -0.5, accuracy: 0.001)

        model.undo()
        let restored = try XCTUnwrap(
            model.activeSequence?.audioTracks.first(where: { $0.id == fixture.trackID })
        )
        XCTAssertEqual(restored.audioPan.base.doubleValue, 0, accuracy: 0.001)
    }

    func testFRAUD003MeterPublisherIsOffRealtimePath() throws {
        let fixture = try makeAudioProjectFixture(clipCount: 1)
        let loaded = try loadAudioFixture(project: fixture.project, named: "MeterPath.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model
        XCTAssertTrue(
            model.mixerMeterPublishesOffRealtimePath,
            "Mixer meters must publish via \(EditorAjarMixerMeterPublisher.analysisQueueLabel), not the RT audio callback"
        )
        XCTAssertEqual(
            EditorAjarMixerMeterPublisher.analysisQueueLabel,
            "org.editorajar.mixer-meter.analysis"
        )
    }

    func testFRAUD003MeterSnapshotUsesOfflineAnalyzer() throws {
        let fixture = try makeAudioProjectFixture(clipCount: 1)
        let loaded = try loadAudioFixture(project: fixture.project, named: "MeterSnap.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model
        let project = try XCTUnwrap(model.project)
        let sequence = try XCTUnwrap(model.activeSequence)
        let range = try TimeRange(
            start: .zero,
            duration: sequence.timebase.duration(ofFrames: 4)
        )
        let provider = try EditorAjarProjectAudioSourceProvider(
            project: project,
            sequence: sequence,
            range: range
        )
        let snapshot = EditorAjarMixerMeterPublisher.measureSnapshot(
            project: project,
            sequence: sequence,
            playheadFrame: 0,
            sourceProvider: provider
        )
        XCTAssertFalse(snapshot.mixLevels.isEmpty)
        XCTAssertNotNil(snapshot.masterTruePeak)
    }

    func testFRAUD003MasterGainScalesMasterMeterClipIndicator() throws {
        let fixture = try makeAudioProjectFixture(clipCount: 1)
        let loaded = try loadAudioFixture(project: fixture.project, named: "MasterMeter.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model
        let project = try XCTUnwrap(model.project)
        let sequence = try XCTUnwrap(model.activeSequence)

        // Hot mono tone at the project sample rate. Amplitude must stay clean at unity master
        // after BS.1770 true-peak oversampling (edge-truncated sinc overshoots ~13% on a step
        // into the analysis window), while gain*2 must push sample peak past 1.0.
        let sampleRate = project.settings.audioSampleRate
        let windowFrames: Int64 = 4
        let samplesPerFrame = max(
            1,
            sampleRate * Int(sequence.timebase.seconds) / Int(sequence.timebase.frames)
        )
        let frameCount = Int(windowFrames) * samplesPerFrame
        let nearFull: Float = 0.7
        let samples = [Float](repeating: nearFull, count: frameCount)
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: sampleRate, channelCount: 1),
            frameCount: frameCount,
            samples: samples
        )
        let provider = InMemoryAudioSourceProvider(sources: [fixture.mediaID: source])

        let unity = EditorAjarMixerMeterPublisher.measureSnapshot(
            project: project,
            sequence: sequence,
            playheadFrame: 0,
            sourceProvider: provider,
            windowFrames: windowFrames,
            masterGainLinear: 1.0
        )
        XCTAssertFalse(
            unity.isMasterClipping,
            "Near-full-scale mix at unity master must not trip the master clip indicator"
        )

        let boosted = EditorAjarMixerMeterPublisher.measureSnapshot(
            project: project,
            sequence: sequence,
            playheadFrame: 0,
            sourceProvider: provider,
            windowFrames: windowFrames,
            masterGainLinear: 2.0
        )
        XCTAssertTrue(
            boosted.isMasterClipping,
            "Master gain > 1 with a near-full-scale mix must light the master clip indicator"
        )
        let peak = try XCTUnwrap(boosted.mixLevels.map(\.peak).max())
        XCTAssertGreaterThanOrEqual(peak, 1.0)
    }

    func testFRAUD003LiveMetersRefreshWhilePlayingWhenPanelVisible() throws {
        let fixture = try makeAudioProjectFixture(clipCount: 1)
        let loaded = try loadAudioFixture(project: fixture.project, named: "LiveMeters.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model

        // Panel hidden + playing: display-link ticks must not request meters.
        XCTAssertFalse(model.isMixerPanelVisible)
        model.shuttleForward()
        XCTAssertTrue(model.isPlaying)
        let hiddenBaseline = model.mixerMeterRequestGenerationForTesting
        for _ in 0..<8 {
            model.simulateDisplayLinkTickForTesting(1.0 / 30.0)
        }
        XCTAssertEqual(
            model.mixerMeterRequestGenerationForTesting,
            hiddenBaseline,
            "Live meters must not schedule analysis while the mixer panel is hidden"
        )
        model.shuttlePause()

        // Panel visible + playing: generation advances (~30 Hz throttle).
        model.toggleMixerPanel()
        XCTAssertTrue(model.isMixerPanelVisible)
        let visibleBaseline = model.mixerMeterRequestGenerationForTesting
        model.shuttleForward()
        for _ in 0..<8 {
            model.simulateDisplayLinkTickForTesting(1.0 / 30.0)
        }
        XCTAssertGreaterThan(
            model.mixerMeterRequestGenerationForTesting,
            visibleBaseline,
            "Playing with the mixer panel open must refresh meters over display-link ticks"
        )
    }

    func testFRAUD003MasterGainIsSessionOnly() throws {
        let fixture = try makeAudioProjectFixture(clipCount: 1)
        let loaded = try loadAudioFixture(project: fixture.project, named: "Master.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model
        let before = try XCTUnwrap(model.project)
        XCTAssertTrue(model.setMasterGainDB(-6, gesturePhase: .discrete))
        XCTAssertEqual(
            AudioMixUISupport.gainDB(fromLinear: model.masterGainLinear),
            -6,
            accuracy: 0.15
        )
        XCTAssertEqual(model.project, before)
    }

    func testFRAUD001ClipGainAndPanUndo() throws {
        let fixture = try makeAudioProjectFixture(clipCount: 1)
        let loaded = try loadAudioFixture(project: fixture.project, named: "ClipGain.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model
        model.selectClip(
            trackID: fixture.trackID,
            clipID: fixture.clipIDs[0],
            mode: .replace
        )
        let original = try XCTUnwrap(model.selectedClip?.audioMix)

        XCTAssertTrue(
            model.setSelectedClipAudioGain(
                AudioMixUISupport.linearGain(fromDB: -3),
                gesturePhase: .discrete
            )
        )
        let afterGain = try XCTUnwrap(model.selectedClip)
        XCTAssertEqual(
            AudioMixUISupport.gainDB(fromLinear: afterGain.audioMix.gain.base.doubleValue),
            -3,
            accuracy: 0.15
        )
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Clip Audio Mix")

        XCTAssertTrue(
            model.setSelectedClipAudioPan(
                RationalValue.approximating(0.25),
                gesturePhase: .discrete
            )
        )
        let afterPan = try XCTUnwrap(model.selectedClip)
        XCTAssertEqual(afterPan.audioMix.pan.base.doubleValue, 0.25, accuracy: 0.001)

        model.undo()
        model.undo()
        XCTAssertEqual(model.selectedClip?.audioMix, original)
    }

    func testFRAUD002FadeCommandsUndoSymmetry() throws {
        let fixture = try makeAudioProjectFixture(clipCount: 1)
        let loaded = try loadAudioFixture(project: fixture.project, named: "Fades.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model
        model.selectClip(
            trackID: fixture.trackID,
            clipID: fixture.clipIDs[0],
            mode: .replace
        )
        let original = try XCTUnwrap(model.selectedClip?.audioMix)

        XCTAssertTrue(model.applyDefaultFadeInToSelectedAudioClip())
        let afterFadeIn = try XCTUnwrap(model.selectedClip)
        XCTAssertGreaterThan(afterFadeIn.audioMix.fadeIn.duration.seconds, 0)
        XCTAssertTrue(model.applyDefaultFadeOutToSelectedAudioClip())
        let afterFadeOut = try XCTUnwrap(model.selectedClip)
        XCTAssertGreaterThan(afterFadeOut.audioMix.fadeOut.duration.seconds, 0)

        model.undo()
        model.undo()
        XCTAssertEqual(model.selectedClip?.audioMix, original)
    }

    func testFRAUD002CrossfadeCommandUndoSymmetry() throws {
        let fixture = try makeAudioProjectFixture(clipCount: 2)
        let loaded = try loadAudioFixture(project: fixture.project, named: "CrossfadeUI.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model

        model.selectClip(
            trackID: fixture.trackID,
            clipID: fixture.clipIDs[0],
            mode: .replace
        )
        XCTAssertTrue(model.canAddCrossfadeAfterSelectedAudioClip)
        XCTAssertTrue(model.addCrossfadeAfterSelectedAudioClip())
        XCTAssertTrue(model.selectedClipHasTrailingCrossfade)

        let sequence = try XCTUnwrap(model.activeSequence)
        let track = try XCTUnwrap(sequence.audioTracks.first(where: { $0.id == fixture.trackID }))
        let outgoing = try firstClip(id: fixture.clipIDs[0], in: track)
        let incoming = try firstClip(id: fixture.clipIDs[1], in: track)
        XCTAssertNotNil(outgoing.audioMix.trailingCrossfade)
        XCTAssertNotNil(incoming.audioMix.leadingCrossfade)

        model.undo()
        let restoredTrack = try XCTUnwrap(
            model.activeSequence?.audioTracks.first(where: { $0.id == fixture.trackID })
        )
        let restoredOutgoing = try firstClip(id: fixture.clipIDs[0], in: restoredTrack)
        XCTAssertNil(restoredOutgoing.audioMix.trailingCrossfade)
    }

    func testFRAUD002WaveformCacheReuseFromMediaPreviewMap() throws {
        let fixture = try makeAudioProjectFixture(clipCount: 1)
        let loaded = try loadAudioFixture(project: fixture.project, named: "Waveform.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model
        let sequence = try XCTUnwrap(model.activeSequence)
        let track = try XCTUnwrap(sequence.audioTracks.first)
        let layouts = model.timelineClipLayouts(for: track)
        XCTAssertFalse(layouts.isEmpty)
        XCTAssertEqual(layouts.first?.kind, .audio)
        model.ensureTimelineAudioWaveforms()
        if let mediaID = layouts.first?.mediaID {
            XCTAssertEqual(
                model.waveformSummary(forMediaID: mediaID),
                model.mediaWaveformSummary[mediaID]
            )
        }
    }

    func testFRAUD003MixerPanelToggleIsSessionChrome() throws {
        let fixture = try makeAudioProjectFixture(clipCount: 1)
        let loaded = try loadAudioFixture(project: fixture.project, named: "Toggle.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model
        let before = try XCTUnwrap(model.project)
        XCTAssertFalse(model.isMixerPanelVisible)
        model.toggleMixerPanel()
        XCTAssertTrue(model.isMixerPanelVisible)
        XCTAssertEqual(model.project, before)
        model.toggleMixerPanel()
        XCTAssertFalse(model.isMixerPanelVisible)
    }

    // MARK: - Helpers

    private struct AudioProjectFixture {
        let project: Project
        let sequenceID: UUID
        let trackID: UUID
        let clipIDs: [UUID]
        let mediaID: UUID
    }

    private func makeAudioProjectFixture(clipCount: Int) throws -> AudioProjectFixture {
        let frameRate = try FrameRate(frames: 30)
        let mediaID = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
        let trackID = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!
        let sequenceID = UUID(uuidString: "00000000-0000-0000-0000-00000000A005")!
        let framesPerClip: Int64 = 30
        let totalFrames = framesPerClip * Int64(clipCount)
        let duration = try frameRate.duration(ofFrames: totalFrames)
        let media = MediaRef(
            id: mediaID,
            sourceURL: URL(fileURLWithPath: "/tmp/editor-ajar-audio-ui.synthetic-audio"),
            contentHash: ContentHash.sha256(data: Data("editor-ajar-audio-ui".utf8)),
            metadata: MediaMetadata(
                codecID: EditorAjarSampleProjectFactory.sampleToneCodecID,
                pixelDimensions: nil,
                frameRate: nil,
                duration: duration,
                colorSpace: .unspecified,
                audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )

        var items: [TimelineItem] = []
        var clipIDs: [UUID] = []
        for index in 0..<clipCount {
            let clipID = UUID(
                uuidString: String(format: "00000000-0000-0000-0000-00000000A1%02d", index + 3)
            )!
            clipIDs.append(clipID)
            let start = try frameRate.duration(ofFrames: framesPerClip * Int64(index))
            let half = try frameRate.duration(ofFrames: framesPerClip)
            let clip = Clip(
                id: clipID,
                source: .media(id: mediaID),
                sourceRange: try TimeRange(start: start, duration: half),
                timelineRange: try TimeRange(start: start, duration: half),
                kind: .audio,
                name: "Audio \(index + 1)"
            )
            items.append(.clip(clip))
        }

        let sequence = Sequence(
            id: sequenceID,
            name: "Audio UI Fixture",
            videoTracks: [],
            audioTracks: [
                Track(id: trackID, kind: .audio, items: items)
            ],
            markers: [],
            timebase: frameRate
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 1280, height: 720),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [media],
            sequences: [sequence]
        )
        return AudioProjectFixture(
            project: project,
            sequenceID: sequenceID,
            trackID: trackID,
            clipIDs: clipIDs,
            mediaID: mediaID
        )
    }

    private func loadAudioFixture(
        project: Project,
        named name: String
    ) throws -> (model: EditorAjarAppModel, packageDirectory: URL) {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-ui-\(UUID().uuidString)-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
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
            packageURL
        )
    }

    private func firstClip(id: UUID, in track: Track) throws -> Clip {
        for item in track.items {
            if case .clip(let clip) = item, clip.id == id {
                return clip
            }
        }
        return try XCTUnwrap(nil)
    }
}
