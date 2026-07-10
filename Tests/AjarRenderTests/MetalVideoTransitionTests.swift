// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import XCTest

@testable import AjarRender

/// FR-FX-001 Metal kernel tests: discrimination + full-frame coverage at progress 0.5
/// (device-or-skip).
final class MetalVideoTransitionTests: XCTestCase {
    func testFRFX001NFRQUAL001TransitionFragmentPipelineLoads() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let executor = try MetalRenderExecutor(device: device)
        let pipeline = try executor.pipelineState(
            fragmentFunctionName: "ajar_video_transition_fragment",
            pixelFormat: MetalRenderExecutor.linearWorkingPixelFormat
        )
        XCTAssertNotNil(pipeline)
    }

    func testFRFX001NFRQUAL001CrossDissolveAtHalfDiffersFromBothInputs() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let size = 64
        let outgoing = try makeSolidSharedTexture(
            device: device,
            size: size,
            bgra: [160, 120, 80, 255]
        )
        let incoming = try makeSolidSharedTexture(
            device: device,
            size: size,
            bgra: [80, 120, 160, 255]
        )
        let blended = try renderTransitionPixels(
            device: device,
            outgoing: outgoing,
            incoming: incoming,
            kind: .crossDissolve,
            size: size
        )
        let outPixels = try readSharedBGRA8(outgoing)
        let inPixels = try readSharedBGRA8(incoming)
        let vsOut = changedPixelFraction(
            left: outPixels,
            right: blended,
            channelDeltaThreshold: 2
        )
        let vsIn = changedPixelFraction(
            left: inPixels,
            right: blended,
            channelDeltaThreshold: 2
        )
        XCTAssertGreaterThan(vsOut, 0.5, "crossDissolve@0.5 should differ from outgoing")
        XCTAssertGreaterThan(vsIn, 0.5, "crossDissolve@0.5 should differ from incoming")
    }

    func testFRFX001NFRQUAL001EachKindDiffersFromCrossDissolveAtHalf() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let size = 64
        let outgoing = try makeCheckerboardTexture(device: device, size: size, cellSize: 8)
        let incoming = try makeSolidSharedTexture(
            device: device,
            size: size,
            bgra: [128, 112, 96, 255]
        )
        let cross = try renderTransitionPixels(
            device: device,
            outgoing: outgoing,
            incoming: incoming,
            kind: .crossDissolve,
            size: size
        )
        for kindCase in transitionCoverageKinds() where kindCase.kind != .crossDissolve {
            let pixels = try renderTransitionPixels(
                device: device,
                outgoing: outgoing,
                incoming: incoming,
                kind: kindCase.kind,
                size: size,
                direction: kindCase.direction
            )
            let fraction = changedPixelFraction(
                left: cross,
                right: pixels,
                channelDeltaThreshold: 2
            )
            XCTAssertGreaterThan(
                fraction,
                0.01,
                "\(kindCase.kind) @0.5 should differ from crossDissolve (got \(fraction))"
            )
        }
    }

    /// Catches the vertexCount:3 / half-quad bug: undrawn upper-right triangle stays at
    /// the render-pass clear color (transparent black). Every kind at p=0.5 must cover
    /// all four corners and the center with non-clear, non-zero-alpha pixels, and the
    /// whole frame must be free of clear-color leftovers.
    func testFRFX001NFRQUAL001EveryKindAtHalfCoversFullFrame() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let size = 64
        let outgoing = try makeSolidSharedTexture(
            device: device,
            size: size,
            bgra: [160, 120, 80, 255]
        )
        let incoming = try makeSolidSharedTexture(
            device: device,
            size: size,
            bgra: [80, 120, 160, 255]
        )
        // Match `MetalRenderExecutor.renderPassDescriptor` clear (transparent black).
        let clearSentinel: [UInt8] = [0, 0, 0, 0]

        for kindCase in transitionCoverageKinds() {
            let pixels = try renderTransitionPixels(
                device: device,
                outgoing: outgoing,
                incoming: incoming,
                kind: kindCase.kind,
                size: size,
                direction: kindCase.direction
            )
            assertFullFrameCoverage(
                pixels: pixels,
                size: size,
                kind: kindCase.kind,
                clearSentinel: clearSentinel
            )
        }
    }
}

