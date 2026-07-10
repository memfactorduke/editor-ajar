// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal

/// Parsed options for `ajar render --frame`.
public struct RenderFrameOptions: Equatable, Sendable {
    /// Frame time argument from the CLI.
    public let frameTime: FrameTimeArgument

    /// `.ajar` package directory to load.
    public let projectURL: URL

    /// PNG output location.
    public let outputURL: URL

    /// Creates render options.
    public init(frameTime: FrameTimeArgument, projectURL: URL, outputURL: URL) {
        self.frameTime = frameTime
        self.projectURL = projectURL
        self.outputURL = outputURL
    }

    static func parse(_ arguments: [String]) throws -> RenderFrameOptions {
        var frame: FrameTimeArgument?
        var outputURL: URL?
        var projectURL: URL?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--frame":
                index += 1
                guard index < arguments.count else {
                    throw AjarCLIError.invalidUsage("--frame requires a value")
                }
                frame = try FrameTimeArgument.parse(arguments[index])
            case "-o", "--output":
                index += 1
                guard index < arguments.count else {
                    throw AjarCLIError.invalidUsage("\(argument) requires a PNG path")
                }
                outputURL = URL(fileURLWithPath: arguments[index])
            default:
                if argument.hasPrefix("-") {
                    throw AjarCLIError.invalidUsage("unknown render option '\(argument)'")
                }
                guard projectURL == nil else {
                    throw AjarCLIError.invalidUsage("render accepts exactly one project path")
                }
                projectURL = URL(fileURLWithPath: argument)
            }
            index += 1
        }

        guard let frame else {
            throw AjarCLIError.invalidUsage("render requires --frame")
        }
        guard let projectURL else {
            throw AjarCLIError.invalidUsage("render requires a project.ajar path")
        }
        guard let outputURL else {
            throw AjarCLIError.invalidUsage("render requires -o <out.png>")
        }

        return RenderFrameOptions(
            frameTime: frame,
            projectURL: projectURL,
            outputURL: outputURL
        )
    }
}

/// Exact frame time argument accepted by the CLI.
public enum FrameTimeArgument: Equatable, Sendable {
    /// A timeline frame index resolved through the project frame rate.
    case frameIndex(Int64)

    /// An explicit RationalTime value.
    case rational(RationalTime)

    static func parse(_ rawValue: String) throws -> FrameTimeArgument {
        if rawValue.contains("/") {
            let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let value = Int64(parts[0]),
                  let timescale = Int64(parts[1])
            else {
                throw AjarCLIError.invalidUsage("invalid rational frame time '\(rawValue)'")
            }
            return .rational(try RationalTime(value: value, timescale: timescale))
        }

        guard let frameIndex = Int64(rawValue) else {
            throw AjarCLIError.invalidUsage("invalid frame time '\(rawValue)'")
        }
        return .frameIndex(frameIndex)
    }

    func resolve(frameRate: FrameRate) throws -> RationalTime {
        switch self {
        case .frameIndex(let frameIndex):
            try RationalTime.atFrame(frameIndex, frameRate: frameRate)
        case .rational(let time):
            time
        }
    }
}

/// Result of writing one rendered frame.
public struct RenderFrameResult: Equatable, Sendable {
    /// PNG output location.
    public let outputURL: URL

    /// Output dimensions.
    public let pixelDimensions: PixelDimensions

    /// Render graph content hash for the output frame.
    public let contentHash: ContentHash
}

/// Implements `ajar render --frame`.
public enum RenderFrameCommand {
    /// Loads, renders, reads back, and writes one PNG frame.
    public static func render(options: RenderFrameOptions) async throws -> RenderFrameResult {
        // Render is non-destructive: higher-minor (read-only) projects are allowed.
        let project = try ProjectPackageIO.loadProject(from: options.projectURL).project
        guard let sequence = project.sequences.first else {
            throw AjarCLIError.missingSequence
        }

        let renderTime = try options.frameTime.resolve(frameRate: project.settings.frameRate)
        let graph = try buildRenderGraph(for: sequence, at: renderTime, in: project)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }

        let sourceProvider = try await PredecodedSourceTextureProvider(
            graph: graph,
            project: project,
            device: device
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: project.settings.resolution),
            sourceProvider: sourceProvider
        )
        try await waitForRender(frame)

        let bytes = try TextureReadback.readBGRA8(texture: frame.texture, device: device)
        let image = PNGImage(
            width: frame.texture.width,
            height: frame.texture.height,
            bgra8: bytes
        )
        try PNGCodec.write(image, to: options.outputURL)

        return RenderFrameResult(
            outputURL: options.outputURL,
            pixelDimensions: PixelDimensions(
                width: frame.texture.width,
                height: frame.texture.height
            ),
            contentHash: frame.contentHash
        )
    }

    private static func waitForRender(_ frame: RenderedFrame) async throws {
        try await frame.waitForCompletion()
        if let error = frame.commandBuffer?.error {
            throw AjarCLIError.renderCommandFailed(String(describing: error))
        }
        guard frame.commandBuffer?.status ?? .completed == .completed else {
            let statusDescription = frame.commandBuffer
                .map { String(describing: $0.status) }
                ?? "unknown"
            throw AjarCLIError.renderCommandFailed(
                "command buffer status \(statusDescription)"
            )
        }
    }
}
