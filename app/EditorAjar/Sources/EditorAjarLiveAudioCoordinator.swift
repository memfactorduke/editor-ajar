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
    private var publishedRange: Range<Int64>?

    init(driver: any EditorAjarAudioOutputDriving) {
        self.driver = driver
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
        try publishPlan(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            durationFrames: durationFrames
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
        try publishPlan(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            durationFrames: durationFrames
        )
    }

    func ensurePlaybackPlan(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
        if shouldPublishPlan(playheadFrame: playheadFrame, sequence: sequence) {
            try publishPlan(
                project: project,
                sequence: sequence,
                playheadFrame: playheadFrame,
                durationFrames: durationFrames
            )
        }
    }

    private func shouldPublishPlan(playheadFrame: Int64, sequence: Sequence) -> Bool {
        guard let publishedRange else {
            return true
        }
        if !publishedRange.contains(playheadFrame) {
            return true
        }

        let refillMargin = Self.refillMarginFrames(for: sequence)
        return publishedRange.upperBound - playheadFrame <= refillMargin
    }

    private func publishPlan(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
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
        let buffer = try Self.renderBuffer(project: project, sequence: sequence, range: range)

        try driver.publish(RealtimeAudioRenderPlan(buffer: buffer))
        publishedRange = boundedPlayheadFrame..<(boundedPlayheadFrame + windowFrames)
    }

    private static func renderBuffer(
        project: Project,
        sequence: Sequence,
        range: TimeRange
    ) throws -> RenderedAudioBuffer {
        let provider = EditorAjarProjectAudioSourceProvider(project: project)
        do {
            return try OfflineAudioMixer.render(
                project: project,
                sequence: sequence,
                range: range,
                sourceProvider: provider
            )
        } catch let error as AudioRenderError {
            switch error {
            case .missingAudioSource, .unsupportedClipSource:
                return try silentBuffer(project: project, range: range)
            default:
                throw error
            }
        }
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
        return max(0, Int(sampleFrames))
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

private struct EditorAjarProjectAudioSourceProvider: AudioSourceProvider {
    let project: Project

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
            sampleRate: project.settings.audioSampleRate
        )
    }

    private static func sampleToneSource(
        media: MediaRef,
        channelCount: Int,
        sampleRate: Int
    ) throws -> AudioSourceBuffer {
        let frameCount = try EditorAjarLiveAudioCoordinator.sampleFrameCount(
            for: media.metadata.duration,
            sampleRate: sampleRate
        )
        var samples: [Float] = []
        samples.reserveCapacity(frameCount * channelCount)

        for frame in 0..<frameCount {
            let phase = 2.0 * Double.pi * 440.0 * Double(frame) / Double(sampleRate)
            let sample = Float(sin(phase) * 0.12)
            for _ in 0..<channelCount {
                samples.append(sample)
            }
        }

        return try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: sampleRate, channelCount: channelCount),
            frameCount: frameCount,
            samples: samples
        )
    }
}