// MARK: - Coverage helpers (file scope keeps the test type under body-length limits)

private struct TransitionKindCase {
    let kind: ClipVideoTransitionKind
    let direction: ClipVideoTransitionDirection
}

private struct TransitionSamplePoint {
    let label: String
    let x: Int
    let y: Int
}

private func transitionCoverageKinds() -> [TransitionKindCase] {
    [
        TransitionKindCase(kind: .crossDissolve, direction: .left),
        TransitionKindCase(kind: .dipToColor, direction: .left),
        TransitionKindCase(kind: .fade, direction: .left),
        TransitionKindCase(kind: .push, direction: .right),
        TransitionKindCase(kind: .slide, direction: .top),
        TransitionKindCase(kind: .wipe, direction: .topLeft),
        TransitionKindCase(kind: .zoom, direction: .left)
    ]
}

private func transitionCoverageSamplePoints(size: Int) -> [TransitionSamplePoint] {
    [
        TransitionSamplePoint(label: "topLeft", x: 0, y: 0),
        TransitionSamplePoint(label: "topRight", x: size - 1, y: 0),
        TransitionSamplePoint(label: "bottomLeft", x: 0, y: size - 1),
        TransitionSamplePoint(label: "bottomRight", x: size - 1, y: size - 1),
        TransitionSamplePoint(label: "center", x: size / 2, y: size / 2)
    ]
}

private func assertFullFrameCoverage(
    pixels: [UInt8],
    size: Int,
    kind: ClipVideoTransitionKind,
    clearSentinel: [UInt8]
) {
    XCTAssertEqual(pixels.count, size * size * 4, "\(kind): unexpected BGRA buffer size")

    for point in transitionCoverageSamplePoints(size: size) {
        let sample = bgraPixel(in: pixels, width: size, x: point.x, y: point.y)
        XCTAssertFalse(
            sampleEquals(sample, clearSentinel, channelTolerance: 0),
            """
            \(kind) @0.5 \(point.label) (\(point.x),\(point.y)) is clear-sentinel \
            — undrawn half-quad?
            """
        )
        // Plausible coverage: non-zero alpha (composited transition result is opaque
        // for solid A/B inputs under every FR-FX-001 kind at mid-progress).
        XCTAssertGreaterThan(
            sample[3],
            8,
            "\(kind) @0.5 \(point.label) alpha \(sample[3]) too low for full-frame coverage"
        )
    }

    let clearFraction = fractionMatching(
        pixels: pixels,
        sentinel: clearSentinel,
        channelTolerance: 0
    )
    XCTAssertEqual(
        clearFraction,
        0,
        accuracy: 0.000_1,
        "\(kind) @0.5 has \(clearFraction) clear-sentinel pixels; expected full-frame cover"
    )
}

private func renderTransitionPixels(
    device: MTLDevice,
    outgoing: MTLTexture,
    incoming: MTLTexture,
    kind: ClipVideoTransitionKind,
    size: Int,
    direction: ClipVideoTransitionDirection = .left
) throws -> [UInt8] {
    let executor = try MetalRenderExecutor(device: device)
    let project = try makeTwoClipTransitionProject(kind: kind, direction: direction)
    let sequence = try XCTUnwrap(project.sequences.first)
    let time = try RationalTime(value: 12, timescale: 24)
    let graph = try buildRenderGraph(for: sequence, at: time, in: project)
    let outgoingID = try transitionTestUUID(4)
    let provider = ClosureRenderSourceTextureProvider { source in
        source.clipID == outgoingID ? outgoing : incoming
    }
    let frame = try executor.render(
        graph: graph,
        output: RenderOutputDescriptor(
            pixelDimensions: PixelDimensions(width: size, height: size)
        ),
        sourceProvider: provider
    )
    waitForEffectStackFrame(frame)
    return try readEffectStackBGRA8(texture: frame.texture, device: device)
}

