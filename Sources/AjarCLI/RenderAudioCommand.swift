// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import Foundation

/// Parsed options for `ajar render-audio`.
public struct RenderAudioOptions: Equatable, Sendable {
    /// Start time in the project timeline.
    public let startTime: FrameTimeArgument

    /// Duration to render.
    public let duration: FrameTimeArgument

    /// Output channel count.
    public let channelCount: Int

    /// `.ajar` package directory to load.
    public let projectURL: URL

    /// WAV output location.
    public let outputURL: URL

    /// Creates render-audio options.
    public init(
        startTime: FrameTimeArgument,
        duration: FrameTimeArgument,
        channelCount: Int,
        projectURL: URL,
        outputURL: URL
    ) {
        self.startTime = startTime
        self.duration = duration
        self.channelCount = channelCount
        self.projectURL = projectURL
        self.outputURL = outputURL
    }

    static func parse(_ arguments: [String]) throws -> RenderAudioOptions {
        try RenderAudioOptionParser(arguments: arguments).parse()
    }
}

/// Result of writing one rendered audio range.
public struct RenderAudioResult: Equatable, Sendable {
    /// WAV output location.
    public let outputURL: URL

    /// Output format.
    public let format: AudioRenderFormat

    /// Rendered frame count.
    public let frameCount: Int
}

/// Implements `ajar render-audio`.
public enum RenderAudioCommand {
    /// Loads, mixes, and writes one exact audio range.
    public static func render(options: RenderAudioOptions) throws -> RenderAudioResult {
        let project = try ProjectPackageIO.loadProject(from: options.projectURL)
        guard let sequence = project.sequences.first else {
            throw AjarCLIError.missingSequence
        }

        let range = try renderRange(options: options, frameRate: project.settings.frameRate)
        let buffer = try OfflineAudioMixer.render(
            project: project,
            sequence: sequence,
            range: range,
            sourceProvider: WAVAudioSourceProvider(project: project),
            channelCount: options.channelCount
        )
        try WAVCodec.write(buffer, to: options.outputURL)

        return RenderAudioResult(
            outputURL: options.outputURL,
            format: buffer.format,
            frameCount: buffer.frameCount
        )
    }

    private static func renderRange(
        options: RenderAudioOptions,
        frameRate: FrameRate
    ) throws -> TimeRange {
        let start = try options.startTime.resolve(frameRate: frameRate)
        let duration = try options.duration.resolve(frameRate: frameRate)
        return try TimeRange(start: start, duration: duration)
    }
}

private struct RenderAudioOptionParser {
    let arguments: [String]

    func parse() throws -> RenderAudioOptions {
        var state = RenderAudioParseState()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            try parse(argument, state: &state, index: &index)
            index += 1
        }

        return try state.options()
    }

    private func parse(
        _ argument: String,
        state: inout RenderAudioParseState,
        index: inout Int
    ) throws {
        switch argument {
        case "--start":
            state.startTime = try nextTimeArgument(after: argument, index: &index)
        case "--duration":
            state.duration = try nextTimeArgument(after: argument, index: &index)
        case "--channels":
            state.channelCount = try nextChannelCount(after: argument, index: &index)
        case "-o", "--output":
            state.outputURL = try nextURL(after: argument, index: &index)
        default:
            try state.acceptProjectArgument(argument)
        }
    }

    private func nextTimeArgument(
        after argument: String,
        index: inout Int
    ) throws -> FrameTimeArgument {
        index += 1
        guard index < arguments.count else {
            throw AjarCLIError.invalidUsage("\(argument) requires a value")
        }
        return try FrameTimeArgument.parse(arguments[index])
    }

    private func nextChannelCount(after argument: String, index: inout Int) throws -> Int {
        index += 1
        guard index < arguments.count, let channelCount = Int(arguments[index]) else {
            throw AjarCLIError.invalidUsage("\(argument) requires a channel count")
        }
        guard channelCount > 0 else {
            throw AjarCLIError.invalidUsage("\(argument) must be positive")
        }
        return channelCount
    }

    private func nextURL(after argument: String, index: inout Int) throws -> URL {
        index += 1
        guard index < arguments.count else {
            throw AjarCLIError.invalidUsage("\(argument) requires a WAV path")
        }
        return URL(fileURLWithPath: arguments[index])
    }
}

private struct RenderAudioParseState {
    var startTime: FrameTimeArgument = .rational(.zero)
    var duration: FrameTimeArgument?
    var channelCount = 2
    var projectURL: URL?
    var outputURL: URL?

    mutating func acceptProjectArgument(_ argument: String) throws {
        if argument.hasPrefix("-") {
            throw AjarCLIError.invalidUsage("unknown render-audio option '\(argument)'")
        }
        guard projectURL == nil else {
            throw AjarCLIError.invalidUsage("render-audio accepts exactly one project path")
        }
        projectURL = URL(fileURLWithPath: argument)
    }

    func options() throws -> RenderAudioOptions {
        guard let duration else {
            throw AjarCLIError.invalidUsage("render-audio requires --duration")
        }
        guard let projectURL else {
            throw AjarCLIError.invalidUsage("render-audio requires a project.ajar path")
        }
        guard let outputURL else {
            throw AjarCLIError.invalidUsage("render-audio requires -o <out.wav>")
        }
        return RenderAudioOptions(
            startTime: startTime,
            duration: duration,
            channelCount: channelCount,
            projectURL: projectURL,
            outputURL: outputURL
        )
    }
}

private struct WAVAudioSourceProvider: AudioSourceProvider {
    private let mediaByID: [UUID: MediaRef]

    init(project: Project) {
        var mediaByID: [UUID: MediaRef] = [:]
        for media in project.mediaPool {
            mediaByID[media.id] = media
        }
        self.mediaByID = mediaByID
    }

    func audioSource(for mediaID: UUID) throws -> AudioSourceBuffer {
        guard let media = mediaByID[mediaID], let url = media.sourceURL else {
            throw AudioRenderError.missingAudioSource(mediaID)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AjarCLIError.missingFile(url.path)
        }
        return try WAVCodec.readAudioSource(from: url)
    }
}
