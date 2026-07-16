// SPDX-License-Identifier: GPL-3.0-or-later

import AVFAudio
import Foundation

/// Errors produced while configuring the platform live audio output graph.
public enum LiveAudioOutputDriverError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The requested PCM format cannot be represented by AVAudioEngine.
    case unsupportedFormat(sampleRate: Int, channelCount: Int)

    /// A published render plan does not match the configured device channel count.
    case channelCountMismatch(expected: Int, actual: Int)

    /// A published render plan does not match the configured device-facing sample rate.
    case sampleRateMismatch(expected: Int, actual: Int)

    /// A human-readable description.
    public var description: String {
        switch self {
        case .unsupportedFormat(let sampleRate, let channelCount):
            "unsupported live audio output format sampleRate=\(sampleRate) "
                + "channelCount=\(channelCount)"
        case .channelCountMismatch(let expected, let actual):
            "live audio plan channelCount=\(actual) does not match output channelCount=\(expected)"
        case .sampleRateMismatch(let expected, let actual):
            "live audio plan sampleRate=\(actual) does not match output sampleRate=\(expected)"
        }
    }
}

/// Live AVAudioEngine output driver for pre-rendered realtime audio plans.
///
/// Control-side code publishes prepared `RealtimeAudioRenderPlan` values. The audio render block
/// only acquires the current plan and copies into caller-owned output memory, preserving the
/// FR-AUD-007 no-allocation/no-lock callback contract.
public final class LiveAudioOutputDriver: @unchecked Sendable {
    private let handoff: RealtimeAudioRenderPlanHandoff
    private let engine: AVAudioEngine
    private let sourceNode: AVAudioSourceNode
    private let outputFormat: AVAudioFormat
    private let sampleRate: Int
    private let channelCount: Int

    /// Creates the audio graph. This does not start hardware output.
    public init(format: AudioRenderFormat = AudioRenderFormat(sampleRate: 48_000, channelCount: 2))
        throws {
        try AudioBufferValidator.validate(format: format, frameCount: 0, samples: [])

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channelCount),
            interleaved: false
        ) else {
            throw LiveAudioOutputDriverError.unsupportedFormat(
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            )
        }

        let handoff = try RealtimeAudioRenderPlanHandoff()
        self.handoff = handoff
        engine = AVAudioEngine()
        self.outputFormat = outputFormat
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList in
            Self.renderCallback(
                handoff: handoff,
                frameCount: Int(frameCount),
                channelCount: format.channelCount,
                audioBufferList: audioBufferList
            )
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: outputFormat)
        engine.prepare()
    }

    deinit {
        stop()
    }

    /// Whether the underlying AVAudioEngine is currently running.
    public var isRunning: Bool {
        engine.isRunning
    }

    /// Publishes a fully prepared render plan from the control side.
    public func publish(_ plan: RealtimeAudioRenderPlan) throws {
        guard plan.format.sampleRate == sampleRate else {
            throw LiveAudioOutputDriverError.sampleRateMismatch(
                expected: sampleRate,
                actual: plan.format.sampleRate
            )
        }
        guard plan.format.channelCount == channelCount else {
            throw LiveAudioOutputDriverError.channelCountMismatch(
                expected: channelCount,
                actual: plan.format.channelCount
            )
        }
        try handoff.publish(plan)
    }

    /// Starts live output after a plan has been published.
    public func start() throws {
        guard !engine.isRunning else {
            return
        }
        try engine.start()
    }

    /// Stops live output.
    public func stop() {
        guard engine.isRunning else {
            return
        }
        engine.stop()
    }

    /// Returns the realtime safety report for the currently published plan.
    public func safetyReport() -> RealtimeAudioSafetyReport? {
        handoff.safetyReport()
    }

    /// Test hook for the render-block body without opening the hardware device.
    @discardableResult
    public func renderForTesting(into output: UnsafeMutableBufferPointer<Float>) -> Int {
        Self.renderInterleavedOutput(handoff: handoff, output: output)
    }

    /// Test hook for the non-interleaved render-block body without opening the hardware device.
    @discardableResult
    public func renderNonInterleavedForTesting(
        audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int
    ) -> Int {
        Self.renderNonInterleavedOutput(
            handoff: handoff,
            audioBufferList: audioBufferList,
            frameCount: frameCount
        )
    }

    private static func renderCallback(
        handoff: RealtimeAudioRenderPlanHandoff,
        frameCount: Int,
        channelCount: Int,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        if buffers.count == 1,
           let data = buffers[0].mData {
            let expectedSampleCount = frameCount * channelCount
            let availableSampleCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride
            let sampleCount = min(expectedSampleCount, availableSampleCount)
            let output = UnsafeMutableBufferPointer(
                start: data.assumingMemoryBound(to: Float.self),
                count: sampleCount
            )
            renderInterleavedOutput(handoff: handoff, output: output)
            return noErr
        }

        guard buffers.count >= channelCount else {
            zero(audioBufferList: audioBufferList)
            return noErr
        }

        renderNonInterleavedOutput(
            handoff: handoff,
            audioBufferList: audioBufferList,
            frameCount: frameCount
        )
        return noErr
    }

    @discardableResult
    private static func renderInterleavedOutput(
        handoff: RealtimeAudioRenderPlanHandoff,
        output: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        guard let renderedFrames = handoff.withCurrentPlan({ plan in
            plan.render(into: output)
        }) else {
            zero(output)
            return 0
        }
        return renderedFrames
    }

    @discardableResult
    private static func renderNonInterleavedOutput(
        handoff: RealtimeAudioRenderPlanHandoff,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int
    ) -> Int {
        guard let renderedFrames = handoff.withCurrentPlan({ plan in
            plan.renderNonInterleaved(into: audioBufferList, frameCount: frameCount)
        }) else {
            zero(audioBufferList: audioBufferList)
            return 0
        }
        return renderedFrames
    }

    private static func zero(_ output: UnsafeMutableBufferPointer<Float>) {
        for sampleIndex in output.indices {
            output[sampleIndex] = 0
        }
    }

    private static func zero(audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for bufferIndex in 0..<buffers.count {
            guard let data = buffers[bufferIndex].mData else {
                continue
            }
            let sampleCount = Int(buffers[bufferIndex].mDataByteSize) / MemoryLayout<Float>.stride
            let output = UnsafeMutableBufferPointer(
                start: data.assumingMemoryBound(to: Float.self),
                count: sampleCount
            )
            zero(output)
        }
    }
}
