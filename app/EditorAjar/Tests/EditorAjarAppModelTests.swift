// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import AjarAudio
import AjarCore
import AjarExport
import AjarMedia
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarAppModelTests: XCTestCase {
    func testFRPROJ001LaunchStartsAtNewOrOpenWithoutSampleProject() {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)

        XCTAssertNil(model.project)
        XCTAssertNil(model.documentURL)
        XCTAssertFalse(model.isDocumentDirty)
        XCTAssertFalse(model.canSaveProject)
        XCTAssertEqual(model.documentDisplayName, "Editor Ajar")
    }

    func testFRPLAY001HelpSampleProjectLoadsFromAjarCoreModel() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0)

        try model.openSampleProject()

        XCTAssertNotNil(model.project)
        XCTAssertEqual(model.activeSequenceName, "Sample Playback Sequence")
        XCTAssertEqual(model.project?.validate(), .valid)
        XCTAssertEqual(model.frameRateDescription, "30 fps")
        XCTAssertEqual(model.project?.mediaPool.count, 2)
        XCTAssertEqual(model.activeSequence?.videoTracks.count, 2)
        XCTAssertEqual(model.activeSequence?.audioTracks.count, 2)
        XCTAssertGreaterThan(model.durationFrames, 1)
    }

    func testFREXP003004ExportDialogPresentsPresetsAndValidatesWholeTimeline() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-export-presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL,
            opensSampleProjectWhenNoRecovery: true
        )

        model.presentExportDialog()
        XCTAssertTrue(model.exportDialog.isPresented)
        XCTAssertGreaterThanOrEqual(model.exportDialog.availablePresets.count, 5)
        XCTAssertEqual(model.exportDialog.mode, .video)
        XCTAssertEqual(model.exportDialog.rangeChoice, .wholeTimeline)

        XCTAssertTrue(model.validateExportDialogSelection())
        XCTAssertEqual(
            model.exportDialog.statusMessage,
            "Ready to export video"
        )

        model.setExportMode(.stillFrame)
        XCTAssertTrue(model.validateExportDialogSelection())

        model.setExportMode(.audioOnly)
        model.setAudioOnlyFormat(.wavPCM)
        XCTAssertTrue(model.validateExportDialogSelection())

        model.dismissExportDialog()
        XCTAssertFalse(model.exportDialog.isPresented)
    }

    func testFREXP003CustomPresetsPersistAppSideNotInProject() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-export-presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL,
            opensSampleProjectWhenNoRecovery: true
        )
        let frameRate = try FrameRate(frames: 30)
        let custom = ExportPreset(
            name: "Test 480p",
            isBuiltIn: false,
            container: .mp4,
            videoCodec: .h264,
            resolution: PixelDimensions(width: 854, height: 480),
            frameRate: frameRate,
            averageBitRate: 2_500_000,
            audio: try ExportAudioSettings(
                codec: .aac,
                sampleRate: 48_000,
                channelCount: 2,
                bitRate: 128_000
            )
        )
        try model.saveCustomExportPreset(custom)

        let reloaded = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL,
            opensSampleProjectWhenNoRecovery: true
        )
        XCTAssertTrue(reloaded.exportDialog.availablePresets.contains { $0.id == custom.id })
        // Project package is untouched — custom presets never appear in project.json fields.
        XCTAssertEqual(model.project, reloaded.project)
    }

    func testFREXP004ExportDialogRejectsMissingInOutMarks() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-export-presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL,
            opensSampleProjectWhenNoRecovery: true
        )
        model.presentExportDialog()
        model.setExportRangeChoice(.inOutMarks)
        // No in/out marks set.
        XCTAssertFalse(model.validateExportDialogSelection())
        XCTAssertNotNil(model.exportDialog.statusMessage)
    }

    /// Out mark is inclusive (NLE convention): UI "Range 10-14" exports frames 10…14 inclusive.
    func testFREXP004InOutMarksExportInclusiveOutFrameFirstAndLast() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-export-presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL,
            opensSampleProjectWhenNoRecovery: true
        )
        let sequence = try XCTUnwrap(model.activeSequence)
        let frameRate = sequence.timebase

        model.scrub(to: 10)
        model.setTimelineRangeIn()
        model.scrub(to: 14)
        model.setTimelineRangeOut()
        XCTAssertEqual(model.timelineRangeDescription, "Range 10-14")

        model.setExportRangeChoice(.inOutMarks)
        let range = try model.exportDialog.resolvedRange(
            sequence: sequence,
            selectionInFrame: model.timelineState.selectionInFrame,
            selectionOutFrame: model.timelineState.selectionOutFrame
        )

        let firstFrame = try range.start.frameIndex(
            at: frameRate,
            rounding: .towardZero
        )
        let exclusiveEnd = try range.start.adding(range.duration)
        let exclusiveEndFrame = try exclusiveEnd.frameIndex(
            at: frameRate,
            rounding: .towardZero
        )
        let lastFrame = exclusiveEndFrame - 1
        let frameCount = try range.duration.frameIndex(
            at: frameRate,
            rounding: .towardZero
        )

        XCTAssertEqual(firstFrame, 10, "first exported frame must match inclusive in mark")
        XCTAssertEqual(lastFrame, 14, "last exported frame must match inclusive out mark")
        XCTAssertEqual(frameCount, 5, "inclusive [10,14] is 5 frames → half-open [10,15)")
        XCTAssertEqual(exclusiveEndFrame, 15)

        // Single-frame mark pair is valid under inclusive-out.
        model.scrub(to: 7)
        model.setTimelineRangeIn()
        model.setTimelineRangeOut()
        XCTAssertEqual(model.timelineRangeDescription, "Range 7-7")
        let single = try model.exportDialog.resolvedRange(
            sequence: sequence,
            selectionInFrame: model.timelineState.selectionInFrame,
            selectionOutFrame: model.timelineState.selectionOutFrame
        )
        let singleCount = try single.duration.frameIndex(
            at: frameRate,
            rounding: .towardZero
        )
        XCTAssertEqual(singleCount, 1)
    }

    func testFREXP004StillExportClampsPlayheadAtDurationExclusiveEnd() {
        // playheadFrame is private(set) and scrub clamps below duration; pin the pure clamp
        // used by the still-export path when playhead sits on the exclusive end.
        XCTAssertEqual(
            EditorAjarAppModel.clampedStillExportFrame(playheadFrame: 90, durationFrames: 90),
            89
        )
        XCTAssertEqual(
            EditorAjarAppModel.clampedStillExportFrame(playheadFrame: 89, durationFrames: 90),
            89
        )
        XCTAssertEqual(
            EditorAjarAppModel.clampedStillExportFrame(playheadFrame: 0, durationFrames: 1),
            0
        )
        XCTAssertEqual(
            EditorAjarAppModel.clampedStillExportFrame(playheadFrame: 5, durationFrames: 0),
            0
        )
    }

    func testFREXP003SaveCustomPresetRecoversFromCorruptStore() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-export-presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        // Corrupt JSON that would make loadCustomPresets throw decodingFailed.
        try Data("{ not valid json".utf8).write(to: storeURL)

        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL,
            opensSampleProjectWhenNoRecovery: true
        )
        let frameRate = try FrameRate(frames: 30)
        let custom = ExportPreset(
            name: "Recovered After Corrupt",
            isBuiltIn: false,
            container: .mp4,
            videoCodec: .h264,
            resolution: PixelDimensions(width: 640, height: 360),
            frameRate: frameRate,
            averageBitRate: 1_500_000,
            audio: try ExportAudioSettings(
                codec: .aac,
                sampleRate: 48_000,
                channelCount: 2,
                bitRate: 128_000
            )
        )
        // Must not propagate decodingFailed — overwrite corrupt store with the new preset.
        try model.saveCustomExportPreset(custom)
        XCTAssertTrue(model.exportDialog.availablePresets.contains { $0.id == custom.id })

        let reloaded = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            exportPresetStoreURL: storeURL,
            opensSampleProjectWhenNoRecovery: true
        )
        XCTAssertTrue(reloaded.exportDialog.availablePresets.contains { $0.id == custom.id })
    }

    func testFRPLAY001TransportTogglesPlaybackAndFrameStepPauses() {
        let model = EditorAjarAppModel(opensSampleProjectWhenNoRecovery: true)

        XCTAssertFalse(model.isPlaying)
        model.togglePlayback()
        XCTAssertTrue(model.isPlaying)

        model.stepForward()
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playheadFrame, 1)

        model.stepBackward()
        model.stepBackward()
        XCTAssertEqual(model.playheadFrame, 0)
    }

    func testFRAUD007TransportStartsAndStopsLiveAudioWithVideoPlayback() {
        let audioCoordinator = FakeAudioCoordinator()
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            audioCoordinator: audioCoordinator,
            opensSampleProjectWhenNoRecovery: true
        )

        model.togglePlayback()

        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(audioCoordinator.startedFrames, [0])
        XCTAssertEqual(audioCoordinator.stopCount, 0)

        model.togglePlayback()

        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(audioCoordinator.stopCount, 1)
    }

    func testFRAUD007SynchronousAudioStartFailurePausesTransport() {
        let audioCoordinator = FakeAudioCoordinator()
        audioCoordinator.startError = TestAudioPreparationError.unreadable
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            audioCoordinator: audioCoordinator,
            opensSampleProjectWhenNoRecovery: true
        )

        model.shuttleForward()

        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playbackRate, 0)
        XCTAssertEqual(audioCoordinator.stopCount, 1)
        XCTAssertEqual(
            model.audioPlaybackError,
            .renderFailed("unreadable")
        )
        XCTAssertTrue(model.loadMessage.contains("Audio playback unavailable"))
    }

    func testFRAUD007SynchronousAudioSeekFailurePausesTransport() {
        let audioCoordinator = FakeAudioCoordinator()
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            audioCoordinator: audioCoordinator,
            opensSampleProjectWhenNoRecovery: true
        )
        model.shuttleForward()
        audioCoordinator.seekError = TestAudioPreparationError.unreadable

        _ = model.setMasterGainDB(-3, gesturePhase: .ended)

        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playbackRate, 0)
        XCTAssertEqual(audioCoordinator.stopCount, 1)
        XCTAssertEqual(
            model.audioPlaybackError,
            .renderFailed("unreadable")
        )
    }

    func testFRAUD007FastForwardShuttleMutesWithoutRestartingAudio() {
        let audioCoordinator = FakeAudioCoordinator()
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            audioCoordinator: audioCoordinator,
            opensSampleProjectWhenNoRecovery: true
        )

        model.shuttleForward()
        model.shuttleForward()
        model.shuttleForward()

        XCTAssertEqual(model.playbackRate, 4)
        XCTAssertEqual(audioCoordinator.startedFrames, [0])
        XCTAssertEqual(audioCoordinator.stopCount, 2)

        model.shuttlePause()
        model.shuttleForward()
        XCTAssertEqual(model.playbackRate, 1)
        XCTAssertEqual(audioCoordinator.startedFrames, [0, 0])
    }

    func testFRPLAY003StepAndScrubDoNotRepublishLiveAudioWhilePaused() {
        let audioCoordinator = FakeAudioCoordinator()
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            audioCoordinator: audioCoordinator,
            opensSampleProjectWhenNoRecovery: true
        )

        model.scrub(to: 12)
        model.stepForward()
        model.stepBackward()

        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(audioCoordinator.seekFrames, [])
        XCTAssertEqual(audioCoordinator.stopCount, 3)
    }

    func testFRAUD007CoordinatorRefillsLiveAudioAtPlaybackWindowMargin() async throws {
        let driver = FakeAudioOutputDriver()
        let coordinator = EditorAjarLiveAudioCoordinator(driver: driver)
        let project = try EditorAjarSampleProjectFactory.makeSampleProject()
        let sequence = try XCTUnwrap(project.sequences.first)
        let durationFrames = try Self.durationFrames(for: sequence)

        try coordinator.start(
            project: project,
            sequence: sequence,
            playheadFrame: 0,
            durationFrames: durationFrames
        )
        await coordinator.drainPendingRendersForTesting()

        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(driver.publishCount, 1)
        XCTAssertEqual(driver.publishedFrameCounts, [96_000])
        XCTAssertEqual(driver.publishWasOnMainThread, [false])

        try coordinator.ensurePlaybackPlan(
            project: project,
            sequence: sequence,
            playheadFrame: 29,
            durationFrames: durationFrames
        )
        await coordinator.drainPendingRendersForTesting()

        XCTAssertEqual(driver.publishCount, 1)

        try coordinator.ensurePlaybackPlan(
            project: project,
            sequence: sequence,
            playheadFrame: 30,
            durationFrames: durationFrames
        )
        await coordinator.drainPendingRendersForTesting()

        XCTAssertEqual(driver.publishCount, 2)
        XCTAssertEqual(driver.publishedFrameCounts, [96_000, 96_000])
        XCTAssertEqual(driver.publishWasOnMainThread, [false, false])
    }

    func testFRAUD007DelayedRefillStartsAtLatestPlaybackFrame() async throws {
        let driver = FakeAudioOutputDriver()
        let gate = AudioRefillPreparationGate()
        let coordinator = EditorAjarLiveAudioCoordinator(
            driver: driver,
            sourceProviderFactory: { project, sequence, range in
                try await gate.prepare(project: project, sequence: sequence, range: range)
            }
        )
        let project = try EditorAjarSampleProjectFactory.makeSampleProject()
        let sequence = try XCTUnwrap(project.sequences.first)
        let durationFrames = try Self.durationFrames(for: sequence)

        try coordinator.start(
            project: project,
            sequence: sequence,
            playheadFrame: 0,
            durationFrames: durationFrames
        )
        await coordinator.drainPendingRendersForTesting()

        try coordinator.ensurePlaybackPlan(
            project: project,
            sequence: sequence,
            playheadFrame: 30,
            durationFrames: durationFrames
        )
        await gate.waitUntilRefillEntered()

        // Video advances while the second source window is still being decoded. Publishing that
        // window from sample zero would replay frame 30 and permanently lag video by one frame.
        try coordinator.ensurePlaybackPlan(
            project: project,
            sequence: sequence,
            playheadFrame: 31,
            durationFrames: durationFrames
        )
        coordinator.drainControlQueueForTesting()
        await gate.releaseRefill()
        await coordinator.drainPendingRendersForTesting()

        XCTAssertEqual(driver.publishCount, 2)
        let firstSamples = driver.publishedFirstSamples
        XCTAssertEqual(firstSamples.count, 2)
        XCTAssertEqual(firstSamples[0], 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(
            abs(firstSamples[1]),
            0.05,
            "refill must skip the silent sample at frame 30 and begin at video frame 31"
        )
    }

    func testFRAUD007DecodedCacheRefusesOfflineAndDeletedButRefreshesNilHashSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-audio-cache-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.wav")

        func writeWave(amplitude: Float, frameCount: AVAudioFrameCount) throws {
            let format = try XCTUnwrap(
                AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)
            )
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
            )
            buffer.frameLength = frameCount
            let channelData = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<Int(frameCount) {
                channelData[0][frame] = amplitude
            }
            let file = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
            try file.write(from: buffer)
        }

        try writeWave(amplitude: 0.1, frameCount: 80)
        let mediaID = UUID()
        let metadata = MediaMetadata(
            codecID: "pcm_f32le",
            pixelDimensions: nil,
            frameRate: nil,
            duration: try RationalTime(value: 1, timescale: 100),
            colorSpace: .unspecified,
            audioChannelLayout: AudioChannelLayout(channelCount: 1),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
        let media = MediaRef(
            id: mediaID,
            sourceURL: sourceURL,
            contentHash: nil,
            metadata: metadata
        )
        let window = AudioSourceTimeWindow(
            mediaID: mediaID,
            range: try TimeRange(start: .zero, duration: metadata.duration)
        )
        let cache = EditorAjarDecodedAudioWindowCache()
        let first = try await cache.decode(media: media, window: window)
        XCTAssertEqual(first.frameCount, 80, "cache alignment must clamp to the probed EOF")
        XCTAssertEqual(try XCTUnwrap(first.samples.first), 0.1, accuracy: 0.000_1)

        try FileManager.default.removeItem(at: sourceURL)
        do {
            _ = try await cache.decode(media: media, window: window)
            XCTFail("Deleted media must not be served from decoded cache")
        } catch {
            XCTAssertEqual(error as? AudioPCMDecodeError, .missingSource(sourceURL))
        }

        try writeWave(amplitude: 0.35, frameCount: 160)
        let replaced = try await cache.decode(media: media, window: window)
        XCTAssertEqual(try XCTUnwrap(replaced.samples.first), 0.35, accuracy: 0.000_1)

        let offline = MediaRef(
            id: mediaID,
            sourceURL: sourceURL,
            contentHash: nil,
            metadata: metadata,
            availability: .offline
        )
        do {
            _ = try await cache.decode(media: offline, window: window)
            XCTFail("Offline media must not be served from decoded cache")
        } catch {
            XCTAssertEqual(error as? AudioPCMDecodeError, .missingSource(sourceURL))
        }
    }

    func testFRAUD007DecodedCacheRefusesReplacedBytesWithDurableHash() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-audio-identity-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.wav")

        func writeWave(amplitude: Float, frameCount: AVAudioFrameCount) throws {
            let format = try XCTUnwrap(
                AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)
            )
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
            )
            buffer.frameLength = frameCount
            let channelData = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<Int(frameCount) {
                channelData[0][frame] = amplitude
            }
            let file = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
            try file.write(from: buffer)
        }

        try writeWave(amplitude: 0.1, frameCount: 80)
        let durableHash = try SHA256MediaFileHasher().contentHash(of: sourceURL)
        let mediaID = UUID()
        let metadata = MediaMetadata(
            codecID: "pcm_f32le",
            pixelDimensions: nil,
            frameRate: nil,
            duration: try RationalTime(value: 1, timescale: 100),
            colorSpace: .unspecified,
            audioChannelLayout: AudioChannelLayout(channelCount: 1),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
        let media = MediaRef(
            id: mediaID,
            sourceURL: sourceURL,
            contentHash: durableHash,
            metadata: metadata
        )
        let window = AudioSourceTimeWindow(
            mediaID: mediaID,
            range: try TimeRange(start: .zero, duration: metadata.duration)
        )
        let cache = EditorAjarDecodedAudioWindowCache(
            identityVerifier: MediaSourceIdentityVerifier()
        )

        let first = try await cache.decode(media: media, window: window)
        XCTAssertEqual(try XCTUnwrap(first.samples.first), 0.1, accuracy: 0.000_1)

        try writeWave(amplitude: 0.35, frameCount: 160)
        let replacementHash = try SHA256MediaFileHasher().contentHash(of: sourceURL)
        do {
            _ = try await cache.decode(media: media, window: window)
            XCTFail("replacement bytes must not be decoded under the stale project hash")
        } catch let error as MediaSourceIdentityVerificationError {
            XCTAssertEqual(
                error,
                .playableContentHashMismatch(
                    url: sourceURL.standardizedFileURL,
                    expected: durableHash,
                    actual: replacementHash
                )
            )
        }
    }

    func testFRAUD007CoordinatorResamplesNon48KProjectToDeviceFacingRate() async throws {
        let driver = FakeAudioOutputDriver()
        let coordinator = EditorAjarLiveAudioCoordinator(driver: driver)
        let fixture = try EditorAjarSampleProjectFactory.makeSampleProject()
        let settings = ProjectSettings(
            frameRate: fixture.settings.frameRate,
            resolution: fixture.settings.resolution,
            colorSpace: fixture.settings.colorSpace,
            audioSampleRate: 44_100
        )
        let project = Project(
            schemaVersion: fixture.schemaVersion,
            settings: settings,
            mediaPool: fixture.mediaPool,
            sequences: fixture.sequences
        )
        let sequence = try XCTUnwrap(project.sequences.first)

        try coordinator.start(
            project: project,
            sequence: sequence,
            playheadFrame: 0,
            durationFrames: try Self.durationFrames(for: sequence)
        )
        await coordinator.drainPendingRendersForTesting()

        XCTAssertEqual(driver.publishCount, 1)
        XCTAssertEqual(
            driver.publishedFrameCounts,
            [96_000],
            "two seconds of live output must stay two seconds at the fixed 48 kHz device rate"
        )
    }

    func testFRAUD007CoordinatorStartsOutputOnlyAfterInitialPlanIsReady() async throws {
        let driver = FakeAudioOutputDriver()
        let gate = AudioProviderPreparationGate()
        let coordinator = EditorAjarLiveAudioCoordinator(
            driver: driver,
            sourceProviderFactory: { project, sequence, range in
                await gate.suspendUntilReleased()
                return try EditorAjarProjectAudioSourceProvider(
                    project: project,
                    sequence: sequence,
                    range: range
                )
            }
        )
        let project = try EditorAjarSampleProjectFactory.makeSampleProject()
        let sequence = try XCTUnwrap(project.sequences.first)

        try coordinator.start(
            project: project,
            sequence: sequence,
            playheadFrame: 0,
            durationFrames: try Self.durationFrames(for: sequence)
        )
        await gate.waitUntilEntered()

        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(driver.publishCount, 0)

        await gate.release()
        await coordinator.drainPendingRendersForTesting()
        XCTAssertEqual(driver.publishCount, 1)
        XCTAssertEqual(driver.startCount, 1)
    }

    func testFRAUD007InitialPlanEventPrecedesAudioDeviceStart() async throws {
        let driver = FakeAudioOutputDriver()
        let coordinator = EditorAjarLiveAudioCoordinator(driver: driver)
        let planPublished = expectation(description: "video may begin before audio device")
        coordinator.setEventHandler { event in
            guard event == .planPublished else {
                return
            }
            XCTAssertEqual(
                driver.startCount,
                0,
                "audio must wait until the MainActor video-start handler has returned"
            )
            planPublished.fulfill()
        }
        coordinator.drainControlQueueForTesting()
        let project = try EditorAjarSampleProjectFactory.makeSampleProject()
        let sequence = try XCTUnwrap(project.sequences.first)

        try coordinator.start(
            project: project,
            sequence: sequence,
            playheadFrame: 0,
            durationFrames: try Self.durationFrames(for: sequence)
        )
        await fulfillment(of: [planPublished], timeout: 2)
        coordinator.drainControlQueueForTesting()

        XCTAssertEqual(driver.publishCount, 1)
        XCTAssertEqual(driver.startCount, 1)
    }

    func testFRAUD007StopSuppressesInitialPlanEventQueuedOnMainActor() async throws {
        let driver = FakeAudioOutputDriver()
        let coordinator = EditorAjarLiveAudioCoordinator(driver: driver)
        var receivedEvents: [EditorAjarLiveAudioEvent] = []
        coordinator.setEventHandler { event in
            receivedEvents.append(event)
        }
        coordinator.drainControlQueueForTesting()
        let project = try EditorAjarSampleProjectFactory.makeSampleProject()
        let sequence = try XCTUnwrap(project.sequences.first)

        try coordinator.start(
            project: project,
            sequence: sequence,
            playheadFrame: 0,
            durationFrames: try Self.durationFrames(for: sequence)
        )
        XCTAssertTrue(
            driver.waitForNextPublish(),
            "the render queue must publish while this test deliberately holds the MainActor"
        )

        coordinator.stop()
        coordinator.drainControlQueueForTesting()
        await coordinator.drainPlanPublishedDeliveryForTesting()

        XCTAssertTrue(receivedEvents.isEmpty)
        XCTAssertEqual(driver.startCount, 0)
    }

    func testFRAUD007StopSuppressesFailureQueuedOnMainActor() async throws {
        let driver = FakeAudioOutputDriver(publishError: TestAudioOutputError.unavailable)
        let coordinator = EditorAjarLiveAudioCoordinator(driver: driver)
        var receivedEvents: [EditorAjarLiveAudioEvent] = []
        coordinator.setEventHandler { event in
            receivedEvents.append(event)
        }
        coordinator.drainControlQueueForTesting()
        let project = try EditorAjarSampleProjectFactory.makeSampleProject()
        let sequence = try XCTUnwrap(project.sequences.first)

        try coordinator.start(
            project: project,
            sequence: sequence,
            playheadFrame: 0,
            durationFrames: try Self.durationFrames(for: sequence)
        )
        XCTAssertTrue(
            driver.waitForNextPublish(),
            "publish must queue its failure while this test deliberately holds the MainActor"
        )

        coordinator.stop()
        coordinator.drainControlQueueForTesting()
        await coordinator.drainFailureDeliveryForTesting()

        XCTAssertTrue(receivedEvents.isEmpty)
        XCTAssertEqual(driver.startCount, 0)
    }

    func testFRAUD007SeekSuppressesStalePlanEventButDeliversCurrentReplacement() async throws {
        let driver = FakeAudioOutputDriver()
        let gate = AudioRefillPreparationGate()
        let coordinator = EditorAjarLiveAudioCoordinator(
            driver: driver,
            sourceProviderFactory: { project, sequence, range in
                try await gate.prepare(project: project, sequence: sequence, range: range)
            }
        )
        var receivedEvents: [EditorAjarLiveAudioEvent] = []
        coordinator.setEventHandler { event in
            receivedEvents.append(event)
        }
        coordinator.drainControlQueueForTesting()
        let project = try EditorAjarSampleProjectFactory.makeSampleProject()
        let sequence = try XCTUnwrap(project.sequences.first)
        let durationFrames = try Self.durationFrames(for: sequence)

        try coordinator.start(
            project: project,
            sequence: sequence,
            playheadFrame: 0,
            durationFrames: durationFrames
        )
        XCTAssertTrue(
            driver.waitForNextPublish(),
            "the first plan must queue its MainActor event before the seek invalidates it"
        )

        try coordinator.publishSeek(
            project: project,
            sequence: sequence,
            playheadFrame: 1,
            durationFrames: durationFrames
        )
        coordinator.drainControlQueueForTesting()
        await gate.waitUntilRefillEntered()
        await coordinator.drainPlanPublishedDeliveryForTesting()

        XCTAssertTrue(receivedEvents.isEmpty)
        XCTAssertEqual(driver.startCount, 0)

        await gate.releaseRefill()
        await coordinator.drainPendingRendersForTesting()
        await coordinator.drainPlanPublishedDeliveryForTesting()
        coordinator.drainControlQueueForTesting()

        XCTAssertEqual(receivedEvents, [.planPublished])
        XCTAssertEqual(driver.publishCount, 2)
        XCTAssertEqual(driver.startCount, 1)
        coordinator.stop()
    }

    func testFRAUD007DecodeFailureStopsOutputAndPublishesTypedErrorNotSilence() async throws {
        let driver = FakeAudioOutputDriver()
        let failed = expectation(description: "typed live audio failure")
        let coordinator = EditorAjarLiveAudioCoordinator(
            driver: driver,
            sourceProviderFactory: { _, _, _ in
                throw TestAudioPreparationError.unreadable
            }
        )
        coordinator.setEventHandler { event in
            guard case .failed(.sourcePreparationFailed(let reason)) = event else {
                return
            }
            XCTAssertTrue(reason.contains("unreadable"))
            failed.fulfill()
        }
        let project = try EditorAjarSampleProjectFactory.makeSampleProject()
        let sequence = try XCTUnwrap(project.sequences.first)

        try coordinator.start(
            project: project,
            sequence: sequence,
            playheadFrame: 0,
            durationFrames: try Self.durationFrames(for: sequence)
        )
        await coordinator.drainPendingRendersForTesting()
        await fulfillment(of: [failed], timeout: 2)

        XCTAssertEqual(driver.publishCount, 0)
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertGreaterThanOrEqual(driver.stopCount, 1)
    }

    func testFRAUD007AppModelSurfacesTypedLiveAudioFailure() async throws {
        let driver = FakeAudioOutputDriver()
        let preparation = RecoverableAudioPreparation()
        let coordinator = EditorAjarLiveAudioCoordinator(
            driver: driver,
            sourceProviderFactory: { project, sequence, range in
                try await preparation.prepare(
                    project: project,
                    sequence: sequence,
                    range: range
                )
            }
        )
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            audioCoordinator: coordinator,
            opensSampleProjectWhenNoRecovery: true
        )

        model.shuttleForward()
        await coordinator.drainPendingRendersForTesting()
        for _ in 0..<10 where model.audioPlaybackError == nil {
            await Task.yield()
        }

        XCTAssertEqual(
            model.audioPlaybackError,
            .sourcePreparationFailed("unreadable")
        )
        XCTAssertTrue(model.loadMessage.contains("Audio playback unavailable"))
        XCTAssertEqual(driver.publishCount, 0)
        XCTAssertFalse(model.isPlaying)

        await preparation.allowSuccess()
        model.shuttleForward()
        await coordinator.drainPendingRendersForTesting()
        for _ in 0..<200 where model.audioPlaybackError != nil || driver.publishCount != 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertNil(model.audioPlaybackError)
        XCTAssertTrue(model.isPlaying)
        XCTAssertFalse(model.loadMessage.contains("Audio playback unavailable"))
        XCTAssertEqual(driver.publishCount, 1)
    }

    func testFRPLAY001DisplayLinkAdvancesPlayheadAtSequenceFrameRate() throws {
        let frameRate = try FrameRate(frames: 30)
        var controller = EditorAjarPlaybackController(frameRate: frameRate, durationFrames: 4)
        controller.shuttleForward()

        XCTAssertFalse(controller.advance(by: 1.0 / 60.0))
        XCTAssertEqual(controller.playheadFrame, 0)
        XCTAssertTrue(controller.advance(by: 1.0 / 60.0))
        XCTAssertEqual(controller.playheadFrame, 1)

        XCTAssertTrue(controller.advance(by: 3.0 / 30.0))
        XCTAssertEqual(controller.playheadFrame, 0)
    }

    func testFRPLAY003ScrubClampsAndStepUpdatesFrame() throws {
        let frameRate = try FrameRate(frames: 30)
        var controller = EditorAjarPlaybackController(frameRate: frameRate, durationFrames: 10)

        controller.scrub(to: 7)
        XCTAssertEqual(controller.playheadFrame, 7)

        controller.stepForward()
        XCTAssertEqual(controller.playheadFrame, 8)

        controller.scrub(to: 20)
        XCTAssertEqual(controller.playheadFrame, 9)

        controller.scrub(to: -4)
        XCTAssertEqual(controller.playheadFrame, 0)
    }

    func testFRPLAY001JKLStacksRateAndReverses() throws {
        let frameRate = try FrameRate(frames: 30)
        var controller = EditorAjarPlaybackController(frameRate: frameRate, durationFrames: 10)

        controller.shuttleForward()
        XCTAssertEqual(controller.playbackRate, 1)
        controller.shuttleForward()
        XCTAssertEqual(controller.playbackRate, 2)
        controller.shuttleForward()
        XCTAssertEqual(controller.playbackRate, 4)
        controller.shuttleBackward()
        XCTAssertEqual(controller.playbackRate, -1)
        controller.scrub(to: 5)
        XCTAssertEqual(controller.playbackRate, 0)
        XCTAssertFalse(controller.advance(by: 1.0 / 30.0))
        controller.shuttleBackward()
        XCTAssertEqual(controller.playbackRate, -1)
        XCTAssertTrue(controller.advance(by: 1.0 / 30.0))
        XCTAssertEqual(controller.playheadFrame, 4)
        controller.shuttlePause()
        XCTAssertEqual(controller.playbackRate, 0)
        XCTAssertFalse(controller.advance(by: 1.0))
    }

    func testFRPLAY001LoopWrapsInBothDirections() throws {
        let frameRate = try FrameRate(frames: 30)
        var controller = EditorAjarPlaybackController(frameRate: frameRate, durationFrames: 10)
        controller.setLoopRange(2...4)
        controller.scrub(to: 4)
        XCTAssertTrue(controller.advance(by: 1.0 / 30.0))
        XCTAssertEqual(controller.playheadFrame, 2)
        controller.shuttleBackward()
        XCTAssertTrue(controller.advance(by: 1.0 / 30.0))
        XCTAssertEqual(controller.playheadFrame, 4)
    }

    func testFRPLAY003EditPointsIncludeAudioOnlyCuts() throws {
        let frameRate = try FrameRate(frames: 30)
        let baseSequence = try makeInteractionSequence()
        let audioClip = try makeInteractionClip(
            id: "00000000-0000-0000-0000-00000000d004",
            name: "Audio-only cut",
            startFrame: 37,
            durationFrames: 5,
            frameRate: frameRate
        )
        let sequence = Sequence(
            id: baseSequence.id,
            name: baseSequence.name,
            videoTracks: baseSequence.videoTracks,
            audioTracks: [Track(id: UUID(), kind: .audio, items: [.clip(audioClip)])],
            markers: baseSequence.markers,
            timebase: baseSequence.timebase
        )

        let editPoints = EditorAjarAppModel.editPointFrames(
            in: sequence,
            durationFrames: 90
        )

        XCTAssertTrue(editPoints.contains(37))
        XCTAssertTrue(editPoints.contains(42))
    }

    func testFRPLAY006CheckerboardIsSessionState() {
        let model = EditorAjarAppModel(opensSampleProjectWhenNoRecovery: true)
        XCTAssertFalse(model.checkerboardAlphaVisible)
        model.toggleCheckerboardAlpha()
        XCTAssertTrue(model.checkerboardAlphaVisible)
    }

    func testFRSPD001FRSPD003SelectedClipControlsRoundTripThroughEditHistory() throws {
        let model = EditorAjarAppModel(opensSampleProjectWhenNoRecovery: true)
        let track = try XCTUnwrap(model.activeSequence?.videoTracks.first)
        let clip = try XCTUnwrap(track.items.compactMap { item -> Clip? in
            guard case .clip(let clip) = item else { return nil }
            return clip
        }.first)
        model.selectClip(trackID: track.id, clipID: clip.id, mode: .replace)

        XCTAssertTrue(model.updateSelectedClipSpeed(percentText: "200"))
        XCTAssertEqual(model.selectedClip?.speed, RationalValue(2))
        XCTAssertTrue(model.setSelectedClipReverse(true))
        XCTAssertTrue(model.selectedClip?.reverse == true)
        XCTAssertTrue(model.setSelectedClipFreezeFrame(true))
        XCTAssertTrue(model.selectedClip?.freezeFrame == true)

        model.undo()
        XCTAssertFalse(model.selectedClip?.freezeFrame ?? true)
        model.undo()
        XCTAssertFalse(model.selectedClip?.reverse ?? true)
        model.undo()
        XCTAssertEqual(model.selectedClip?.speed, .one)
    }

    func testFRTL001TrackToggleRoutesThroughEditHistoryAndUndo() throws {
        let model = EditorAjarAppModel(opensSampleProjectWhenNoRecovery: true)
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)

        model.setTrackState(
            sequenceID: sequence.id,
            trackID: videoTrack.id,
            enabled: false,
            locked: true,
            hidden: true
        )

        let editedTrack = try XCTUnwrap(model.activeSequence?.videoTracks.first)
        XCTAssertFalse(editedTrack.enabled)
        XCTAssertTrue(editedTrack.locked)
        XCTAssertTrue(editedTrack.hidden)
        XCTAssertTrue(model.canUndo)

        model.undo()

        let restoredTrack = try XCTUnwrap(model.activeSequence?.videoTracks.first)
        XCTAssertTrue(restoredTrack.enabled)
        XCTAssertFalse(restoredTrack.locked)
        XCTAssertFalse(restoredTrack.hidden)
    }

    func testFRTL012AppUndoRedoMenuTitlesAndAvailabilityReflectEditHistory() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
        let originalProject = try XCTUnwrap(model.project)

        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertEqual(model.undoMenuTitle, "Undo")
        XCTAssertEqual(model.redoMenuTitle, "Redo")

        model.setTrackState(
            sequenceID: sequence.id,
            trackID: videoTrack.id,
            hidden: true
        )
        let editedProject = try XCTUnwrap(model.project)

        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertEqual(model.undoMenuTitle, "Undo Change Track State")

        model.undo()

        XCTAssertEqual(model.project, originalProject)
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canRedo)
        XCTAssertEqual(model.undoMenuTitle, "Undo")
        XCTAssertEqual(model.redoMenuTitle, "Redo Change Track State")

        model.redo()

        XCTAssertEqual(model.project, editedProject)
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertEqual(model.undoMenuTitle, "Undo Change Track State")
        XCTAssertEqual(model.redoMenuTitle, "Redo")

        model.undo()
        model.addTimelineMarkerAtPlayhead()

        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertEqual(model.undoMenuTitle, "Undo Add Marker")
    }

    func testFRTL012LongAppUndoRedoSequenceRestoresExactProjectState() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let originalProject = try XCTUnwrap(model.project)
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
        let audioTrack = try XCTUnwrap(sequence.audioTracks.first)
        let linkedSelection = try sampleLinkedSelection(in: model)

        model.setTrackState(
            sequenceID: sequence.id,
            trackID: videoTrack.id,
            hidden: true
        )
        model.setTrackState(
            sequenceID: sequence.id,
            trackID: audioTrack.id,
            muted: true
        )
        model.scrub(to: 12)
        model.addTimelineMarkerAtPlayhead()
        model.updateSelectedMarker(
            name: "Undo checkpoint",
            color: .green,
            note: "FR-TL-012"
        )
        model.selectClip(
            trackID: linkedSelection.videoTrackID,
            clipID: linkedSelection.videoClip.id,
            mode: .replace
        )
        XCTAssertTrue(model.moveSelectedClip(toStartFrame: 6))
        XCTAssertTrue(model.detachAudioForSelectedClip())

        let editedProject = try XCTUnwrap(model.project)
        XCTAssertNotEqual(editedProject, originalProject)
        XCTAssertEqual(model.undoMenuTitle, "Undo Detach Audio")

        for _ in 0..<6 {
            XCTAssertTrue(model.canUndo)
            model.undo()
        }

        XCTAssertEqual(model.project, originalProject)
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canRedo)

        for _ in 0..<6 {
            XCTAssertTrue(model.canRedo)
            model.redo()
        }

        XCTAssertEqual(model.project, editedProject)
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
    }

    func testFRTL011SequenceTabsAddCloseAndUndoThroughEditHistory() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let originalProject = try XCTUnwrap(model.project)
        let originalSequenceID = try XCTUnwrap(model.activeSequenceID)

        XCTAssertEqual(model.sequenceTabs.map(\.title), ["Sample Playback Sequence"])
        XCTAssertFalse(model.canCloseActiveSequence)

        XCTAssertTrue(model.addSequence())
        let addedSequenceID = try XCTUnwrap(model.activeSequenceID)

        XCTAssertNotEqual(addedSequenceID, originalSequenceID)
        XCTAssertEqual(model.activeSequenceName, "Sequence 2")
        XCTAssertEqual(model.project?.sequences.count, 2)
        XCTAssertTrue(model.canCloseActiveSequence)
        XCTAssertEqual(model.undoMenuTitle, "Undo Add Sequence")

        XCTAssertTrue(model.closeActiveSequence())

        XCTAssertEqual(model.activeSequenceID, originalSequenceID)
        XCTAssertEqual(model.project?.sequences.count, 1)
        XCTAssertEqual(model.undoMenuTitle, "Undo Remove Sequence")

        model.undo()

        XCTAssertEqual(model.project?.sequences.count, 2)
        XCTAssertTrue(model.canCloseActiveSequence)

        model.undo()

        XCTAssertEqual(model.project, originalProject)
        XCTAssertEqual(model.activeSequenceID, originalSequenceID)
        XCTAssertFalse(model.canCloseActiveSequence)
    }

    func testFRTL011SequenceTabsRestorePerSequenceEditingContext() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let firstSequenceID = try XCTUnwrap(model.activeSequenceID)
        let firstVideoTrack = try XCTUnwrap(model.activeSequence?.videoTracks.first)
        let firstClipLayout = try XCTUnwrap(model.timelineClipLayouts(for: firstVideoTrack).first)

        model.scrub(to: 12)
        model.selectClip(
            trackID: firstClipLayout.reference.trackID,
            clipID: firstClipLayout.reference.clipID,
            mode: .replace
        )
        model.zoomTimelineIn()
        let firstPixelsPerFrame = model.timelineState.pixelsPerFrame

        XCTAssertTrue(model.addSequence())
        let secondSequenceID = try XCTUnwrap(model.activeSequenceID)

        XCTAssertNotEqual(firstSequenceID, secondSequenceID)
        XCTAssertEqual(model.playheadFrame, 0)
        XCTAssertEqual(model.timelineSelectedClipCount, 0)
        XCTAssertTrue(model.timelineSnappingEnabled)

        model.scrub(to: 5)
        model.setTimelineSnappingEnabled(false)
        model.zoomTimelineOut()

        XCTAssertTrue(model.selectSequence(firstSequenceID))

        XCTAssertEqual(model.playheadFrame, 12)
        XCTAssertEqual(model.timelineSelectedClipCount, 1)
        XCTAssertTrue(model.timelineSnappingEnabled)
        XCTAssertEqual(model.timelineState.pixelsPerFrame, firstPixelsPerFrame)

        XCTAssertTrue(model.selectSequence(secondSequenceID))

        XCTAssertEqual(model.playheadFrame, 0)
        XCTAssertFalse(model.timelineSnappingEnabled)
    }

    func testFRCMP001002004LinkedMakeOpenEditDecomposeAndUndoRedo() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let original = try sampleLinkedSelection(in: model)
        let parentSequenceID = try XCTUnwrap(model.activeSequenceID)
        model.selectClip(
            trackID: original.videoTrackID,
            clipID: original.videoClip.id,
            mode: .replace
        )
        let undoBeforeMake = model.editHistory?.undoCount

        XCTAssertTrue(model.canMakeCompoundClip)
        XCTAssertTrue(model.makeCompoundClip())
        XCTAssertEqual(model.editHistory?.undoCount, (undoBeforeMake ?? 0) + 1)
        XCTAssertEqual(model.activeSequenceID, parentSequenceID, "Make stays on the parent")
        let compound = try XCTUnwrap(model.selectedClip)
        let compoundReference = try XCTUnwrap(model.selectedClipReference)
        guard case .sequence(let nestedSequenceID) = compound.source else {
            return XCTFail("Make must select a sequence-backed compound replacement")
        }
        XCTAssertEqual(compound.name, "Compound Clip 1")
        let nested = try XCTUnwrap(model.project?.sequences.first { $0.id == nestedSequenceID })
        XCTAssertEqual(
            Set(TimelineInteraction.clipReferences(in: nested).map(\.clipID)),
            [original.videoClip.id, original.audioClip.id],
            "selecting linked video must pull its audio partner into the compound"
        )
        XCTAssertFalse(try XCTUnwrap(model.sequenceTabs.first { $0.id == nestedSequenceID }).canClose)

        let projectBeforeProtectedClose = model.project
        XCTAssertFalse(model.closeSequence(nestedSequenceID))
        XCTAssertEqual(model.project, projectBeforeProtectedClose)
        XCTAssertEqual(
            model.loadMessage,
            "This sequence is used by a compound clip. Decompose every instance before removing it."
        )

        XCTAssertTrue(model.canOpenCompoundClip)
        XCTAssertTrue(model.openCompoundClip())
        XCTAssertEqual(model.activeSequenceID, nestedSequenceID)
        XCTAssertFalse(model.canCloseActiveSequence)
        XCTAssertTrue(
            model.canInvokeCloseActiveSequenceCommand,
            "the menu command must consume Cmd-W while the nested sequence refuses removal"
        )
        let projectBeforeProtectedShortcut = model.project
        XCTAssertFalse(model.closeActiveSequence())
        XCTAssertEqual(model.project, projectBeforeProtectedShortcut)
        XCTAssertEqual(model.activeSequenceID, nestedSequenceID)
        let innerVideoTrack = try XCTUnwrap(model.activeSequence?.videoTracks.first)
        let innerVideo = try firstClip(in: innerVideoTrack)
        model.selectClip(trackID: innerVideoTrack.id, clipID: innerVideo.id, mode: .replace)
        XCTAssertTrue(model.addEffectToSelectedClip(kind: .gaussianBlur))

        XCTAssertTrue(model.selectSequence(parentSequenceID))
        XCTAssertEqual(model.selectedClipReference, compoundReference)
        guard case .sequence(let stillNestedID) = model.selectedClip?.source else {
            return XCTFail("parent compound selection should survive open/edit/return")
        }
        XCTAssertEqual(stillNestedID, nestedSequenceID)
        let editedNested = try XCTUnwrap(
            model.project?.sequences.first { $0.id == nestedSequenceID }
        )
        XCTAssertEqual(try firstClip(in: editedNested.videoTracks[0]).effectStack.nodes.count, 1)

        let undoBeforeDecompose = model.editHistory?.undoCount
        XCTAssertTrue(model.canDecomposeCompoundClip)
        XCTAssertTrue(model.decomposeCompoundClip())
        XCTAssertEqual(model.editHistory?.undoCount, (undoBeforeDecompose ?? 0) + 1)
        XCTAssertEqual(
            Set(model.timelineState.selectedClips.map(\.clipID)),
            [original.videoClip.id, original.audioClip.id]
        )
        for reference in model.timelineState.selectedClips {
            XCTAssertTrue(
                TimelineInteraction.clipReferences(in: try XCTUnwrap(model.activeSequence))
                    .contains(reference),
                "post-decompose selection may contain only clips that still exist"
            )
        }
        XCTAssertTrue(try XCTUnwrap(model.sequenceTabs.first { $0.id == nestedSequenceID }).canClose)

        model.undo()
        XCTAssertNotNil(
            model.activeSequence?.videoTracks.flatMap(\.items).compactMap { item -> Clip? in
                guard case .clip(let clip) = item,
                      case .sequence(let id) = clip.source,
                      id == nestedSequenceID
                else { return nil }
                return clip
            }.first
        )
        XCTAssertFalse(try XCTUnwrap(model.sequenceTabs.first { $0.id == nestedSequenceID }).canClose)

        model.redo()
        let existing = Set(TimelineInteraction.clipReferences(in: try XCTUnwrap(model.activeSequence)))
        XCTAssertTrue(model.timelineState.selectedClips.isSubset(of: existing))
    }

    func testFRCMP003WholeCompoundUsesTransformEffectSpeedAndKeyframeControls() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let linked = try sampleLinkedSelection(in: model)
        model.selectClip(trackID: linked.videoTrackID, clipID: linked.videoClip.id, mode: .replace)
        XCTAssertTrue(model.makeCompoundClip())
        let compoundReference = try XCTUnwrap(model.selectedClipReference)
        let nestedBefore = try XCTUnwrap(model.project?.sequences.last)

        XCTAssertEqual(model.selectedCanvasTransformLayout?.clipSize, model.project?.settings.resolution)
        XCTAssertTrue(model.updateSelectedTransformField(.positionX, rawValue: "12"))
        XCTAssertTrue(model.toggleSelectedTransformKeyframe(.position))
        XCTAssertTrue(model.addEffectToSelectedClip(kind: .gaussianBlur))
        XCTAssertTrue(model.updateSelectedClipSpeed(percentText: "200"))

        let outer = try XCTUnwrap(model.selectedClip)
        XCTAssertEqual(compoundReference, model.selectedClipReference)
        XCTAssertEqual(outer.transform.position.x, RationalValue(12))
        XCTAssertEqual(outer.transformAnimation.position.keyframes.count, 1)
        XCTAssertEqual(outer.effectStack.nodes.first?.kind, .gaussianBlur)
        XCTAssertEqual(outer.speed, RationalValue(2))
        XCTAssertEqual(
            model.project?.sequences.first { $0.id == nestedBefore.id },
            nestedBefore,
            "whole-compound controls must not rewrite nested contents"
        )

        let beforeRefusedDecompose = model.project
        XCTAssertFalse(model.decomposeCompoundClip())
        XCTAssertEqual(model.project, beforeRefusedDecompose)
        XCTAssertEqual(
            model.loadMessage,
            "Remove compound-level transforms, effects, keyframes, time remapping, reverse or freeze settings, audio adjustments, and nested track keyframes before decomposing."
        )
    }

    func testFRCMP001005NestedMakeUsesUniqueNamesAndProtectsEveryReferencedSequence() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let linked = try sampleLinkedSelection(in: model)
        model.selectClip(trackID: linked.videoTrackID, clipID: linked.videoClip.id, mode: .replace)
        XCTAssertTrue(model.makeCompoundClip())
        let firstNestedID = try XCTUnwrap(model.project?.sequences.last?.id)
        XCTAssertTrue(model.openCompoundClip())

        let innerVideoTrack = try XCTUnwrap(model.activeSequence?.videoTracks.first)
        let innerVideo = try firstClip(in: innerVideoTrack)
        model.selectClip(trackID: innerVideoTrack.id, clipID: innerVideo.id, mode: .replace)
        XCTAssertTrue(model.makeCompoundClip())
        let secondCompound = try XCTUnwrap(model.selectedClip)
        guard case .sequence(let secondNestedID) = secondCompound.source else {
            return XCTFail("nested make should produce another sequence reference")
        }
        XCTAssertEqual(secondCompound.name, "Compound Clip 2")
        XCTAssertEqual(model.activeSequenceID, firstNestedID)
        XCTAssertEqual(
            Set(model.project?.sequences.map(\.name) ?? []),
            ["Sample Playback Sequence", "Compound Clip 1", "Compound Clip 2"]
        )
        XCTAssertFalse(try XCTUnwrap(model.sequenceTabs.first { $0.id == firstNestedID }).canClose)
        XCTAssertFalse(try XCTUnwrap(model.sequenceTabs.first { $0.id == secondNestedID }).canClose)
        XCTAssertEqual(model.project?.validate(), .valid)
    }

    func testFRCMP001LockedLinkedTrackAndTextEditingRefuseWithoutMutation() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let linked = try sampleLinkedSelection(in: model)
        model.setTrackState(
            sequenceID: try XCTUnwrap(model.activeSequenceID),
            trackID: linked.audioTrackID,
            locked: true
        )
        model.selectClip(trackID: linked.videoTrackID, clipID: linked.videoClip.id, mode: .replace)
        let lockedProject = model.project
        let lockedUndoCount = model.editHistory?.undoCount
        XCTAssertFalse(model.canMakeCompoundClip)
        XCTAssertFalse(model.makeCompoundClip())
        XCTAssertEqual(model.project, lockedProject)
        XCTAssertEqual(model.editHistory?.undoCount, lockedUndoCount)
        XCTAssertEqual(
            model.loadMessage,
            "Unlock every selected or linked track before making a compound clip."
        )

        model.setTrackState(
            sequenceID: try XCTUnwrap(model.activeSequenceID),
            trackID: linked.audioTrackID,
            locked: false
        )
        let editorID = UUID()
        XCTAssertTrue(model.textEditorFocusChanged(id: editorID, isFocused: true))
        let textEditingProject = model.project
        XCTAssertFalse(model.makeCompoundClip())
        XCTAssertEqual(model.project, textEditingProject)
        XCTAssertEqual(model.loadMessage, "Finish editing text before making a compound clip.")
        XCTAssertTrue(model.textEditorFocusChanged(id: editorID, isFocused: false))

        XCTAssertTrue(model.detachAudioForSelectedClip())
        model.selectClip(trackID: linked.audioTrackID, clipID: linked.audioClip.id, mode: .replace)
        let audioOnlyProject = model.project
        XCTAssertFalse(model.canMakeCompoundClip)
        XCTAssertFalse(model.makeCompoundClip())
        XCTAssertEqual(model.project, audioOnlyProject)
        XCTAssertEqual(
            model.loadMessage,
            "Include at least one video clip in the compound selection."
        )
    }

    func testFRCMP001DestinationAndDuckingRefusalsAreAtomicAndLocalized() throws {
        let destinationFixture = try makeCompoundDestinationRefusalProject()
        let destinationModel = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        destinationModel.replaceProjectSessionForTesting(destinationFixture.project, documentURL: nil)
        destinationModel.selectClip(
            trackID: destinationFixture.first.trackID,
            clipID: destinationFixture.first.clipID,
            mode: .replace
        )
        destinationModel.selectClip(
            trackID: destinationFixture.second.trackID,
            clipID: destinationFixture.second.clipID,
            mode: .toggle
        )
        let destinationBefore = destinationModel.project
        let destinationUndo = destinationModel.editHistory?.undoCount
        XCTAssertTrue(destinationModel.canMakeCompoundClip)
        XCTAssertFalse(destinationModel.makeCompoundClip())
        XCTAssertEqual(destinationModel.project, destinationBefore)
        XCTAssertEqual(destinationModel.editHistory?.undoCount, destinationUndo)
        XCTAssertEqual(
            destinationModel.loadMessage,
            "The selection cannot be replaced without overlapping clips left outside it. Adjust the selection and try again."
        )

        let duckingFixture = try makeCompoundDuckingRefusalProject()
        let duckingModel = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        duckingModel.replaceProjectSessionForTesting(duckingFixture.project, documentURL: nil)
        duckingModel.selectClip(
            trackID: duckingFixture.video.trackID,
            clipID: duckingFixture.video.clipID,
            mode: .replace
        )
        duckingModel.selectClip(
            trackID: duckingFixture.trigger.trackID,
            clipID: duckingFixture.trigger.clipID,
            mode: .toggle
        )
        let duckingBefore = duckingModel.project
        let duckingUndo = duckingModel.editHistory?.undoCount
        XCTAssertTrue(duckingModel.canMakeCompoundClip)
        XCTAssertFalse(duckingModel.makeCompoundClip())
        XCTAssertEqual(duckingModel.project, duckingBefore)
        XCTAssertEqual(duckingModel.editHistory?.undoCount, duckingUndo)
        XCTAssertEqual(
            duckingModel.loadMessage,
            "The selection crosses an audio ducking boundary. Include every affected ducking track or change the ducking setup first."
        )
    }

    func testFRCMP004LockedOverlapAndDuckingRefusalsAreAtomicAndLocalized() throws {
        let lockedModel = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let linked = try sampleLinkedSelection(in: lockedModel)
        lockedModel.selectClip(
            trackID: linked.videoTrackID,
            clipID: linked.videoClip.id,
            mode: .replace
        )
        XCTAssertTrue(lockedModel.makeCompoundClip())
        let compoundReference = try XCTUnwrap(lockedModel.selectedClipReference)
        lockedModel.setTrackState(
            sequenceID: try XCTUnwrap(lockedModel.activeSequenceID),
            trackID: compoundReference.trackID,
            locked: true
        )
        let lockedBefore = lockedModel.project
        let lockedUndo = lockedModel.editHistory?.undoCount
        XCTAssertFalse(lockedModel.canDecomposeCompoundClip)
        XCTAssertFalse(lockedModel.decomposeCompoundClip())
        XCTAssertEqual(lockedModel.project, lockedBefore)
        XCTAssertEqual(lockedModel.editHistory?.undoCount, lockedUndo)
        XCTAssertEqual(
            lockedModel.loadMessage,
            "Unlock the compound clip's track before decomposing it."
        )

        let overlapFixture = try makeDecomposeOverlapRefusalProject()
        let overlapModel = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        overlapModel.replaceProjectSessionForTesting(overlapFixture.project, documentURL: nil)
        overlapModel.selectClip(
            trackID: overlapFixture.compound.trackID,
            clipID: overlapFixture.compound.clipID,
            mode: .replace
        )
        let overlapBefore = overlapModel.project
        let overlapUndo = overlapModel.editHistory?.undoCount
        XCTAssertTrue(overlapModel.canDecomposeCompoundClip)
        XCTAssertFalse(overlapModel.decomposeCompoundClip())
        XCTAssertEqual(overlapModel.project, overlapBefore)
        XCTAssertEqual(overlapModel.editHistory?.undoCount, overlapUndo)
        XCTAssertEqual(
            overlapModel.loadMessage,
            "The compound contents would overlap clips already on the parent timeline. Move those clips and try again."
        )

        let decomposeDuckingFixture = try makeDecomposeDuckingRefusalProject()
        let decomposeDuckingModel = EditorAjarAppModel(autosaveIntervalSeconds: 0)
        decomposeDuckingModel.replaceProjectSessionForTesting(
            decomposeDuckingFixture.project,
            documentURL: nil
        )
        decomposeDuckingModel.selectClip(
            trackID: decomposeDuckingFixture.compound.trackID,
            clipID: decomposeDuckingFixture.compound.clipID,
            mode: .replace
        )
        let decomposeDuckingBefore = decomposeDuckingModel.project
        let decomposeDuckingUndo = decomposeDuckingModel.editHistory?.undoCount
        XCTAssertTrue(decomposeDuckingModel.canDecomposeCompoundClip)
        XCTAssertFalse(decomposeDuckingModel.decomposeCompoundClip())
        XCTAssertEqual(decomposeDuckingModel.project, decomposeDuckingBefore)
        XCTAssertEqual(decomposeDuckingModel.editHistory?.undoCount, decomposeDuckingUndo)
        XCTAssertEqual(
            decomposeDuckingModel.loadMessage,
            "Decomposing would break an audio ducking relationship. Change the ducking setup first."
        )
    }

    func testFRTL010TimelineTimeMappingAndZoomClamps() {
        XCTAssertEqual(
            TimelineInteraction.xPosition(frame: 12, pixelsPerFrame: 4),
            48
        )
        XCTAssertEqual(
            TimelineInteraction.frame(atX: 49, pixelsPerFrame: 4, durationFrames: 20),
            12
        )
        XCTAssertEqual(
            TimelineInteraction.frame(atX: -25, pixelsPerFrame: 4, durationFrames: 20),
            0
        )
        XCTAssertEqual(
            TimelineInteraction.frame(atX: 200, pixelsPerFrame: 4, durationFrames: 20),
            19
        )
        XCTAssertEqual(
            TimelineInteraction.fittedPixelsPerFrame(durationFrames: 100, availableWidth: 500),
            5
        )
        XCTAssertEqual(
            TimelineInteraction.zoomedPixelsPerFrame(100, factor: 2),
            TimelineInteractionState.maximumPixelsPerFrame
        )
        XCTAssertEqual(
            TimelineInteraction.zoomedLaneHeight(10, factor: 0.5),
            TimelineInteractionState.minimumLaneHeight
        )
    }

    func testFRTL010TimelineClipLayoutsScaleTimelineItems() throws {
        let sequence = try makeInteractionSequence()
        let track = try XCTUnwrap(sequence.videoTracks.first)

        let layouts = TimelineInteraction.clipLayouts(
            for: track,
            frameRate: sequence.timebase,
            pixelsPerFrame: 2
        )

        XCTAssertEqual(layouts.count, 3)
        XCTAssertEqual(layouts[0].startFrame, 0)
        XCTAssertEqual(layouts[0].endFrame, 30)
        XCTAssertEqual(layouts[0].xPosition, 0)
        XCTAssertEqual(layouts[0].width, 60)
        XCTAssertEqual(layouts[1].startFrame, 45)
        XCTAssertEqual(layouts[1].width, 30)
    }

    func testFRTL007SelectionReducerSupportsReplaceToggleAndRange() throws {
        let sequence = try makeInteractionSequence()
        let references = TimelineInteraction.clipReferences(in: sequence)
        let first = try XCTUnwrap(references.first)
        let second = try XCTUnwrap(references.dropFirst().first)
        let third = try XCTUnwrap(references.dropFirst(2).first)

        let replaced = TimelineInteraction.reducedSelection(
            currentSelection: [],
            anchor: nil,
            visibleClipReferences: references,
            reference: first,
            mode: .replace
        )
        XCTAssertEqual(replaced.selectedClips, [first])
        XCTAssertEqual(replaced.anchor, first)

        let toggled = TimelineInteraction.reducedSelection(
            currentSelection: replaced.selectedClips,
            anchor: replaced.anchor,
            visibleClipReferences: references,
            reference: second,
            mode: .toggle
        )
        XCTAssertEqual(toggled.selectedClips, [first, second])

        let ranged = TimelineInteraction.reducedSelection(
            currentSelection: toggled.selectedClips,
            anchor: first,
            visibleClipReferences: references,
            reference: third,
            mode: .rangeOnTrack
        )
        XCTAssertEqual(ranged.selectedClips, [first, second, third])
        XCTAssertEqual(ranged.anchor, first)
    }

    func testFRTL006SnappingUsesPlayheadClipEdgesAndMarkers() throws {
        let sequence = try makeInteractionSequence()
        let targets = TimelineInteraction.snapTargets(in: sequence, playheadFrame: 10)

        XCTAssertEqual(
            TimelineInteraction.snappedFrame(
                proposedFrame: 11,
                targets: targets,
                toleranceFrames: 2
            ),
            10
        )
        XCTAssertEqual(
            TimelineInteraction.snappedFrame(
                proposedFrame: 31,
                targets: targets,
                toleranceFrames: 2
            ),
            30
        )
        XCTAssertEqual(
            TimelineInteraction.snappedFrame(
                proposedFrame: 59,
                targets: targets,
                toleranceFrames: 2
            ),
            60
        )
        XCTAssertEqual(
            TimelineInteraction.snappedFrame(
                proposedFrame: 25,
                targets: targets,
                toleranceFrames: 2
            ),
            25
        )
    }

    func testFRTL006FRTL007FRTL010AppTimelineInteractionState() throws {
        let model = EditorAjarAppModel(opensSampleProjectWhenNoRecovery: true)
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
        let clipLayout = try XCTUnwrap(model.timelineClipLayouts(for: videoTrack).first)

        XCTAssertTrue(model.timelineSnappingEnabled)
        model.selectClip(
            trackID: clipLayout.reference.trackID,
            clipID: clipLayout.reference.clipID,
            mode: .replace
        )
        XCTAssertTrue(model.isClipSelected(clipLayout.reference))
        XCTAssertEqual(model.timelineSelectedClipCount, 1)

        model.setTimelineRangeIn()
        model.scrubTimeline(xPosition: 16, snappingDisabled: true)
        model.setTimelineRangeOut()
        XCTAssertEqual(model.timelineRangeDescription, "Range 0-2")

        let initialPixelsPerFrame = model.timelineState.pixelsPerFrame
        model.zoomTimelineIn()
        XCTAssertGreaterThan(model.timelineState.pixelsPerFrame, initialPixelsPerFrame)
        model.fitTimeline(toWidth: 450)
        XCTAssertEqual(model.timelineContentWidth(minimumWidth: 450), 450)
        model.zoomTimelineToSelection(toWidth: 300)
        XCTAssertGreaterThan(model.timelineState.pixelsPerFrame, 1)

        model.setTimelineSnappingEnabled(false)
        XCTAssertFalse(model.timelineSnappingEnabled)
    }

    func testFRTL009AppLinkedMoveAndMomentaryUnlinkRouteThroughEditHistory() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let selection = try sampleLinkedSelection(in: model)

        XCTAssertEqual(selection.videoClip.linkGroupID, selection.audioClip.linkGroupID)
        model.selectClip(
            trackID: selection.videoTrackID,
            clipID: selection.videoClip.id,
            mode: .replace
        )
        XCTAssertTrue(model.selectedClipIsLinked)

        XCTAssertTrue(model.moveSelectedClip(toStartFrame: 12, linkedClipEditMode: .linked))
        let linkedMoveSelection = try sampleLinkedSelection(in: model)
        try assertFrameRange(
            linkedMoveSelection.videoClip.timelineRange,
            startFrame: 12,
            durationFrames: 90,
            frameRate: linkedMoveSelection.frameRate
        )
        try assertFrameRange(
            linkedMoveSelection.audioClip.timelineRange,
            startFrame: 12,
            durationFrames: 90,
            frameRate: linkedMoveSelection.frameRate
        )

        model.undo()
        XCTAssertTrue(model.moveSelectedClip(toStartFrame: 12, linkedClipEditMode: .unlinked))
        let unlinkedMoveSelection = try sampleLinkedSelection(in: model)
        try assertFrameRange(
            unlinkedMoveSelection.videoClip.timelineRange,
            startFrame: 12,
            durationFrames: 90,
            frameRate: unlinkedMoveSelection.frameRate
        )
        try assertFrameRange(
            unlinkedMoveSelection.audioClip.timelineRange,
            startFrame: 0,
            durationFrames: 90,
            frameRate: unlinkedMoveSelection.frameRate
        )
    }

    func testIssue240TimelineFocusGatesClipboardAndDelete() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0, opensSampleProjectWhenNoRecovery: true)
        let selection = try sampleLinkedSelection(in: model)
        model.selectClip(trackID: selection.videoTrackID, clipID: selection.videoClip.id, mode: .replace)

        XCTAssertFalse(model.copyTimelineClips())
        XCTAssertFalse(model.liftSelection())
        model.focusTimeline()
        XCTAssertTrue(model.copyTimelineClips())
        model.blurTimeline()
        XCTAssertFalse(model.pasteTimelineClips())
    }

    func testIssue240CommandClickToggleAndSelectForward() throws {
        let model = EditorAjarAppModel(opensSampleProjectWhenNoRecovery: true)
        let sequence = try XCTUnwrap(model.activeSequence)
        let references = TimelineInteraction.clipReferences(in: sequence)
        let first = try XCTUnwrap(references.first)
        model.selectClip(trackID: first.trackID, clipID: first.clipID, mode: .toggle)
        XCTAssertTrue(model.isClipSelected(first))
        model.selectClip(trackID: first.trackID, clipID: first.clipID, mode: .toggle)
        XCTAssertFalse(model.isClipSelected(first))

        model.scrub(to: 0)
        model.selectForwardFromPlayhead()
        XCTAssertEqual(model.timelineSelectedClipCount, references.count)
    }

    func testIssue240BladeAtPlayheadIsOneUndoableEdit() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0, opensSampleProjectWhenNoRecovery: true)
        let selection = try sampleLinkedSelection(in: model)
        model.selectClip(trackID: selection.videoTrackID, clipID: selection.videoClip.id, mode: .replace)
        model.scrub(to: 20)
        let before = model.project
        XCTAssertTrue(model.bladeSelectedClipAtPlayhead())
        XCTAssertNotEqual(model.project, before)
        model.undo()
        XCTAssertEqual(model.project, before)
    }

    func testIssue240AddAndRemoveEmptyTrack() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0, opensSampleProjectWhenNoRecovery: true)
        let before = try XCTUnwrap(model.activeSequence).videoTracks.count
        XCTAssertTrue(model.addTrack(kind: .video))
        let track = try XCTUnwrap(model.activeSequence?.videoTracks.last)
        XCTAssertEqual(model.activeSequence?.videoTracks.count, before + 1)
        model.selectTimelineTrack(track.id)
        XCTAssertTrue(model.removeSelectedEmptyTrack())
        XCTAssertEqual(model.activeSequence?.videoTracks.count, before)
    }

    func testIssue240SnapTargetsIncludePlayheadAndTransformKeyframes() throws {
        let model = EditorAjarAppModel(opensSampleProjectWhenNoRecovery: true)
        let sequence = try XCTUnwrap(model.activeSequence)
        let targets = TimelineInteraction.snapTargets(in: sequence, playheadFrame: 17)
        XCTAssertTrue(targets.contains { $0.frame == 17 && $0.kind == .playhead })

        // A transform keyframe becomes a snap target so scrubbing/dragging snaps to it (FR-TL-006).
        try selectSampleVideoClip(in: model)
        model.scrub(to: 17)
        XCTAssertTrue(model.addSelectedTransformKeyframe(parameter: .position, atFrame: 17))
        model.scrub(to: 0)
        let keyframeTargets = TimelineInteraction.snapTargets(
            in: try XCTUnwrap(model.activeSequence), playheadFrame: 0
        )
        XCTAssertTrue(keyframeTargets.contains { target in
            guard case .keyframe = target.kind else { return false }
            return target.frame == 17
        })

        XCTAssertEqual(model.snappedTimelineFrame(16, momentarilyDisabled: false), 17)
        XCTAssertEqual(model.snappedTimelineFrame(16, momentarilyDisabled: true), 16)
    }

    func testFRTL009AppTrimAndDetachAudioRouteThroughEditHistory() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let selection = try sampleLinkedSelection(in: model)

        model.selectClip(
            trackID: selection.videoTrackID,
            clipID: selection.videoClip.id,
            mode: .replace
        )
        XCTAssertTrue(
            model.trimSelectedClip(
                sourceStartFrame: 4,
                timelineStartFrame: 4,
                durationFrames: 70,
                linkedClipEditMode: .linked
            )
        )
        let trimmedSelection = try sampleLinkedSelection(in: model)
        try assertFrameRange(
            trimmedSelection.videoClip.sourceRange,
            startFrame: 4,
            durationFrames: 70,
            frameRate: trimmedSelection.frameRate
        )
        try assertFrameRange(
            trimmedSelection.audioClip.sourceRange,
            startFrame: 4,
            durationFrames: 70,
            frameRate: trimmedSelection.frameRate
        )

        XCTAssertTrue(model.detachAudioForSelectedClip())
        let detachedSelection = try sampleLinkedSelection(in: model)
        XCTAssertNil(detachedSelection.videoClip.linkGroupID)
        XCTAssertNil(detachedSelection.audioClip.linkGroupID)

        model.undo()
        let relinkedSelection = try sampleLinkedSelection(in: model)
        XCTAssertEqual(relinkedSelection.videoClip.linkGroupID, selection.videoClip.linkGroupID)
        XCTAssertEqual(relinkedSelection.audioClip.linkGroupID, selection.audioClip.linkGroupID)
    }

    func testFRTL008AppMarkerActionsRouteThroughEditHistoryAndUndo() throws {
        let model = EditorAjarAppModel(opensSampleProjectWhenNoRecovery: true)
        let initialMarkerCount = model.activeSequence?.markers.count ?? 0

        model.scrub(to: 12)
        model.addTimelineMarkerAtPlayhead()

        let addedMarker = try XCTUnwrap(model.selectedMarker)
        XCTAssertEqual(model.activeSequence?.markers.count, initialMarkerCount + 1)
        XCTAssertEqual(
            try addedMarker.time.frameIndex(
                at: try XCTUnwrap(model.activeSequence?.timebase),
                rounding: .nearestOrAwayFromZero
            ),
            12
        )
        XCTAssertTrue(model.canUndo)

        model.updateSelectedMarker(
            name: "Scene beat",
            color: .green,
            note: "Check the cut before export"
        )

        let updatedMarker = try XCTUnwrap(model.selectedMarker)
        XCTAssertEqual(updatedMarker.name, "Scene beat")
        XCTAssertEqual(updatedMarker.color, .green)
        XCTAssertEqual(updatedMarker.note, "Check the cut before export")
        XCTAssertEqual(model.timelineMarkerLayouts().first?.name, "Scene beat")

        model.deleteSelectedMarker()
        XCTAssertNil(model.selectedMarker)
        XCTAssertEqual(model.activeSequence?.markers.count, initialMarkerCount)

        model.undo()
        XCTAssertEqual(model.activeSequence?.markers.count, initialMarkerCount + 1)
        XCTAssertEqual(model.activeSequence?.markers.first?.name, "Scene beat")
    }

    func testFRPLAY002AppJumpsBetweenMarkers() throws {
        let model = EditorAjarAppModel(opensSampleProjectWhenNoRecovery: true)

        model.scrub(to: 10)
        model.addTimelineMarkerAtPlayhead()
        let firstMarker = try XCTUnwrap(model.selectedMarker)
        model.updateSelectedMarker(name: "First marker")

        model.scrub(to: 24)
        model.addTimelineMarkerAtPlayhead()
        let secondMarker = try XCTUnwrap(model.selectedMarker)
        model.updateSelectedMarker(name: "Second marker")

        model.scrub(to: 0)
        model.jumpToNextMarker()
        XCTAssertEqual(model.playheadFrame, 10)
        XCTAssertEqual(model.selectedMarker?.id, firstMarker.id)

        model.jumpToNextMarker()
        XCTAssertEqual(model.playheadFrame, 24)
        XCTAssertEqual(model.selectedMarker?.id, secondMarker.id)

        model.jumpToPreviousMarker()
        XCTAssertEqual(model.playheadFrame, 10)
        XCTAssertEqual(model.selectedMarker?.id, firstMarker.id)
    }

    func testFRXFORM007TransformInspectorFieldsRouteThroughEditHistoryAndUndo() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)
        let originalProject = try XCTUnwrap(model.project)

        XCTAssertEqual(model.transformFieldValue(.positionX), "0")
        XCTAssertTrue(model.updateSelectedTransformField(.positionX, rawValue: "12.5"))

        let editedTransform = try XCTUnwrap(model.selectedTransformInspector?.transform)
        XCTAssertEqual(editedTransform.position.x.doubleValue, 12.5, accuracy: 0.000_001)
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Clip Transform")

        model.undo()

        XCTAssertEqual(model.project, originalProject)
        XCTAssertEqual(model.transformFieldValue(.positionX), "0")
    }

    func testFRXFORM007BlendFlipAndCanvasGestureRouteThroughEditHistory() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)

        XCTAssertTrue(model.updateSelectedClipBlendMode(.screen))
        XCTAssertEqual(model.selectedTransformInspector?.transform.blendMode, .screen)

        XCTAssertTrue(model.updateSelectedClipFlip(horizontal: true))
        XCTAssertEqual(model.selectedTransformInspector?.transform.flip.horizontal, true)

        XCTAssertTrue(
            model.applyCanvasTransformGesture(
                CanvasTransformGesture(
                    handle: .move,
                    translationX: 20,
                    translationY: 10,
                    canvasScale: 2
                )
            )
        )
        let movedTransform = try XCTUnwrap(model.selectedTransformInspector?.transform)
        XCTAssertEqual(movedTransform.position.x.doubleValue, 10, accuracy: 0.000_001)
        XCTAssertEqual(movedTransform.position.y.doubleValue, 5, accuracy: 0.000_001)
        XCTAssertTrue(model.canUndo)
    }

    func testFRCOL007AppCopiesAndPastesGradeThroughUndoableHistory() throws {
        let fixture = try makeGradeAppFixture()
        let loaded = try loadGradeAppModel(project: fixture.project, named: "CopyPasteGrade.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model

        XCTAssertFalse(model.canCopyGrade)
        XCTAssertFalse(model.canPasteGrade)
        model.selectClip(
            trackID: fixture.source.trackID,
            clipID: fixture.source.clipID,
            mode: .replace
        )

        XCTAssertTrue(model.canCopyGrade)
        XCTAssertTrue(model.copyGradeFromSelectedClip())
        XCTAssertEqual(model.copiedGradeSource, fixture.source)

        model.selectClip(
            trackID: fixture.target.trackID,
            clipID: fixture.target.clipID,
            mode: .replace
        )
        XCTAssertTrue(model.canPasteGrade)
        XCTAssertTrue(model.pasteGradeToSelectedClip())
        XCTAssertEqual(model.undoMenuTitle, "Undo Copy Grade")

        let source = try projectClip(fixture.source, in: XCTUnwrap(model.project))
        let pasted = try projectClip(fixture.target, in: XCTUnwrap(model.project))
        XCTAssertEqual(
            pasted.effectStack.grade.nodes.map(\.definition),
            source.effectStack.grade.nodes.map(\.definition)
        )
        XCTAssertNotEqual(
            pasted.effectStack.grade.nodes.map(\.id),
            source.effectStack.grade.nodes.map(\.id)
        )
        let pastedIDs = pasted.effectStack.grade.nodes.map(\.id)

        model.undo()
        XCTAssertTrue(
            try projectClip(fixture.target, in: XCTUnwrap(model.project))
                .effectStack.grade.nodes.isEmpty
        )

        model.redo()
        XCTAssertEqual(
            try projectClip(fixture.target, in: XCTUnwrap(model.project))
                .effectStack.grade.nodes.map(\.id),
            pastedIDs
        )
    }

    func testFRCOL007AppSavesUniqueLookAndAppliesItToSelectedClip() throws {
        let fixture = try makeGradeAppFixture()
        let existingLook = ProjectLook(
            id: try appTestUUID("00000000-0000-0000-0000-000000007104"),
            name: " look 1 ",
            grade: ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: try appTestUUID("00000000-0000-0000-0000-000000007105"),
                        definition: .invert(.identity)
                    )
                ]
            )
        )
        let project = Project(
            schemaVersion: fixture.project.schemaVersion,
            schemaMinor: fixture.project.schemaMinor,
            settings: fixture.project.settings,
            mediaPool: fixture.project.mediaPool,
            sequences: fixture.project.sequences,
            looks: [existingLook]
        )
        let loaded = try loadGradeAppModel(project: project, named: "SaveApplyLook.ajar")
        defer { try? FileManager.default.removeItem(at: loaded.packageDirectory) }
        let model = loaded.model

        model.selectClip(
            trackID: fixture.source.trackID,
            clipID: fixture.source.clipID,
            mode: .replace
        )
        XCTAssertTrue(model.canSaveLook)
        XCTAssertTrue(model.saveLookFromSelectedClip())
        XCTAssertTrue(model.isSaveLookSheetPresented)
        XCTAssertEqual(model.saveLookDraftName, "Look 2")
        model.updateSaveLookDraftName("Warm Grade")
        XCTAssertTrue(model.confirmSaveLookFromSelectedClip())
        XCTAssertFalse(model.isSaveLookSheetPresented)
        XCTAssertEqual(model.savedLooks.map(\.name), [" look 1 ", "Warm Grade"])
        XCTAssertEqual(model.undoMenuTitle, "Undo Save Look")
        let savedLook = try XCTUnwrap(model.savedLooks.last)

        model.selectClip(
            trackID: fixture.target.trackID,
            clipID: fixture.target.clipID,
            mode: .replace
        )
        XCTAssertTrue(model.canApplyLook)
        XCTAssertTrue(model.applyLookToSelectedClip(lookID: savedLook.id))
        XCTAssertEqual(model.undoMenuTitle, "Undo Apply Look")

        let applied = try projectClip(fixture.target, in: XCTUnwrap(model.project))
        XCTAssertEqual(
            applied.effectStack.grade.nodes.map(\.definition),
            savedLook.grade.nodes.map(\.definition)
        )
        XCTAssertNotEqual(
            applied.effectStack.grade.nodes.map(\.id),
            savedLook.grade.nodes.map(\.id)
        )

        model.undo()
        XCTAssertTrue(
            try projectClip(fixture.target, in: XCTUnwrap(model.project))
                .effectStack.grade.nodes.isEmpty
        )
        model.undo()
        XCTAssertEqual(model.savedLooks, [existingLook])
    }

    func testFRCOMP006TrackCompositingInspectorRoutesThroughEditHistoryAndUndo() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )

        XCTAssertNil(model.selectedTrackCompositingInspector)
        XCTAssertFalse(model.updateSelectedTrackOpacityPercent(rawValue: "45"))
        XCTAssertFalse(model.updateSelectedTrackBlendMode(.difference))

        try selectSampleVideoClip(in: model)
        let originalProject = try XCTUnwrap(model.project)

        XCTAssertEqual(model.selectedTrackCompositingInspector?.trackName, "Video track 1")
        XCTAssertEqual(model.selectedTrackCompositingInspector?.blendMode, .normal)
        XCTAssertEqual(model.selectedTrackOpacityPercentValue(), "100")

        XCTAssertTrue(model.updateSelectedTrackOpacityPercent(rawValue: "45"))
        let editedOpacity = try XCTUnwrap(model.selectedTrackCompositingInspector?.opacity)
        XCTAssertEqual(
            editedOpacity.doubleValue,
            0.45,
            accuracy: 0.000_001
        )
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Track Compositing")

        model.undo()

        XCTAssertEqual(model.project, originalProject)
        XCTAssertEqual(model.selectedTrackOpacityPercentValue(), "100")

        XCTAssertTrue(model.updateSelectedTrackBlendMode(.difference))
        XCTAssertEqual(model.selectedTrackCompositingInspector?.blendMode, .difference)
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Track Compositing")

        model.undo()

        XCTAssertEqual(model.project, originalProject)
        XCTAssertEqual(model.selectedTrackCompositingInspector?.blendMode, .normal)
    }

    func testFRKEY005TransformKeyframeToggleLaneMoveAndDeleteRouteThroughEditHistory() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        try selectSampleVideoClip(in: model)
        model.scrub(to: 10)
        let selectedTransformReference = try XCTUnwrap(model.selectedTransformClipReference)

        XCTAssertFalse(model.selectedTransformHasKeyframe(.position))
        XCTAssertTrue(model.toggleSelectedTransformKeyframe(.position))
        XCTAssertTrue(model.selectedTransformHasKeyframe(.position))
        XCTAssertEqual(model.selectedTransformClipReference, selectedTransformReference)
        XCTAssertEqual(
            model.selectedTransformKeyframeLanes.filter { !$0.keyframes.isEmpty }.map(\.parameter),
            [.position]
        )
        XCTAssertEqual(try positionLane(in: model).keyframes.map(\.frame), [10])
        XCTAssertEqual(model.undoMenuTitle, "Undo Add Transform Keyframe")

        XCTAssertTrue(model.moveSelectedTransformKeyframe(parameter: .position, fromFrame: 10, toFrame: 12))
        XCTAssertEqual(try positionLane(in: model).keyframes.map(\.frame), [12])

        XCTAssertTrue(model.deleteSelectedTransformKeyframe(parameter: .position, atFrame: 12))
        XCTAssertEqual(try positionLane(in: model).keyframes, [])

        model.undo()

        XCTAssertEqual(try positionLane(in: model).keyframes.map(\.frame), [12])
    }

    func testFRXFORM007PureTransformFieldAndGestureMappingHelpers() throws {
        let transform = ClipTransform(
            position: CanvasPoint(x: RationalValue(1), y: RationalValue(2)),
            scale: .identity
        )

        let updatedScale = try XCTUnwrap(
            TransformFieldValueMapper.updatedTransform(
                .scaleXPercent,
                rawValue: "125",
                in: transform
            )
        )
        XCTAssertEqual(updatedScale.scale.x.doubleValue, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(
            TransformFieldValueMapper.stringValue(for: .scaleXPercent, in: updatedScale),
            "125"
        )

        let moved = CanvasTransformGestureMapper.updatedTransform(
            from: transform,
            gesture: CanvasTransformGesture(
                handle: .move,
                translationX: 8,
                translationY: -4,
                canvasScale: 2
            ),
            clipSize: PixelDimensions(width: 100, height: 50)
        )
        XCTAssertEqual(moved.position.x.doubleValue, 5, accuracy: 0.000_001)
        XCTAssertEqual(moved.position.y.doubleValue, 0, accuracy: 0.000_001)

        let scaled = CanvasTransformGestureMapper.updatedTransform(
            from: transform,
            gesture: CanvasTransformGesture(
                handle: .scaleBottomRight,
                translationX: 50,
                translationY: 25,
                canvasScale: 1
            ),
            clipSize: PixelDimensions(width: 100, height: 50)
        )
        XCTAssertEqual(scaled.scale.x.doubleValue, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(scaled.scale.y.doubleValue, 1.5, accuracy: 0.000_001)
    }

    func testFRTXT003CanvasTitleTextEditingIsLiveAndOneUndoStep() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let originalProject = try XCTUnwrap(model.project)
        let firstLayout = try XCTUnwrap(model.visibleCanvasTitleBoxes.first)

        XCTAssertEqual(model.visibleCanvasTitleBoxes.count, 2)
        XCTAssertTrue(model.beginCanvasTitleTextEditing(firstLayout.reference))
        XCTAssertTrue(model.updateCanvasTitleText("Canvas", reference: firstLayout.reference))
        XCTAssertTrue(
            model.updateCanvasTitleText("Canvas edited", reference: firstLayout.reference)
        )
        XCTAssertEqual(
            model.visibleCanvasTitleBoxes.first { $0.reference == firstLayout.reference }?.box.text,
            "Canvas edited"
        )
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Title Text Box")

        model.endCanvasTitleTextEditing()
        model.undo()

        XCTAssertEqual(model.project, originalProject)
        XCTAssertEqual(
            model.visibleCanvasTitleBoxes.first { $0.reference == firstLayout.reference }?.box.text,
            "Edit me"
        )
    }

    func testFRTXT003CanvasTitleDragSnapsAndArrowKeysNudge() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let firstLayout = try XCTUnwrap(model.visibleCanvasTitleBoxes.first)
        let actionSafeOrigin = CanvasTitlePositioning.draggedOrigin(
            for: firstLayout,
            translationX: -55,
            translationY: -41,
            canvasScale: 1
        )
        XCTAssertEqual(actionSafeOrigin.x.doubleValue, 16, accuracy: 0.000_001)
        XCTAssertEqual(actionSafeOrigin.y.doubleValue, 9, accuracy: 0.000_001)

        XCTAssertTrue(
            model.dragCanvasTitleBox(
                firstLayout.reference,
                translationX: -36,
                translationY: -30,
                canvasScale: 1
            )
        )
        let snapped = try XCTUnwrap(
            model.visibleCanvasTitleBoxes.first { $0.reference == firstLayout.reference }
        )
        XCTAssertEqual(snapped.box.origin.x.doubleValue, 32, accuracy: 0.000_001)
        XCTAssertEqual(snapped.box.origin.y.doubleValue, 18, accuracy: 0.000_001)

        XCTAssertTrue(
            model.dragCanvasTitleBox(
                firstLayout.reference,
                translationX: 35,
                translationY: 0,
                canvasScale: 1
            )
        )
        let centered = try XCTUnwrap(
            model.visibleCanvasTitleBoxes.first { $0.reference == firstLayout.reference }
        )
        XCTAssertEqual(centered.box.origin.x.doubleValue, 70, accuracy: 0.000_001)
        XCTAssertEqual(centered.box.origin.y.doubleValue, 18, accuracy: 0.000_001)

        XCTAssertTrue(
            model.nudgeCanvasTitleBox(
                firstLayout.reference,
                direction: .right,
                largeStep: true
            )
        )
        let nudged = try XCTUnwrap(
            model.visibleCanvasTitleBoxes.first { $0.reference == firstLayout.reference }
        )
        XCTAssertEqual(nudged.box.origin.x.doubleValue, 80, accuracy: 0.000_001)
        XCTAssertEqual(nudged.box.origin.y.doubleValue, 18, accuracy: 0.000_001)
        XCTAssertEqual(model.undoMenuTitle, "Undo Set Title Text Box")
    }

    func testFRTXT003TabMovesEditingToTheNextCanvasTitleBox() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let layouts = model.visibleCanvasTitleBoxes
        XCTAssertEqual(layouts.count, 2)
        let first = try XCTUnwrap(layouts.first)
        let second = try XCTUnwrap(layouts.last)

        XCTAssertTrue(model.beginCanvasTitleTextEditing(first.reference))
        XCTAssertEqual(
            model.editAdjacentCanvasTitleBox(from: first.reference, reverse: false),
            second.reference
        )
        XCTAssertEqual(model.editingCanvasTitleBoxReference, second.reference)
        XCTAssertEqual(
            model.editAdjacentCanvasTitleBox(from: second.reference, reverse: true),
            first.reference
        )
    }

    func testFRTXT003StaleEndCommitDoesNotClobberOtherBoxEditSession() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let layouts = model.visibleCanvasTitleBoxes
        XCTAssertEqual(layouts.count, 2)
        let first = try XCTUnwrap(layouts.first)
        let second = try XCTUnwrap(layouts.last)

        XCTAssertTrue(model.beginCanvasTitleTextEditing(first.reference))
        XCTAssertEqual(model.editingCanvasTitleBoxReference, first.reference)

        // Direct click-to-other-box: B starts while A's textDidEndEditing is still pending.
        XCTAssertTrue(model.beginCanvasTitleTextEditing(second.reference))
        XCTAssertEqual(model.editingCanvasTitleBoxReference, second.reference)

        // Late commit from A must be a no-op (reference-scoped teardown).
        model.endCanvasTitleTextEditing(for: first.reference)
        XCTAssertEqual(model.editingCanvasTitleBoxReference, second.reference)

        // Matching commit still ends the active session.
        model.endCanvasTitleTextEditing(for: second.reference)
        XCTAssertNil(model.editingCanvasTitleBoxReference)
    }

    func testFRTXT003SafeAreaGuidesNeverEnterProjectOrRenderedOutput() throws {
        let model = EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let project = try XCTUnwrap(model.project)
        let sequence = try XCTUnwrap(model.activeSequence)
        let graphBefore = try buildRenderGraph(for: sequence, at: .zero, in: project)
        let outputHashBefore = try XCTUnwrap(graphBefore.outputNode?.contentHash)

        model.toggleCanvasSafeAreaGuides()

        XCTAssertTrue(model.canvasSafeAreaGuidesVisible)
        XCTAssertEqual(model.project, project)
        let projectAfter = try XCTUnwrap(model.project)
        let sequenceAfter = try XCTUnwrap(model.activeSequence)
        let graphAfter = try buildRenderGraph(
            for: sequenceAfter,
            at: .zero,
            in: projectAfter
        )
        XCTAssertEqual(graphAfter, graphBefore)
        XCTAssertEqual(graphAfter.outputNode?.contentHash, outputHashBefore)
    }

    func testFRTL014NFRSTAB002AppLaunchRecoversAutosavePackage() throws {
        let packageURL = try temporaryAutosavePackageURL(named: "LaunchRecovery.ajar")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        let sampleProject = try EditorAjarAppModel.makeSampleProject().get()
        let command = try autosaveTrackStateCommand(project: sampleProject)
        let recoveredProject = try apply(command, to: sampleProject)
        try AjarAutosaveStore.writeSnapshot(
            sampleProject,
            appliedCommandCount: 0,
            openMode: .editable,
            to: packageURL
        )
        try AjarAutosaveStore.appendJournalEntry(
            command: command,
            sequenceNumber: 1,
            to: packageURL
        )

        let model = EditorAjarAppModel(
            autosavePackageURL: packageURL,
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )

        XCTAssertEqual(model.project, recoveredProject)
        XCTAssertTrue(model.isProjectEditable)
        XCTAssertFalse(model.isReadOnlyBannerVisible)
        XCTAssertTrue(model.canSaveProject)
    }

    /// Higher-minor recovery opens read-only: banner, save gated, edit refusal once (#196).
    func testFRPROJ005Issue196ReadOnlyOpenSurfacesBannerAndGatesSaveAndEdits() async throws {
        let packageURL = try temporaryAutosavePackageURL(named: "ReadOnlyOpen.ajar")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        let sampleProject = try EditorAjarAppModel.makeSampleProject().get()
        let higherMinor = AjarProjectCodec.currentSchemaMinor + 3
        let reason = AjarProjectReadOnlyReason.newerSchemaMinor(
            found: higherMinor,
            supported: AjarProjectCodec.currentSchemaMinor
        )
        try writeHigherMinorPackage(
            project: sampleProject,
            schemaMinor: higherMinor,
            to: packageURL
        )

        let model = EditorAjarAppModel(
            autosavePackageURL: packageURL,
            autosaveIntervalSeconds: 0
        )

        XCTAssertEqual(model.project?.schemaMinor, higherMinor)
        XCTAssertTrue(model.isProjectReadOnly)
        XCTAssertFalse(model.isProjectEditable)
        XCTAssertEqual(model.projectOpenMode, .readOnly(reason: reason))
        XCTAssertEqual(model.projectReadOnlyReason, reason)
        XCTAssertTrue(model.isReadOnlyBannerVisible)
        XCTAssertEqual(model.readOnlyBannerMessage, reason.message)
        XCTAssertFalse(model.canSaveProject)
        // loadMessage is set to "… (read-only)" during recovery, then immediately overwritten
        // by requestRenderForCurrentFrame() ("Rendering frame …") or Metal setup failure
        // before init returns — so it is not a stable post-init surface. The durable
        // FR-PROJ-005 copy is the banner (asserted above); first edit refusal reasserts
        // reason.message on loadMessage below.

        let sequence = try XCTUnwrap(model.activeSequence)
        let track = try XCTUnwrap(sequence.videoTracks.first)
        let projectBefore = try XCTUnwrap(model.project)

        // First edit refusal surfaces the typed reason once.
        model.setTrackState(
            sequenceID: sequence.id,
            trackID: track.id,
            enabled: false,
            locked: true,
            hidden: true
        )
        XCTAssertEqual(model.project, projectBefore)
        XCTAssertEqual(model.loadMessage, reason.message)
        XCTAssertTrue(model.isReadOnlyBannerVisible)

        // Subsequent edits stay no-ops without spamming loadMessage changes.
        let messageAfterFirstRefusal = model.loadMessage
        model.setTrackState(
            sequenceID: sequence.id,
            trackID: track.id,
            enabled: true,
            locked: false,
            hidden: false
        )
        XCTAssertEqual(model.loadMessage, messageAfterFirstRefusal)
        XCTAssertEqual(model.project, projectBefore)

        let videoClip = try firstClip(in: track)
        model.selectClip(trackID: track.id, clipID: videoClip.id, mode: .replace)
        XCTAssertFalse(model.canMakeCompoundClip)
        XCTAssertFalse(model.makeCompoundClip())
        XCTAssertEqual(model.project, projectBefore)
        XCTAssertEqual(model.loadMessage, reason.message)

        // Autosave must not rewrite a higher-minor package.
        await model.autosaveCheckpointForTesting()
        let reloaded = try AjarAutosaveStore.recoverProject(from: packageURL)
        XCTAssertEqual(reloaded.openMode, .readOnly(reason: reason))
        XCTAssertEqual(reloaded.project.schemaMinor, higherMinor)
        XCTAssertEqual(reloaded.project, projectBefore)

        model.dismissReadOnlyBanner()
        XCTAssertFalse(model.isReadOnlyBannerVisible)
        XCTAssertNil(model.readOnlyBannerMessage)

        // A later edit re-presents the banner without changing the one-shot loadMessage.
        model.setTrackState(
            sequenceID: sequence.id,
            trackID: track.id,
            enabled: false,
            locked: false,
            hidden: false
        )
        XCTAssertTrue(model.isReadOnlyBannerVisible)
        XCTAssertEqual(model.loadMessage, messageAfterFirstRefusal)
    }

    func testFRTL014AppAutosavesSignificantEditToRecoverablePackage() async throws {
        let packageURL = try temporaryAutosavePackageURL(named: "EditAutosave.ajar")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        let model = EditorAjarAppModel(
            autosavePackageURL: packageURL,
            autosaveIntervalSeconds: 0,
            opensSampleProjectWhenNoRecovery: true
        )
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)

        model.setTrackState(
            sequenceID: sequence.id,
            trackID: videoTrack.id,
            enabled: false,
            locked: true,
            hidden: true
        )
        await model.autosaveCheckpointForTesting()

        let recovered = try AjarAutosaveStore.recoverProject(from: packageURL)
        XCTAssertTrue(recovered.isComplete)
        XCTAssertEqual(recovered.latestCommandCount, 1)
        XCTAssertEqual(recovered.project, model.project)
    }

    // MARK: - #240 timeline gesture closures (blade pointer, multi-move, groups, three-point)

    /// Blade tool splits at the pointer position, not the playhead (FR-TL-004, #240).
    func testIssue240BladeToolSplitsAtPointerNotPlayhead() throws {
        let fixture = try makeControlledTimelineProject(videoStarts: [0], durationFrames: 90)
        let model = try makeModel(loading: fixture.project)
        let reference = try XCTUnwrap(model.timelineClipLayouts(for: firstVideoTrack(model)).first).reference
        model.focusTimeline()
        model.scrub(to: 5)
        let pixelsPerFrame = model.timelineState.pixelsPerFrame
        let before = model.project

        XCTAssertTrue(model.bladeClip(reference: reference, atTimelineX: 20 * pixelsPerFrame))

        let clips = videoClips(model)
        XCTAssertEqual(clips.count, 2)
        let left = try XCTUnwrap(clips.first)
        let right = try XCTUnwrap(clips.last)
        try assertFrameRange(left.timelineRange, startFrame: 0, durationFrames: 20, frameRate: fixture.frameRate)
        try assertFrameRange(right.timelineRange, startFrame: 20, durationFrames: 70, frameRate: fixture.frameRate)

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    /// A linked A/V blade splits video and its audio together in exactly one undo step (FR-TL-009).
    func testIssue240LinkedAVBladeIsSingleUndoStep() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0, opensSampleProjectWhenNoRecovery: true)
        let selection = try sampleLinkedSelection(in: model)
        let reference = TimelineClipReference(
            trackID: selection.videoTrackID, clipID: selection.videoClip.id
        )
        let before = model.project

        XCTAssertTrue(model.bladeClip(reference: reference, atFrame: 30))

        let sequence = try XCTUnwrap(model.activeSequence)
        XCTAssertEqual(sequence.videoTracks[0].items.count, 2)
        XCTAssertEqual(sequence.audioTracks[0].items.count, 2)

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    /// Multi-selection move shifts the whole selection, with linked partners following, in one step.
    func testIssue240MultiSelectionMoveMovesWholeSelectionLinkedInOneStep() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0, opensSampleProjectWhenNoRecovery: true)
        let sequence = try XCTUnwrap(model.activeSequence)
        let frameRate = sequence.timebase
        let v1 = try firstClip(in: sequence.videoTracks[0])
        let v2 = try firstClip(in: sequence.videoTracks[1])
        model.focusTimeline()
        model.selectClip(trackID: sequence.videoTracks[0].id, clipID: v1.id, mode: .replace)
        model.selectClip(trackID: sequence.videoTracks[1].id, clipID: v2.id, mode: .toggle)
        XCTAssertEqual(model.timelineSelectedClipCount, 2)
        let before = model.project

        XCTAssertTrue(model.moveSelectedClips(byFrames: 5, linkedClipEditMode: .linked))

        let moved = try XCTUnwrap(model.activeSequence)
        try assertFrameRange(try firstClip(in: moved.videoTracks[0]).timelineRange, startFrame: 5, durationFrames: 90, frameRate: frameRate)
        try assertFrameRange(try firstClip(in: moved.videoTracks[1]).timelineRange, startFrame: 5, durationFrames: 60, frameRate: frameRate)
        // The unselected linked audio partner of V1 follows the move.
        try assertFrameRange(try firstClip(in: moved.audioTracks[0]).timelineRange, startFrame: 5, durationFrames: 90, frameRate: frameRate)

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    /// The momentary-unlink modifier keeps a linked partner in place during a multi-selection move.
    func testIssue240MultiSelectionMoveUnlinkedLeavesPartner() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0, opensSampleProjectWhenNoRecovery: true)
        let sequence = try XCTUnwrap(model.activeSequence)
        let frameRate = sequence.timebase
        let v1 = try firstClip(in: sequence.videoTracks[0])
        let v2 = try firstClip(in: sequence.videoTracks[1])
        model.focusTimeline()
        model.selectClip(trackID: sequence.videoTracks[0].id, clipID: v1.id, mode: .replace)
        model.selectClip(trackID: sequence.videoTracks[1].id, clipID: v2.id, mode: .toggle)

        XCTAssertTrue(model.moveSelectedClips(byFrames: 5, linkedClipEditMode: .unlinked))

        let moved = try XCTUnwrap(model.activeSequence)
        try assertFrameRange(try firstClip(in: moved.videoTracks[0]).timelineRange, startFrame: 5, durationFrames: 90, frameRate: frameRate)
        // Audio partner stays put because the move was unlinked.
        try assertFrameRange(try firstClip(in: moved.audioTracks[0]).timelineRange, startFrame: 0, durationFrames: 90, frameRate: frameRate)
    }

    /// A multi-clip ripple delete is a single undo step (#240).
    func testIssue240MultiClipRippleDeleteIsSingleUndoStep() throws {
        let fixture = try makeControlledTimelineProject(videoStarts: [0, 10, 20], durationFrames: 10)
        let model = try makeModel(loading: fixture.project)
        model.focusTimeline()
        selectAllVideoClips(model)
        XCTAssertEqual(model.timelineSelectedClipCount, 3)
        let before = model.project

        XCTAssertTrue(model.rippleDeleteSelection())
        XCTAssertTrue(videoClips(model).isEmpty)

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    /// A multi-clip lift is a single undo step and leaves gaps (#240).
    func testIssue240MultiClipLiftIsSingleUndoStep() throws {
        let fixture = try makeControlledTimelineProject(videoStarts: [0, 20], durationFrames: 10)
        let model = try makeModel(loading: fixture.project)
        model.focusTimeline()
        selectAllVideoClips(model)
        let before = model.project

        XCTAssertTrue(model.liftSelection())
        XCTAssertTrue(videoClips(model).isEmpty)

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    /// Pasting several clipboard items is a single undo step, gated on timeline focus (#240).
    func testIssue240PasteIsSingleUndoStepAndFocusGated() throws {
        // Clips spaced so a paste at the playhead lands in free timeline without overlapping.
        let fixture = try makeControlledTimelineProject(videoStarts: [0, 60], durationFrames: 10)
        let model = try makeModel(loading: fixture.project)
        model.focusTimeline()
        selectAllVideoClips(model)
        XCTAssertTrue(model.copyTimelineClips())

        model.blurTimeline()
        XCTAssertFalse(model.pasteTimelineClips())

        model.focusTimeline()
        model.scrub(to: 20)
        let before = model.project
        XCTAssertTrue(model.pasteTimelineClips())
        XCTAssertEqual(videoClips(model).count, 4)

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    /// Three-point insert fits the browser selection into the marked range and undoes in one step.
    func testFRTL003ThreePointInsertFitsMarkedRangeAndUndoes() throws {
        let fixture = try makeControlledTimelineProject(videoStarts: [], durationFrames: 10)
        let model = try makeModel(loading: fixture.project)
        model.setSelectedMediaIDs([fixture.mediaID])
        model.scrub(to: 10)
        model.setTimelineRangeIn()
        model.scrub(to: 30)
        model.setTimelineRangeOut()
        XCTAssertTrue(model.canPerformThreePointEdit)
        let before = model.project

        XCTAssertTrue(model.performThreePointEdit(mode: .insert))
        let clips = videoClips(model)
        XCTAssertEqual(clips.count, 1)
        let inserted = try XCTUnwrap(clips.first)
        try assertFrameRange(inserted.timelineRange, startFrame: 10, durationFrames: 20, frameRate: fixture.frameRate)
        try assertFrameRange(inserted.sourceRange, startFrame: 0, durationFrames: 20, frameRate: fixture.frameRate)

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    /// Three-point overwrite fits the marked range and undoes in one step.
    func testFRTL003ThreePointOverwriteFitsMarkedRangeAndUndoes() throws {
        let fixture = try makeControlledTimelineProject(videoStarts: [], durationFrames: 10)
        let model = try makeModel(loading: fixture.project)
        model.setSelectedMediaIDs([fixture.mediaID])
        model.scrub(to: 5)
        model.setTimelineRangeIn()
        model.scrub(to: 45)
        model.setTimelineRangeOut()
        let before = model.project

        XCTAssertTrue(model.performThreePointEdit(mode: .overwrite))
        let clips = videoClips(model)
        XCTAssertEqual(clips.count, 1)
        let placed = try XCTUnwrap(clips.first)
        try assertFrameRange(placed.timelineRange, startFrame: 5, durationFrames: 40, frameRate: fixture.frameRate)

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    /// Three-point editing refuses without both timeline marks and a media selection (FR-TL-003).
    func testFRTL003ThreePointRefusesWithoutMarksOrSelection() throws {
        let fixture = try makeControlledTimelineProject(videoStarts: [], durationFrames: 10)
        let model = try makeModel(loading: fixture.project)

        // No marks, no selection.
        XCTAssertFalse(model.canPerformThreePointEdit)
        XCTAssertFalse(model.performThreePointEdit(mode: .insert))

        // Marks but no browser selection.
        model.scrub(to: 10)
        model.setTimelineRangeIn()
        model.scrub(to: 30)
        model.setTimelineRangeOut()
        XCTAssertFalse(model.canPerformThreePointEdit)
        XCTAssertFalse(model.performThreePointEdit(mode: .insert))

        // Selection but inverted/empty marks.
        model.setSelectedMediaIDs([fixture.mediaID])
        model.clearTimelineRange()
        model.scrub(to: 30)
        model.setTimelineRangeIn()
        model.scrub(to: 10)
        model.setTimelineRangeOut()
        XCTAssertFalse(model.canPerformThreePointEdit)
        XCTAssertFalse(model.performThreePointEdit(mode: .overwrite))
    }

    /// #240 review finding 1: while a text field has keyboard focus, ⌘X-equivalent cut (and every
    /// destructive or plain-key timeline gesture) refuses, so typing can never delete a clip.
    /// Models the exact focus-flag transitions the UI performs via `timelineTextEditingScope`.
    func testIssue240ReviewTextFieldFocusRefusesCutAndPlainKeyGestures() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0, opensSampleProjectWhenNoRecovery: true)
        let selection = try sampleLinkedSelection(in: model)
        model.selectClip(trackID: selection.videoTrackID, clipID: selection.videoClip.id, mode: .replace)
        model.focusTimeline()
        XCTAssertTrue(model.copyTimelineClips())

        // A transform/marker/search field gains focus — the scenario where ⌘X must cut text.
        let editorID = UUID()
        model.textEditorFocusChanged(id: editorID, isFocused: true)
        XCTAssertTrue(model.isTextEditingActive)
        XCTAssertFalse(model.timelineHasFocus)

        let before = model.project
        XCTAssertFalse(model.cutTimelineClips())
        XCTAssertFalse(model.copyTimelineClips())
        XCTAssertFalse(model.liftSelection())
        XCTAssertFalse(model.rippleDeleteSelection())
        XCTAssertFalse(model.pasteTimelineClips())
        XCTAssertFalse(model.trimSelectedClipToPlayhead(edge: .trailing))
        XCTAssertFalse(model.slipSelectedClip(byFrames: 1))
        XCTAssertFalse(model.slideSelectedClip(byFrames: 1))
        XCTAssertFalse(model.bladeSelectedClipAtPlayhead())
        model.toggleBladeTool()
        XCTAssertEqual(model.timelineTool, .selection)
        model.setTimelineRangeIn()
        XCTAssertNil(model.timelineState.selectionInFrame)
        model.selectForwardFromPlayhead()
        XCTAssertFalse(model.timelineHasFocus)
        XCTAssertEqual(model.project, before)

        // Focus moving directly between two fields must not drop the gate (gain before loss).
        let secondEditorID = UUID()
        model.textEditorFocusChanged(id: secondEditorID, isFocused: true)
        model.textEditorFocusChanged(id: editorID, isFocused: false)
        XCTAssertTrue(model.isTextEditingActive)
        XCTAssertFalse(model.cutTimelineClips())

        // Leaving text editing and refocusing the timeline restores the gestures.
        model.textEditorFocusChanged(id: secondEditorID, isFocused: false)
        XCTAssertFalse(model.isTextEditingActive)
        model.focusTimeline()
        XCTAssertTrue(model.cutTimelineClips())
        model.undo()
        XCTAssertEqual(model.project, before)
    }

    /// #240 review finding 1 (canvas variant): the canvas title text editor also gates gestures.
    func testIssue240ReviewCanvasTitleEditingRefusesDestructiveGestures() throws {
        let model = EditorAjarAppModel(autosaveIntervalSeconds: 0, opensSampleProjectWhenNoRecovery: true)
        let selection = try sampleLinkedSelection(in: model)
        model.selectClip(trackID: selection.videoTrackID, clipID: selection.videoClip.id, mode: .replace)
        model.focusTimeline()

        XCTAssertTrue(model.editPrimaryCanvasTitleBox())
        XCTAssertTrue(model.isTextEditingActive)
        let before = model.project
        XCTAssertFalse(model.cutTimelineClips())
        XCTAssertFalse(model.liftSelection())
        XCTAssertEqual(model.project, before)
        model.endCanvasTitleTextEditing()
        XCTAssertFalse(model.isTextEditingActive)
    }

    /// #240 review finding 5: pasted clips never keep the source link group. A pasted A/V pair
    /// shares one fresh group (linked to each other, not to the originals).
    func testIssue240ReviewPasteAssignsFreshLinkGroupsPerPastedSet() throws {
        let fixture = try makeLinkedPairProject()
        let model = try makeModel(loading: fixture.project)
        model.focusTimeline()
        model.selectClip(trackID: fixture.videoTrackID, clipID: fixture.videoClipID, mode: .replace)
        model.selectClip(trackID: fixture.audioTrackID, clipID: fixture.audioClipID, mode: .toggle)
        XCTAssertTrue(model.copyTimelineClips())
        model.scrub(to: 20)
        XCTAssertTrue(model.pasteTimelineClips())

        let sequence = try XCTUnwrap(model.activeSequence)
        let pastedVideo = try XCTUnwrap(
            clipStarting(atFrame: 20, in: sequence.videoTracks[0], frameRate: fixture.frameRate)
        )
        let pastedAudio = try XCTUnwrap(
            clipStarting(atFrame: 20, in: sequence.audioTracks[0], frameRate: fixture.frameRate)
        )
        let pastedGroup = try XCTUnwrap(pastedVideo.linkGroupID)
        XCTAssertEqual(pastedAudio.linkGroupID, pastedGroup)
        XCTAssertNotEqual(pastedGroup, fixture.linkGroupID)

        // Moving the pasted pair drags its own partner, never the source clips.
        model.selectClip(trackID: fixture.videoTrackID, clipID: pastedVideo.id, mode: .replace)
        XCTAssertTrue(model.moveSelectedClip(toStartFrame: 35, linkedClipEditMode: .linked))
        let moved = try XCTUnwrap(model.activeSequence)
        XCTAssertNotNil(clipStarting(atFrame: 35, in: moved.videoTracks[0], frameRate: fixture.frameRate))
        XCTAssertNotNil(clipStarting(atFrame: 35, in: moved.audioTracks[0], frameRate: fixture.frameRate))
        let originalVideo = try XCTUnwrap(
            clipStarting(atFrame: 0, in: moved.videoTracks[0], frameRate: fixture.frameRate)
        )
        let originalAudio = try XCTUnwrap(
            clipStarting(atFrame: 0, in: moved.audioTracks[0], frameRate: fixture.frameRate)
        )
        XCTAssertEqual(originalVideo.id, fixture.videoClipID)
        XCTAssertEqual(originalAudio.id, fixture.audioClipID)
        XCTAssertEqual(originalVideo.linkGroupID, fixture.linkGroupID)
    }

    func testIssue240ReviewLiftVideoSelectionRemovesLinkedPairInOneUndoStep() throws {
        let fixture = try makeLinkedPairProject()
        let model = try makeModel(loading: fixture.project)
        model.focusTimeline()
        model.selectClip(
            trackID: fixture.videoTrackID,
            clipID: fixture.videoClipID,
            mode: .replace
        )
        let before = model.project

        XCTAssertTrue(model.liftSelection())
        let lifted = try XCTUnwrap(model.activeSequence)
        XCTAssertNil(
            lifted.videoTracks[0].items.compactMap(timelineClip).first(where: {
                $0.id == fixture.videoClipID
            })
        )
        XCTAssertNil(
            lifted.audioTracks[0].items.compactMap(timelineClip).first(where: {
                $0.id == fixture.audioClipID
            })
        )

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    func testIssue240ReviewRippleVideoSelectionRemovesLinkedPairInOneUndoStep() throws {
        let fixture = try makeLinkedPairProject()
        let model = try makeModel(loading: fixture.project)
        model.focusTimeline()
        model.selectClip(
            trackID: fixture.videoTrackID,
            clipID: fixture.videoClipID,
            mode: .replace
        )
        let before = model.project

        XCTAssertTrue(model.rippleDeleteSelection())
        let deleted = try XCTUnwrap(model.activeSequence)
        XCTAssertNil(
            deleted.videoTracks[0].items.compactMap(timelineClip).first(where: {
                $0.id == fixture.videoClipID
            })
        )
        XCTAssertNil(
            deleted.audioTracks[0].items.compactMap(timelineClip).first(where: {
                $0.id == fixture.audioClipID
            })
        )
        XCTAssertNotNil(
            clipStarting(
                atFrame: 50,
                in: deleted.videoTracks[0],
                frameRate: fixture.frameRate
            )
        )

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    func testIssue240ReviewCutVideoSelectionCopiesAndRemovesSameLinkedPair() throws {
        let fixture = try makeLinkedPairProject()
        let model = try makeModel(loading: fixture.project)
        model.focusTimeline()
        model.selectClip(
            trackID: fixture.videoTrackID,
            clipID: fixture.videoClipID,
            mode: .replace
        )
        let before = model.project

        XCTAssertTrue(model.cutTimelineClips())
        let cut = try XCTUnwrap(model.activeSequence)
        XCTAssertNil(
            cut.videoTracks[0].items.compactMap(timelineClip).first(where: {
                $0.id == fixture.videoClipID
            })
        )
        XCTAssertNil(
            cut.audioTracks[0].items.compactMap(timelineClip).first(where: {
                $0.id == fixture.audioClipID
            })
        )
        let afterCut = model.project

        model.scrub(to: 20)
        XCTAssertTrue(model.pasteTimelineClips())
        let pasted = try XCTUnwrap(model.activeSequence)
        let pastedVideo = try XCTUnwrap(
            clipStarting(atFrame: 20, in: pasted.videoTracks[0], frameRate: fixture.frameRate)
        )
        let pastedAudio = try XCTUnwrap(
            clipStarting(atFrame: 20, in: pasted.audioTracks[0], frameRate: fixture.frameRate)
        )
        XCTAssertEqual(pastedVideo.linkGroupID, pastedAudio.linkGroupID)
        XCTAssertNotNil(pastedVideo.linkGroupID)

        model.undo()
        XCTAssertEqual(model.project, afterCut)
        model.undo()
        XCTAssertEqual(model.project, before)
    }

    func testIssue240ReviewDestructiveSelectionRefusesLockedLinkedPartnerWithoutUndo() throws {
        let fixture = try makeLinkedPairProject()
        let model = try makeModel(loading: fixture.project)
        model.focusTimeline()
        model.selectClip(
            trackID: fixture.videoTrackID,
            clipID: fixture.videoClipID,
            mode: .replace
        )
        let beforeLock = model.project
        let sequenceID = try XCTUnwrap(model.activeSequence?.id)
        model.setTrackState(
            sequenceID: sequenceID,
            trackID: fixture.audioTrackID,
            locked: true
        )
        let locked = model.project

        XCTAssertFalse(model.liftSelection())
        XCTAssertFalse(model.rippleDeleteSelection())
        XCTAssertEqual(model.project, locked)

        model.undo()
        XCTAssertEqual(model.project, beforeLock, "refusals must not add an undo entry")
    }

    func testIssue240ReviewPasteLinkedPairRefusesWhenAllAudioTracksLocked() throws {
        let fixture = try makeLinkedPairProject()
        let model = try makeModel(loading: fixture.project)
        model.focusTimeline()
        model.selectClip(
            trackID: fixture.videoTrackID,
            clipID: fixture.videoClipID,
            mode: .replace
        )
        model.selectClip(
            trackID: fixture.audioTrackID,
            clipID: fixture.audioClipID,
            mode: .toggle
        )
        XCTAssertTrue(model.copyTimelineClips())

        let beforeLock = model.project
        let sequenceID = try XCTUnwrap(model.activeSequence?.id)
        for track in try XCTUnwrap(model.activeSequence).audioTracks {
            model.setTrackState(sequenceID: sequenceID, trackID: track.id, locked: true)
        }
        model.scrub(to: 20)
        let locked = model.project

        XCTAssertFalse(model.pasteTimelineClips())
        XCTAssertEqual(model.project, locked)
        let sequence = try XCTUnwrap(model.activeSequence)
        XCTAssertNil(
            clipStarting(atFrame: 20, in: sequence.videoTracks[0], frameRate: fixture.frameRate)
        )
        XCTAssertNil(
            clipStarting(atFrame: 20, in: sequence.audioTracks[0], frameRate: fixture.frameRate)
        )

        model.undo()
        XCTAssertEqual(model.project, beforeLock, "failed paste must not add an undo entry")
    }

    /// #240 review finding 5: pasting a single member of a linked pair unlinks the copy.
    func testIssue240ReviewPastingLoneLinkedMemberUnlinksTheCopy() throws {
        let fixture = try makeLinkedPairProject()
        let model = try makeModel(loading: fixture.project)
        model.focusTimeline()
        model.selectClip(trackID: fixture.videoTrackID, clipID: fixture.videoClipID, mode: .replace)
        XCTAssertTrue(model.copyTimelineClips())
        model.scrub(to: 20)
        XCTAssertTrue(model.pasteTimelineClips())

        let sequence = try XCTUnwrap(model.activeSequence)
        let pasted = try XCTUnwrap(
            clipStarting(atFrame: 20, in: sequence.videoTracks[0], frameRate: fixture.frameRate)
        )
        XCTAssertNil(pasted.linkGroupID)
        // The original audio partner is untouched at frame 0.
        let originalAudio = try XCTUnwrap(
            clipStarting(atFrame: 0, in: sequence.audioTracks[0], frameRate: fixture.frameRate)
        )
        XCTAssertEqual(originalAudio.linkGroupID, fixture.linkGroupID)
    }

    // MARK: - #240 test fixtures

    private struct ControlledTimelineFixture {
        let project: Project
        let frameRate: FrameRate
        let sequenceID: UUID
        let videoTrackID: UUID
        let mediaID: UUID
    }

    private func makeControlledTimelineProject(
        videoStarts: [Int64],
        durationFrames: Int64
    ) throws -> ControlledTimelineFixture {
        let frameRate = try FrameRate(frames: 30)
        let spacerFrames: Int64 = 120
        let mediaID = UUID()
        let media = MediaRef(
            id: mediaID,
            sourceURL: URL(fileURLWithPath: "/media/controlled-\(mediaID.uuidString).mov"),
            contentHash: ContentHash.sha256(data: Data(mediaID.uuidString.utf8)),
            metadata: MediaMetadata(
                codecID: "h264",
                pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
                frameRate: frameRate,
                duration: try frameRate.duration(ofFrames: spacerFrames),
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        // A background audio clip establishes a long enough sequence duration that the playhead
        // (and thus timeline in/out marks) can reach the mark frames these tests use.
        let audioMediaID = UUID()
        let audioMedia = MediaRef(
            id: audioMediaID,
            sourceURL: URL(fileURLWithPath: "/media/controlled-\(audioMediaID.uuidString).wav"),
            contentHash: ContentHash.sha256(data: Data(audioMediaID.uuidString.utf8)),
            metadata: MediaMetadata(
                codecID: "pcm",
                pixelDimensions: nil,
                frameRate: nil,
                duration: try frameRate.duration(ofFrames: spacerFrames),
                colorSpace: .unspecified,
                audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        let spacerDuration = try frameRate.duration(ofFrames: spacerFrames)
        let audioSpacer = Clip(
            id: UUID(),
            source: .media(id: audioMediaID),
            sourceRange: try TimeRange(start: .zero, duration: spacerDuration),
            timelineRange: try TimeRange(start: .zero, duration: spacerDuration),
            kind: .audio,
            name: "Spacer"
        )
        let sourceDuration = try frameRate.duration(ofFrames: durationFrames)
        let clips: [TimelineItem] = try videoStarts.map { start in
            .clip(Clip(
                id: UUID(),
                source: .media(id: mediaID),
                sourceRange: try TimeRange(start: .zero, duration: sourceDuration),
                timelineRange: try TimeRange(
                    start: try RationalTime.atFrame(start, frameRate: frameRate),
                    duration: sourceDuration
                ),
                kind: .video,
                name: "Clip \(start)"
            ))
        }
        let videoTrackID = UUID()
        let sequenceID = UUID()
        let sequence = Sequence(
            id: sequenceID,
            name: "Controlled",
            videoTracks: [Track(id: videoTrackID, kind: .video, items: clips)],
            audioTracks: [Track(id: UUID(), kind: .audio, items: [.clip(audioSpacer)])],
            markers: [],
            timebase: frameRate
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 1_920, height: 1_080),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [media, audioMedia],
            sequences: [sequence]
        )
        return ControlledTimelineFixture(
            project: project,
            frameRate: frameRate,
            sequenceID: sequenceID,
            videoTrackID: videoTrackID,
            mediaID: mediaID
        )
    }

    private struct LinkedPairFixture {
        let project: Project
        let frameRate: FrameRate
        let videoTrackID: UUID
        let audioTrackID: UUID
        let videoClipID: UUID
        let audioClipID: UUID
        let linkGroupID: UUID
    }

    /// Linked A/V pair at [0, 10) plus an unlinked video clip at [60, 70) so the sequence is long
    /// enough for the playhead to reach paste targets in the middle.
    private func makeLinkedPairProject() throws -> LinkedPairFixture {
        let frameRate = try FrameRate(frames: 30)
        let mediaID = UUID()
        let media = MediaRef(
            id: mediaID,
            sourceURL: URL(fileURLWithPath: "/media/linked-\(mediaID.uuidString).mov"),
            contentHash: ContentHash.sha256(data: Data(mediaID.uuidString.utf8)),
            metadata: MediaMetadata(
                codecID: "h264",
                pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
                frameRate: frameRate,
                duration: try frameRate.duration(ofFrames: 120),
                colorSpace: .rec709,
                audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        let clipDuration = try frameRate.duration(ofFrames: 10)
        let pairRange = try TimeRange(start: .zero, duration: clipDuration)
        let linkGroupID = UUID()
        let videoClipID = UUID()
        let audioClipID = UUID()
        let videoClip = Clip(
            id: videoClipID,
            source: .media(id: mediaID),
            sourceRange: pairRange,
            timelineRange: pairRange,
            kind: .video,
            name: "Linked Video",
            linkGroupID: linkGroupID
        )
        let audioClip = Clip(
            id: audioClipID,
            source: .media(id: mediaID),
            sourceRange: pairRange,
            timelineRange: pairRange,
            kind: .audio,
            name: "Linked Audio",
            linkGroupID: linkGroupID
        )
        let tailClip = Clip(
            id: UUID(),
            source: .media(id: mediaID),
            sourceRange: pairRange,
            timelineRange: try TimeRange(
                start: try RationalTime.atFrame(60, frameRate: frameRate),
                duration: clipDuration
            ),
            kind: .video,
            name: "Tail"
        )
        let videoTrackID = UUID()
        let audioTrackID = UUID()
        let sequence = Sequence(
            id: UUID(),
            name: "Linked Pair",
            videoTracks: [
                Track(id: videoTrackID, kind: .video, items: [.clip(videoClip), .clip(tailClip)])
            ],
            audioTracks: [
                Track(id: audioTrackID, kind: .audio, items: [.clip(audioClip)])
            ],
            markers: [],
            timebase: frameRate
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 1_920, height: 1_080),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [media],
            sequences: [sequence]
        )
        return LinkedPairFixture(
            project: project,
            frameRate: frameRate,
            videoTrackID: videoTrackID,
            audioTrackID: audioTrackID,
            videoClipID: videoClipID,
            audioClipID: audioClipID,
            linkGroupID: linkGroupID
        )
    }

    private func clipStarting(atFrame frame: Int64, in track: Track, frameRate: FrameRate) -> Clip? {
        for item in track.items {
            guard case .clip(let clip) = item,
                  let startFrame = try? clip.timelineRange.start.frameIndex(
                    at: frameRate,
                    rounding: .nearestOrAwayFromZero
                  ),
                  startFrame == frame
            else {
                continue
            }
            return clip
        }
        return nil
    }

    private func timelineClip(_ item: TimelineItem) -> Clip? {
        guard case .clip(let clip) = item else { return nil }
        return clip
    }

    private func makeModel(loading project: Project) throws -> EditorAjarAppModel {
        let packageURL = try temporaryAutosavePackageURL(named: "Issue240-\(UUID().uuidString).ajar")
        try AjarAutosaveStore.writeSnapshot(
            project,
            appliedCommandCount: 0,
            openMode: .editable,
            to: packageURL
        )
        let model = EditorAjarAppModel(
            autosavePackageURL: packageURL,
            autosaveIntervalSeconds: 0
        )
        return model
    }

    private func firstVideoTrack(_ model: EditorAjarAppModel) -> Track {
        model.activeSequence?.videoTracks.first ?? Track(id: UUID(), kind: .video, items: [])
    }

    private func videoClips(_ model: EditorAjarAppModel) -> [Clip] {
        guard let track = model.activeSequence?.videoTracks.first else { return [] }
        return track.items.compactMap { item in
            guard case .clip(let clip) = item else { return nil }
            return clip
        }
    }

    private func selectAllVideoClips(_ model: EditorAjarAppModel) {
        guard let track = model.activeSequence?.videoTracks.first else { return }
        var replaced = false
        for item in track.items {
            guard case .clip(let clip) = item else { continue }
            model.selectClip(
                trackID: track.id,
                clipID: clip.id,
                mode: replaced ? .toggle : .replace
            )
            replaced = true
        }
    }

    private func makeInteractionSequence() throws -> AjarCore.Sequence {
        let frameRate = try FrameRate(frames: 30)
        let trackID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000a001"))
        let markerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000b001"))
        return Sequence(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000c001")),
            name: "Interaction Sequence",
            videoTracks: [
                Track(
                    id: trackID,
                    kind: .video,
                    items: [
                        .clip(try makeInteractionClip(
                            id: "00000000-0000-0000-0000-00000000d001",
                            name: "First",
                            startFrame: 0,
                            durationFrames: 30,
                            frameRate: frameRate
                        )),
                        .clip(try makeInteractionClip(
                            id: "00000000-0000-0000-0000-00000000d002",
                            name: "Second",
                            startFrame: 45,
                            durationFrames: 15,
                            frameRate: frameRate
                        )),
                        .clip(try makeInteractionClip(
                            id: "00000000-0000-0000-0000-00000000d003",
                            name: "Third",
                            startFrame: 60,
                            durationFrames: 30,
                            frameRate: frameRate
                        )),
                    ]
                )
            ],
            audioTracks: [],
            markers: [
                Marker(
                    id: markerID,
                    time: try RationalTime.atFrame(30, frameRate: frameRate),
                    name: "Marker"
                )
            ],
            timebase: frameRate
        )
    }

    private func makeInteractionClip(
        id: String,
        name: String,
        startFrame: Int64,
        durationFrames: Int64,
        frameRate: FrameRate
    ) throws -> Clip {
        let duration = try frameRate.duration(ofFrames: durationFrames)
        return Clip(
            id: try XCTUnwrap(UUID(uuidString: id)),
            source: .media(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000e001"))),
            sourceRange: try TimeRange(start: .zero, duration: duration),
            timelineRange: try TimeRange(
                start: try RationalTime.atFrame(startFrame, frameRate: frameRate),
                duration: duration
            ),
            kind: .video,
            name: name
        )
    }

    private func autosaveTrackStateCommand(project: Project) throws -> EditCommand {
        let sequence = try XCTUnwrap(project.sequences.first)
        let track = try XCTUnwrap(sequence.videoTracks.first)
        return .setTrackState(
            sequenceID: sequence.id,
            trackID: track.id,
            state: TrackStatePatch(enabled: false, locked: true, hidden: true)
        )
    }

    private func temporaryAutosavePackageURL(named name: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-app-autosave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL.appendingPathComponent(name, isDirectory: true)
    }

    /// Writes a higher-minor package without going through encode (which rewrites current minor).
    private func writeHigherMinorPackage(
        project: Project,
        schemaMinor: Int,
        to packageURL: URL
    ) throws {
        let document = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            schemaMinor: schemaMinor,
            settings: project.settings,
            mediaPool: [],
            sequences: project.sequences,
            looks: project.looks
        )
        let manifest = AjarMediaManifest(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            schemaMinor: schemaMinor,
            media: project.mediaPool
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        try encoder.encode(document).write(
            to: packageURL.appendingPathComponent("project.json")
        )
        try encoder.encode(manifest).write(
            to: packageURL.appendingPathComponent("media.json")
        )
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
            clipID: try appTestUUID("00000000-0000-0000-0000-000000007102")
        )
        let gradeNode = ClipEffectNode(
            id: try appTestUUID("00000000-0000-0000-0000-000000007101"),
            definition: .colorAdjust(
                ClipColorAdjustParameters(
                    brightness: try RationalValue(numerator: 1, denominator: 4)
                )
            )
        )
        project = try apply(
            .addClipEffectNode(
                sequenceID: sourceReference.sequenceID,
                trackID: sourceReference.trackID,
                clipID: sourceReference.clipID,
                node: gradeNode
            ),
            to: project
        )
        // V2 already holds the FR-TXT-003 title clip at [0, 60). Abut the grade target
        // at [60, 90) so copy/paste/look tests do not trip itemsOverlap.
        let targetDurationFrames: Int64 = 30
        let targetDuration = try sequence.timebase.duration(ofFrames: targetDurationFrames)
        let targetStart = try trackTimelineEnd(targetTrack)
        let targetSourceRange = try TimeRange(start: .zero, duration: targetDuration)
        let targetTimelineRange = try TimeRange(start: targetStart, duration: targetDuration)
        let targetClip = Clip(
            id: targetReference.clipID,
            source: sourceClip.source,
            sourceRange: targetSourceRange,
            timelineRange: targetTimelineRange,
            kind: .video,
            name: "Grade target"
        )
        project = try apply(
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
            guard case .clip(let clip) = item else {
                continue
            }
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
        let packageURL = try temporaryAutosavePackageURL(named: packageName)
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

    private func appTestUUID(_ rawValue: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: rawValue))
    }

    private struct CompoundDestinationRefusalFixture {
        let project: Project
        let first: TimelineClipReference
        let second: TimelineClipReference
    }

    private func makeCompoundDestinationRefusalProject() throws
        -> CompoundDestinationRefusalFixture
    {
        let sample = try EditorAjarAppModel.makeSampleProject().get()
        let settings = sample.settings
        let frameRate = settings.frameRate
        let mediaID = try XCTUnwrap(sample.mediaPool.first { $0.metadata.pixelDimensions != nil }?.id)
        let firstTrackID = UUID()
        let secondTrackID = UUID()
        let firstSelectedID = UUID()
        let secondSelectedID = UUID()
        let sequence = Sequence(
            id: UUID(),
            name: "Compound destination refusal",
            videoTracks: [
                Track(
                    id: firstTrackID,
                    kind: .video,
                    items: [
                        .clip(try compoundTestClip(
                            id: firstSelectedID,
                            mediaID: mediaID,
                            kind: .video,
                            startFrame: 0,
                            durationFrames: 10,
                            frameRate: frameRate,
                            name: "First selected"
                        )),
                        .clip(try compoundTestClip(
                            id: UUID(),
                            mediaID: mediaID,
                            kind: .video,
                            startFrame: 10,
                            durationFrames: 10,
                            frameRate: frameRate,
                            name: "First leftover"
                        )),
                    ]
                ),
                Track(
                    id: secondTrackID,
                    kind: .video,
                    items: [
                        .clip(try compoundTestClip(
                            id: UUID(),
                            mediaID: mediaID,
                            kind: .video,
                            startFrame: 0,
                            durationFrames: 20,
                            frameRate: frameRate,
                            name: "Second leftover"
                        )),
                        .clip(try compoundTestClip(
                            id: secondSelectedID,
                            mediaID: mediaID,
                            kind: .video,
                            startFrame: 20,
                            durationFrames: 10,
                            frameRate: frameRate,
                            name: "Second selected"
                        )),
                    ]
                ),
            ],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        return CompoundDestinationRefusalFixture(
            project: Project(
                schemaVersion: AjarProjectCodec.currentSchemaVersion,
                settings: settings,
                mediaPool: sample.mediaPool,
                sequences: [sequence]
            ),
            first: TimelineClipReference(trackID: firstTrackID, clipID: firstSelectedID),
            second: TimelineClipReference(trackID: secondTrackID, clipID: secondSelectedID)
        )
    }

    private struct CompoundDuckingRefusalFixture {
        let project: Project
        let video: TimelineClipReference
        let trigger: TimelineClipReference
    }

    private func makeCompoundDuckingRefusalProject() throws -> CompoundDuckingRefusalFixture {
        let sample = try EditorAjarAppModel.makeSampleProject().get()
        let settings = sample.settings
        let frameRate = settings.frameRate
        let videoMediaID = try XCTUnwrap(
            sample.mediaPool.first { $0.metadata.pixelDimensions != nil }?.id
        )
        let audioMediaID = try XCTUnwrap(
            sample.mediaPool.first { $0.metadata.audioChannelLayout != nil }?.id
        )
        let videoTrackID = UUID()
        let triggerTrackID = UUID()
        let targetTrackID = UUID()
        let videoClipID = UUID()
        let triggerClipID = UUID()
        let targetClipID = UUID()
        let sequence = Sequence(
            id: UUID(),
            name: "Compound ducking refusal",
            videoTracks: [
                Track(
                    id: videoTrackID,
                    kind: .video,
                    items: [.clip(try compoundTestClip(
                        id: videoClipID,
                        mediaID: videoMediaID,
                        kind: .video,
                        startFrame: 0,
                        durationFrames: 10,
                        frameRate: frameRate,
                        name: "Selected video"
                    ))]
                )
            ],
            audioTracks: [
                Track(
                    id: triggerTrackID,
                    kind: .audio,
                    items: [.clip(try compoundTestClip(
                        id: triggerClipID,
                        mediaID: audioMediaID,
                        kind: .audio,
                        startFrame: 0,
                        durationFrames: 10,
                        frameRate: frameRate,
                        name: "Selected trigger"
                    ))]
                ),
                Track(
                    id: targetTrackID,
                    kind: .audio,
                    items: [.clip(try compoundTestClip(
                        id: targetClipID,
                        mediaID: audioMediaID,
                        kind: .audio,
                        startFrame: 0,
                        durationFrames: 10,
                        frameRate: frameRate,
                        name: "Outside target"
                    ))]
                ),
            ],
            markers: [],
            audioDucking: [
                AudioDuckingRule(
                    triggerTrackID: triggerTrackID,
                    targetTrackIDs: [targetTrackID],
                    threshold: try RationalValue(numerator: 1, denominator: 2),
                    reductionGain: try RationalValue(numerator: 1, denominator: 4),
                    attack: .zero,
                    release: .zero
                )
            ],
            timebase: frameRate
        )
        return CompoundDuckingRefusalFixture(
            project: Project(
                schemaVersion: AjarProjectCodec.currentSchemaVersion,
                settings: settings,
                mediaPool: sample.mediaPool,
                sequences: [sequence]
            ),
            video: TimelineClipReference(trackID: videoTrackID, clipID: videoClipID),
            trigger: TimelineClipReference(trackID: triggerTrackID, clipID: triggerClipID)
        )
    }

    private struct DecomposeRefusalFixture {
        let project: Project
        let compound: TimelineClipReference
    }

    private func makeDecomposeOverlapRefusalProject() throws -> DecomposeRefusalFixture {
        let sample = try EditorAjarAppModel.makeSampleProject().get()
        let settings = sample.settings
        let frameRate = settings.frameRate
        let mediaID = try XCTUnwrap(sample.mediaPool.first { $0.metadata.pixelDimensions != nil }?.id)
        let parentSequenceID = UUID()
        let nestedSequenceID = UUID()
        let compoundTrackID = UUID()
        let targetTrackID = UUID()
        let compoundClipID = UUID()
        let duration = try frameRate.duration(ofFrames: 10)
        let compound = Clip(
            id: compoundClipID,
            source: .sequence(id: nestedSequenceID),
            sourceRange: try TimeRange(start: .zero, duration: duration),
            timelineRange: try TimeRange(start: .zero, duration: duration),
            kind: .video,
            name: "Overlap compound"
        )
        let inner = try compoundTestClip(
            id: UUID(),
            mediaID: mediaID,
            kind: .video,
            startFrame: 0,
            durationFrames: 10,
            frameRate: frameRate,
            name: "Inner video"
        )
        let blocker = try compoundTestClip(
            id: UUID(),
            mediaID: mediaID,
            kind: .video,
            startFrame: 0,
            durationFrames: 10,
            frameRate: frameRate,
            name: "Parent blocker"
        )
        let parent = Sequence(
            id: parentSequenceID,
            name: "Decompose overlap parent",
            videoTracks: [
                Track(id: compoundTrackID, kind: .video, items: [.clip(compound)]),
                Track(id: targetTrackID, kind: .video, items: [.clip(blocker)]),
            ],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        let nested = Sequence(
            id: nestedSequenceID,
            name: "Decompose overlap nested",
            videoTracks: [Track(id: targetTrackID, kind: .video, items: [.clip(inner)])],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: settings,
            mediaPool: sample.mediaPool,
            sequences: [parent, nested]
        )
        XCTAssertEqual(project.validate(), .valid)
        return DecomposeRefusalFixture(
            project: project,
            compound: TimelineClipReference(trackID: compoundTrackID, clipID: compoundClipID)
        )
    }

    private func makeDecomposeDuckingRefusalProject() throws -> DecomposeRefusalFixture {
        let sample = try EditorAjarAppModel.makeSampleProject().get()
        let settings = sample.settings
        let frameRate = settings.frameRate
        let audioMediaID = try XCTUnwrap(
            sample.mediaPool.first { $0.metadata.audioChannelLayout != nil }?.id
        )
        let parentSequenceID = UUID()
        let nestedSequenceID = UUID()
        let compoundTrackID = UUID()
        let insideTriggerTrackID = UUID()
        let outsideTargetTrackID = UUID()
        let compoundClipID = UUID()
        let windowDuration = try frameRate.duration(ofFrames: 4)
        let compound = Clip(
            id: compoundClipID,
            source: .sequence(id: nestedSequenceID),
            sourceRange: try TimeRange(start: .zero, duration: windowDuration),
            timelineRange: try TimeRange(start: .zero, duration: windowDuration),
            kind: .video,
            name: "Ducking compound"
        )
        let rule = AudioDuckingRule(
            triggerTrackID: insideTriggerTrackID,
            targetTrackIDs: [outsideTargetTrackID],
            threshold: try RationalValue(numerator: 1, denominator: 2),
            reductionGain: try RationalValue(numerator: 1, denominator: 4),
            attack: .zero,
            release: .zero
        )
        let parent = Sequence(
            id: parentSequenceID,
            name: "Decompose ducking parent",
            videoTracks: [Track(
                id: compoundTrackID,
                kind: .video,
                items: [.clip(compound)]
            )],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        let nested = Sequence(
            id: nestedSequenceID,
            name: "Decompose ducking nested",
            videoTracks: [],
            audioTracks: [
                Track(
                    id: insideTriggerTrackID,
                    kind: .audio,
                    items: [.clip(try compoundTestClip(
                        id: UUID(),
                        mediaID: audioMediaID,
                        kind: .audio,
                        startFrame: 0,
                        durationFrames: 4,
                        frameRate: frameRate,
                        name: "Inside trigger"
                    ))]
                ),
                Track(
                    id: outsideTargetTrackID,
                    kind: .audio,
                    items: [.clip(try compoundTestClip(
                        id: UUID(),
                        mediaID: audioMediaID,
                        kind: .audio,
                        startFrame: 4,
                        durationFrames: 4,
                        frameRate: frameRate,
                        name: "Outside target"
                    ))]
                ),
            ],
            markers: [],
            audioDucking: [rule],
            timebase: frameRate
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: settings,
            mediaPool: sample.mediaPool,
            sequences: [parent, nested]
        )
        XCTAssertEqual(project.validate(), .valid)
        return DecomposeRefusalFixture(
            project: project,
            compound: TimelineClipReference(trackID: compoundTrackID, clipID: compoundClipID)
        )
    }

    private func compoundTestClip(
        id: UUID,
        mediaID: UUID,
        kind: TrackKind,
        startFrame: Int64,
        durationFrames: Int64,
        frameRate: FrameRate,
        name: String
    ) throws -> Clip {
        let duration = try frameRate.duration(ofFrames: durationFrames)
        return Clip(
            id: id,
            source: .media(id: mediaID),
            sourceRange: try TimeRange(start: .zero, duration: duration),
            timelineRange: try TimeRange(
                start: try RationalTime.atFrame(startFrame, frameRate: frameRate),
                duration: duration
            ),
            kind: kind,
            name: name
        )
    }

    private func sampleLinkedSelection(
        in model: EditorAjarAppModel
    ) throws -> SampleLinkedSelection {
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
        let audioTrack = try XCTUnwrap(sequence.audioTracks.first)
        return SampleLinkedSelection(
            frameRate: sequence.timebase,
            videoTrackID: videoTrack.id,
            audioTrackID: audioTrack.id,
            videoClip: try firstClip(in: videoTrack),
            audioClip: try firstClip(in: audioTrack)
        )
    }

    @discardableResult
    private func selectSampleVideoClip(
        in model: EditorAjarAppModel
    ) throws -> Clip {
        let sequence = try XCTUnwrap(model.activeSequence)
        let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
        let clip = try firstClip(in: videoTrack)
        model.selectClip(trackID: videoTrack.id, clipID: clip.id, mode: .replace)
        return clip
    }

    private func positionLane(in model: EditorAjarAppModel) throws -> TransformKeyframeLane {
        try XCTUnwrap(
            model.selectedTransformKeyframeLanes.first { lane in
                lane.parameter == .position
            }
        )
    }

    private func firstClip(in track: Track) throws -> Clip {
        for item in track.items {
            if case .clip(let clip) = item {
                return clip
            }
        }
        return try XCTUnwrap(nil)
    }

    private func assertFrameRange(
        _ range: TimeRange,
        startFrame: Int64,
        durationFrames: Int64,
        frameRate: FrameRate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try range.start.frameIndex(at: frameRate, rounding: .nearestOrAwayFromZero),
            startFrame,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try range.duration.frameIndex(at: frameRate, rounding: .nearestOrAwayFromZero),
            durationFrames,
            file: file,
            line: line
        )
    }

    private static func durationFrames(for sequence: Sequence) throws -> Int64 {
        var endFrame: Int64 = 1
        for track in sequence.videoTracks + sequence.audioTracks {
            for item in track.items {
                guard case .clip(let clip) = item else {
                    continue
                }
                endFrame = max(
                    endFrame,
                    try clip.timelineRange.end().frameIndex(
                        at: sequence.timebase,
                        rounding: .nearestOrAwayFromZero
                    )
                )
            }
        }
        return endFrame
    }
}

private struct SampleLinkedSelection {
    let frameRate: FrameRate
    let videoTrackID: UUID
    let audioTrackID: UUID
    let videoClip: Clip
    let audioClip: Clip
}

private struct GradeAppFixture {
    let project: Project
    let source: ProjectClipReference
    let target: ProjectClipReference
}

private final class FakeAudioCoordinator: EditorAjarAudioCoordinating {
    private(set) var startedFrames: [Int64] = []
    private(set) var seekFrames: [Int64] = []
    private(set) var ensuredFrames: [Int64] = []
    private(set) var stopCount = 0
    var startError: Error?
    var seekError: Error?
    var ensureError: Error?

    func start(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
        if let startError {
            throw startError
        }
        startedFrames.append(playheadFrame)
    }

    func stop() {
        stopCount += 1
    }

    func publishSeek(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
        if let seekError {
            throw seekError
        }
        seekFrames.append(playheadFrame)
    }

    func ensurePlaybackPlan(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
        if let ensureError {
            throw ensureError
        }
        ensuredFrames.append(playheadFrame)
    }
}

private final class FakeAudioOutputDriver: EditorAjarAudioOutputDriving {
    private let lock = NSLock()
    private let publishSemaphore = DispatchSemaphore(value: 0)
    private var publishedFrameCountsValue: [Int] = []
    private var publishWasOnMainThreadValue: [Bool] = []
    private var publishedFirstSamplesValue: [Float] = []
    private var startCountValue = 0
    private var stopCountValue = 0
    private let publishError: Error?

    init(publishError: Error? = nil) {
        self.publishError = publishError
    }

    var publishedFrameCounts: [Int] {
        lock.withLock { publishedFrameCountsValue }
    }

    var publishWasOnMainThread: [Bool] {
        lock.withLock { publishWasOnMainThreadValue }
    }

    var publishedFirstSamples: [Float] {
        lock.withLock { publishedFirstSamplesValue }
    }

    var startCount: Int {
        lock.withLock { startCountValue }
    }

    var stopCount: Int {
        lock.withLock { stopCountValue }
    }

    var publishCount: Int {
        publishedFrameCounts.count
    }

    func publish(_ plan: RealtimeAudioRenderPlan) throws {
        var inspectablePlan = plan
        var firstFrame = Array(repeating: Float(0), count: plan.format.channelCount)
        firstFrame.withUnsafeMutableBufferPointer { output in
            _ = inspectablePlan.render(into: output)
        }
        lock.withLock {
            publishedFrameCountsValue.append(plan.safetyReport().preparedFrameCount)
            publishWasOnMainThreadValue.append(Thread.isMainThread)
            publishedFirstSamplesValue.append(firstFrame[0])
        }
        publishSemaphore.signal()
        if let publishError {
            throw publishError
        }
    }

    func waitForNextPublish() -> Bool {
        publishSemaphore.wait(timeout: .now() + .seconds(2)) == .success
    }

    func start() throws {
        lock.withLock {
            startCountValue += 1
        }
    }

    func stop() {
        lock.withLock {
            stopCountValue += 1
        }
    }

    func safetyReport() -> RealtimeAudioSafetyReport? {
        nil
    }
}

private enum TestAudioOutputError: Error {
    case unavailable
}

private actor AudioProviderPreparationGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        entered = true
        for waiter in enteredWaiters {
            waiter.resume()
        }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else {
            return
        }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor AudioRefillPreparationGate {
    private var preparationCount = 0
    private var refillEntered = false
    private var refillEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var refillReleaseContinuation: CheckedContinuation<Void, Never>?

    func prepare(
        project: Project,
        sequence: Sequence,
        range: TimeRange
    ) async throws -> any AudioSourceProvider {
        preparationCount += 1
        if preparationCount == 2 {
            refillEntered = true
            for waiter in refillEnteredWaiters {
                waiter.resume()
            }
            refillEnteredWaiters.removeAll()
            await withCheckedContinuation { continuation in
                refillReleaseContinuation = continuation
            }
        }
        return try EditorAjarProjectAudioSourceProvider(
            project: project,
            sequence: sequence,
            range: range
        )
    }

    func waitUntilRefillEntered() async {
        guard !refillEntered else {
            return
        }
        await withCheckedContinuation { continuation in
            refillEnteredWaiters.append(continuation)
        }
    }

    func releaseRefill() {
        refillReleaseContinuation?.resume()
        refillReleaseContinuation = nil
    }
}

private actor RecoverableAudioPreparation {
    private var shouldFail = true

    func prepare(
        project: Project,
        sequence: Sequence,
        range: TimeRange
    ) throws -> any AudioSourceProvider {
        if shouldFail {
            throw TestAudioPreparationError.unreadable
        }
        return try EditorAjarProjectAudioSourceProvider(
            project: project,
            sequence: sequence,
            range: range
        )
    }

    func allowSuccess() {
        shouldFail = false
    }
}

private enum TestAudioPreparationError: Error {
    case unreadable
}
