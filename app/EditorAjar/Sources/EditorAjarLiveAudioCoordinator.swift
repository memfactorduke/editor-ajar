// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import Foundation

protocol EditorAjarAudioOutputDriving: AnyObject {
    func publish(_ plan: RealtimeAudioRenderPlan) throws
    func start() throws
    func stop()
    func safetyReport() -> RealtimeAudioSafetyReport?
}

extension LiveAudioOutputDriver: EditorAjarAudioOutputDriving {}

protocol EditorAjarAudioCoordinating: AnyObject {
    func start(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws

    func stop()

    func publishSeek(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws

    func ensurePlaybackPlan(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws
}

final class EditorAjarLiveAudioCoordinator: EditorAjarAudioCoordinating {
    private static let renderWindowSeconds: Int64 = 2
    private static let refillMarginSeconds: Int64 = 1

    private let driver: any EditorAjarAudioOutputDriving
    private let renderQueue: DispatchQueue
    private var publishedRange: Range<Int64>?
    private var pendingRange: Range<Int64>?
    /// Session master monitoring gain. Written from the main actor, read only on `renderQueue`
    /// when preparing plans — never on the real-time audio callback (ADR-0012).
    private var masterGainLinear: Double = AudioMixUISupport.defaultMasterGainLinear

    init(
        driver: any EditorAjarAudioOutputDriving,
        renderQueue: DispatchQueue = DispatchQueue(
            label: "org.editorajar.live-audio-coordinator.render",
            qos: .userInitiated
        )
    ) {
        self.driver = driver
        self.renderQueue = renderQueue
    }

    /// Updates session master gain. Applied when the next plan is prepared off-thread.
    func setMasterGainLinear(_ linear: Double) {
        let clamped = min(
            AudioMixLimits.maximumGain.doubleValue,
            max(AudioMixLimits.minimumGain.doubleValue, linear)
        )
        renderQueue.async { [weak self] in
            self?.masterGainLinear = clamped
        }
    }

    convenience init() throws {
        try self.init(driver: LiveAudioOutputDriver())
    }

    func start(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
        try enqueuePlan(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            durationFrames: durationFrames,
            force: true
        )
        try driver.start()
    }

    func stop() {
        driver.stop()
    }

    func publishSeek(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
        try enqueuePlan(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            durationFrames: durationFrames,
            force: true
        )
    }

    func ensurePlaybackPlan(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
        try enqueuePlan(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            durationFrames: durationFrames,
            force: false
        )
    }

    func drainPendingRendersForTesting() {
        renderQueue.sync {}
    }

    private func shouldPublishPlan(playheadFrame: Int64, sequence: Sequence) -> Bool {
        if let pendingRange, pendingRange.contains(playheadFrame) {
            return false
        }

        guard let publishedRange else {
            return true
        }
        if !publishedRange.contains(playheadFrame) {
            return true
        }

        let refillMargin = Self.refillMarginFrames(for: sequence)
        return publishedRange.upperBound - playheadFrame <= refillMargin
    }

    private func enqueuePlan(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64,
        force: Bool
    ) throws {
        let request = try Self.renderRequest(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            durationFrames: durationFrames
        )

        renderQueue.async { [weak self] in
            guard let self else {
                return
            }
            guard force || self.shouldPublishPlan(
                playheadFrame: request.playheadFrame,
                sequence: sequence
            ) else {
                return
            }

            self.pendingRange = request.publishRange
            defer {
                self.pendingRange = nil
            }

            do {
                let plan = try Self.renderPlan(
                    project: project,
                    sequence: sequence,
                    range: request.renderRange,
                    masterGainLinear: self.masterGainLinear
                )
                try self.driver.publish(plan)
                self.publishedRange = request.publishRange
            } catch {
                self.publishedRange = nil
            }
        }
    }

    private static func renderRequest(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws -> LiveAudioRenderRequest {
        let boundedPlayheadFrame = max(0, min(playheadFrame, max(0, durationFrames - 1)))
        let windowFrames = Self.windowFrames(
            from: boundedPlayheadFrame,
            durationFrames: durationFrames,
            sequence: sequence
        )
        let range = try TimeRange(
            start: RationalTime.atFrame(boundedPlayheadFrame, frameRate: sequence.timebase),
            duration: sequence.timebase.duration(ofFrames: windowFrames)
        )

        return LiveAudioRenderRequest(
            playheadFrame: boundedPlayheadFrame,
            renderRange: range,
            publishRange: boundedPlayheadFrame..<(boundedPlayheadFrame + windowFrames)
        )
    }

    private struct LiveAudioRenderRequest {
        let playheadFrame: Int64
        let renderRange: TimeRange
        let publishRange: Range<Int64>
    }

    /// Builds the realtime callback plan off-thread, flattening compound/nested sources with
    /// the same contributor semantics as the offline mix (FR-AUD-007, FR-CMP-001).
    ///
    /// Session master gain is applied here by scaling the pre-rendered buffer so the RT
    /// callback remains a pure copy (ADR-0012).
    private static func renderPlan(
        project: Project,
        sequence: Sequence,
        range: TimeRange,
        masterGainLinear: Double
    ) throws -> RealtimeAudioRenderPlan {
        let provider = try EditorAjarProjectAudioSourceProvider(
            project: project,
            sequence: sequence,
            range: range
        )
        do {
            let buffer = try OfflineAudioMixer.render(
                project: project,
                sequence: sequence,
                range: range,
                sourceProvider: provider
            )
            let scaled = try Self.applyingMasterGain(masterGainLinear, to: buffer)
            return RealtimeAudioRenderPlan(buffer: scaled)
        } catch let error as AudioRenderError {
            switch error {
            case .missingAudioSource, .unsupportedClipSource:
                return RealtimeAudioRenderPlan(
                    buffer: try silentBuffer(project: project, range: range)
                )
            default:
                throw error
            }
        }
    }

    private static func applyingMasterGain(
        _ linear: Double,
        to buffer: RenderedAudioBuffer
    ) throws -> RenderedAudioBuffer {
        guard linear != 1.0, linear.isFinite else {
            return buffer
        }
        let gain = Float(linear)
        let samples = buffer.samples.map { $0 * gain }
        return try RenderedAudioBuffer(
            format: buffer.format,
            frameCount: buffer.frameCount,
            samples: samples
        )
    }

    private static func silentBuffer(project: Project, range: TimeRange) throws -> RenderedAudioBuffer {
        let format = AudioRenderFormat(sampleRate: project.settings.audioSampleRate, channelCount: 2)
        let frameCount = try sampleFrameCount(for: range.duration, sampleRate: format.sampleRate)
        let samples = [Float](repeating: 0, count: frameCount * format.channelCount)
        return try RenderedAudioBuffer(format: format, frameCount: frameCount, samples: samples)
    }

    fileprivate static func sampleFrameCount(
        for duration: RationalTime,
        sampleRate: Int
    ) throws -> Int {
        let sampleFrames = try duration.value(atTimescale: Int64(sampleRate))
        guard sampleFrames <= Int64(Int.max) else {
            throw AudioRenderError.timeArithmetic("sample frame count \(sampleFrames) is out of range")
        }
        return max(0, Int(sampleFrames))
    }

    fileprivate static func sampleFrameIndex(
        for time: RationalTime,
        sampleRate: Int,
        rounding: FrameRoundingRule
    ) throws -> Int {
        let rate = try FrameRate(frames: Int64(sampleRate))
        let value = try time.frameIndex(at: rate, rounding: rounding)
        guard value >= 0, value <= Int64(Int.max) else {
            throw AudioRenderError.timeArithmetic("sample index \(value) is out of range")
        }
        return Int(value)
    }

    private static func windowFrames(
        from playheadFrame: Int64,
        durationFrames: Int64,
        sequence: Sequence
    ) -> Int64 {
        let remainingFrames = max(1, durationFrames - playheadFrame)
        return min(remainingFrames, renderWindowFrames(for: sequence))
    }

    private static func renderWindowFrames(for sequence: Sequence) -> Int64 {
        max(1, sequence.timebase.frames * renderWindowSeconds / sequence.timebase.seconds)
    }

    private static func refillMarginFrames(for sequence: Sequence) -> Int64 {
        max(1, sequence.timebase.frames * refillMarginSeconds / sequence.timebase.seconds)
    }
}

/// Sample-tone / project media provider shared by live playback plan prep and off-RT metering.
struct EditorAjarProjectAudioSourceProvider: AudioSourceProvider {
    let project: Project
    let sourceWindowsByMediaID: [UUID: Range<Int>]

    init(project: Project, sequence: Sequence, range: TimeRange) throws {
        self.project = project
        sourceWindowsByMediaID = try Self.sourceWindowsByMediaID(
            project: project,
            sequence: sequence,
            range: range
        )
    }

    func audioSource(for mediaID: UUID) throws -> AudioSourceBuffer {
        guard let media = project.mediaPool.first(where: { $0.id == mediaID }),
              media.metadata.codecID == EditorAjarSampleProjectFactory.sampleToneCodecID,
              let layout = media.metadata.audioChannelLayout
        else {
            throw AudioRenderError.missingAudioSource(mediaID)
        }

        return try Self.sampleToneSource(
            media: media,
            channelCount: layout.channelCount,
            sampleRate: project.settings.audioSampleRate,
            sourceWindow: sourceWindowsByMediaID[mediaID]
        )
    }

    private static func sourceWindowsByMediaID(
        project: Project,
        sequence: Sequence,
        range: TimeRange
    ) throws -> [UUID: Range<Int>] {
        var windows: [UUID: Range<Int>] = [:]
        let sampleRate = project.settings.audioSampleRate
        let renderEnd = try range.end()
        var mediaByID: [UUID: MediaRef] = [:]
        for media in project.mediaPool {
            mediaByID[media.id] = media
        }

        for track in selectedAudioTracks(sequence.audioTracks) {
            for item in track.items {
                guard case .clip(let clip) = item,
                      clip.kind == .audio,
                      case .media(let mediaID) = clip.source,
                      mediaByID[mediaID]?.metadata.codecID
                        == EditorAjarSampleProjectFactory.sampleToneCodecID
                else {
                    continue
                }

                let clipEnd = try clip.timelineRange.end()
                let intersectionStart = max(clip.timelineRange.start, range.start)
                let intersectionEnd = min(clipEnd, renderEnd)
                guard intersectionStart < intersectionEnd else {
                    continue
                }

                let sourceStartOffset = try intersectionStart.subtracting(clip.timelineRange.start)
                let sourceEndOffset = try intersectionEnd.subtracting(clip.timelineRange.start)
                let sourceStart = try clip.sourceRange.start.adding(sourceStartOffset)
                let sourceEnd = try clip.sourceRange.start.adding(sourceEndOffset)
                let startFrame = try EditorAjarLiveAudioCoordinator.sampleFrameIndex(
                    for: sourceStart,
                    sampleRate: sampleRate,
                    rounding: .down
                )
                let endFrame = try EditorAjarLiveAudioCoordinator.sampleFrameIndex(
                    for: sourceEnd,
                    sampleRate: sampleRate,
                    rounding: .up
                )
                let sourceWindow = startFrame..<max(startFrame, endFrame + 1)
                if let existing = windows[mediaID] {
                    let lowerBound = min(existing.lowerBound, sourceWindow.lowerBound)
                    let upperBound = max(existing.upperBound, sourceWindow.upperBound)
                    windows[mediaID] = lowerBound..<upperBound
                } else {
                    windows[mediaID] = sourceWindow
                }
            }
        }

        return windows
    }

    private static func selectedAudioTracks(_ tracks: [Track]) -> [Track] {
        let enabledTracks = tracks.filter { track in
            track.kind == .audio && track.enabled && !track.muted
        }
        let soloTracks = enabledTracks.filter(\.solo)
        return soloTracks.isEmpty ? enabledTracks : soloTracks
    }

    private static func sampleToneSource(
        media: MediaRef,
        channelCount: Int,
        sampleRate: Int,
        sourceWindow: Range<Int>?
    ) throws -> AudioSourceBuffer {
        let mediaFrameCount = try EditorAjarLiveAudioCoordinator.sampleFrameCount(
            for: media.metadata.duration,
            sampleRate: sampleRate
        )
        let requestedWindow = sourceWindow ?? 0..<mediaFrameCount
        let frameOffset = min(max(0, requestedWindow.lowerBound), mediaFrameCount)
        let upperBound = min(max(frameOffset, requestedWindow.upperBound), mediaFrameCount)
        let frameCount = upperBound - frameOffset
        var samples: [Float] = []
        samples.reserveCapacity(frameCount * channelCount)

        for frame in 0..<frameCount {
            let absoluteFrame = frameOffset + frame
            let phase = 2.0 * Double.pi * 440.0 * Double(absoluteFrame) / Double(sampleRate)
            let sample = Float(sin(phase) * 0.12)
            for _ in 0..<channelCount {
                samples.append(sample)
            }
        }

        return try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: sampleRate, channelCount: channelCount),
            frameCount: frameCount,
            samples: samples,
            frameOffset: frameOffset
        )
    }
}