// swiftlint:disable:next function_body_length
private func makeTwoClipTransitionProject(
    kind: ClipVideoTransitionKind,
    direction: ClipVideoTransitionDirection
) throws -> Project {
    let mediaID = try transitionTestUUID(1)
    let sequenceID = try transitionTestUUID(2)
    let trackID = try transitionTestUUID(3)
    let outgoingID = try transitionTestUUID(4)
    let incomingID = try transitionTestUUID(5)
    let duration = try RationalTime(value: 4, timescale: 24)
    let ten = try RationalTime(value: 10, timescale: 24)
    let sourceRange = try TimeRange(start: .zero, duration: ten)
    let outgoing = Clip(
        id: outgoingID,
        source: .media(id: mediaID),
        sourceRange: sourceRange,
        timelineRange: try TimeRange(start: .zero, duration: ten),
        kind: .video,
        name: "out",
        trailingTransition: ClipVideoTransition(
            partnerClipID: incomingID,
            duration: duration,
            kind: kind,
            direction: direction
        )
    )
    let incoming = Clip(
        id: incomingID,
        source: .media(id: mediaID),
        sourceRange: sourceRange,
        timelineRange: try TimeRange(start: ten, duration: ten),
        kind: .video,
        name: "in",
        leadingTransition: ClipVideoTransition(
            partnerClipID: outgoingID,
            duration: duration,
            kind: kind,
            direction: direction
        )
    )
    let track = Track(
        id: trackID,
        kind: .video,
        items: [.clip(outgoing), .clip(incoming)]
    )
    let sequence = Sequence(
        id: sequenceID,
        name: "t",
        videoTracks: [track],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let media = try effectStackMediaRef(
        id: mediaID,
        size: 64,
        path: "/tmp/transition-test.mov"
    )
    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 64, height: 64),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [media],
        sequences: [sequence]
    )
}

private func makeSolidSharedTexture(
    device: MTLDevice,
    size: Int,
    bgra: [UInt8]
) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: size,
        height: size,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw EffectStackDiscriminationError.textureUnavailable
    }
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    for index in 0..<(size * size) {
        let base = index * 4
        bytes[base] = bgra[0]
        bytes[base + 1] = bgra[1]
        bytes[base + 2] = bgra[2]
        bytes[base + 3] = bgra[3]
    }
    texture.replace(
        region: MTLRegionMake2D(0, 0, size, size),
        mipmapLevel: 0,
        withBytes: bytes,
        bytesPerRow: size * 4
    )
    return texture
}

private func readSharedBGRA8(_ texture: MTLTexture) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(
        &bytes,
        bytesPerRow: texture.width * 4,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    return bytes
}

private func bgraPixel(in pixels: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
    let base = ((y * width) + x) * 4
    return [pixels[base], pixels[base + 1], pixels[base + 2], pixels[base + 3]]
}

private func sampleEquals(_ left: [UInt8], _ right: [UInt8], channelTolerance: Int) -> Bool {
    guard left.count == 4, right.count == 4 else {
        return false
    }
    for channel in 0..<4 where abs(Int(left[channel]) - Int(right[channel])) > channelTolerance {
        return false
    }
    return true
}

private func fractionMatching(
    pixels: [UInt8],
    sentinel: [UInt8],
    channelTolerance: Int
) -> Double {
    let pixelCount = pixels.count / 4
    guard pixelCount > 0 else {
        return 0
    }
    var matches = 0
    var index = 0
    while index < pixels.count {
        let sample = [pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3]]
        if sampleEquals(sample, sentinel, channelTolerance: channelTolerance) {
            matches += 1
        }
        index += 4
    }
    return Double(matches) / Double(pixelCount)
}

private func transitionTestUUID(_ value: Int) throws -> UUID {
    try effectStackUUID(7_000 + value)
}
