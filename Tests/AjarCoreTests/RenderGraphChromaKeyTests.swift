// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class RenderGraphChromaKeyTests: XCTestCase {
    func testFRCOMP001ADR0009EvaluatedChromaKeyParamsInvalidateCompositeHash() throws {
        let mediaID = try uuid(1)
        let clipID = try uuid(2)
        let effectsAnimation = try AnimatableClipEffects(
            chromaKey: AnimatableClipChromaKeySettings(
                enabled: true,
                keyColor: .green,
                tolerance: Animatable(
                    base: try rationalValue(1, 10),
                    keyframes: [
                        Keyframe(
                            time: try time(0),
                            value: try rationalValue(1, 10),
                            interpolation: .linear
                        ),
                        Keyframe(
                            time: try time(12),
                            value: try rationalValue(1, 2),
                            interpolation: .hold
                        )
                    ]
                ),
                edgeSoftness: .constant(try rationalValue(1, 10)),
                spillSuppression: .constant(try rationalValue(1, 5)),
                choke: .constant(.zero)
            )
        )
        let clip = try makeClip(
            id: clipID,
            mediaID: mediaID,
            effectsAnimation: effectsAnimation
        )
        let sequence = try makeSequence(with: clip)
        let project = try makeProject(mediaPool: [makeMediaRef(id: mediaID)], sequences: [sequence])

        let firstGraph = try buildRenderGraph(for: sequence, at: try time(0), in: project)
        let repeatedFirstGraph = try buildRenderGraph(for: sequence, at: try time(0), in: project)
        let secondGraph = try buildRenderGraph(for: sequence, at: try time(12), in: project)
        let firstInput = try compositeInput(in: firstGraph)
        let secondInput = try compositeInput(in: secondGraph)

        XCTAssertEqual(firstInput.effects.chromaKey.tolerance, try rationalValue(1, 10))
        XCTAssertEqual(secondInput.effects.chromaKey.tolerance, try rationalValue(1, 2))
        XCTAssertEqual(
            firstGraph.outputNode?.contentHash,
            repeatedFirstGraph.outputNode?.contentHash
        )
        XCTAssertNotEqual(firstGraph.outputNode?.contentHash, secondGraph.outputNode?.contentHash)
    }

    func testFRCOMP003ADR0009EvaluatedMaskParamsInvalidateCompositeHash() throws {
        let mediaID = try uuid(3)
        let clipID = try uuid(4)
        let effectsAnimation = try AnimatableClipEffects(
            masks: [
                AnimatableClipMask(
                    id: try uuid(5),
                    shape: .rectangle(
                        AnimatableClipRectangleMask(
                            x: .constant(.zero),
                            y: .constant(.zero),
                            width: Animatable(
                                base: try rationalValue(1, 1),
                                keyframes: [
                                    Keyframe(
                                        time: try time(0),
                                        value: try rationalValue(1, 1),
                                        interpolation: .linear
                                    ),
                                    Keyframe(
                                        time: try time(12),
                                        value: try rationalValue(4, 1),
                                        interpolation: .hold
                                    )
                                ]
                            ),
                            height: .constant(try rationalValue(1, 1))
                        )
                    ),
                    featherRadius: .constant(.zero)
                )
            ]
        )
        let clip = try makeClip(
            id: clipID,
            mediaID: mediaID,
            effectsAnimation: effectsAnimation
        )
        let sequence = try makeSequence(with: clip)
        let project = try makeProject(mediaPool: [makeMediaRef(id: mediaID)], sequences: [sequence])

        let firstGraph = try buildRenderGraph(for: sequence, at: try time(0), in: project)
        let repeatedFirstGraph = try buildRenderGraph(for: sequence, at: try time(0), in: project)
        let secondGraph = try buildRenderGraph(for: sequence, at: try time(12), in: project)
        let firstRectangle = try rectangleMask(in: firstGraph)
        let secondRectangle = try rectangleMask(in: secondGraph)

        XCTAssertEqual(firstRectangle.width, try rationalValue(1, 1))
        XCTAssertEqual(secondRectangle.width, try rationalValue(4, 1))
        XCTAssertEqual(
            firstGraph.outputNode?.contentHash,
            repeatedFirstGraph.outputNode?.contentHash
        )
        XCTAssertNotEqual(firstGraph.outputNode?.contentHash, secondGraph.outputNode?.contentHash)
    }

    func testFRCOL001ADR0009EvaluatedColorCorrectionInvalidatesCompositeHash() throws {
        let mediaID = try uuid(6)
        let clipID = try uuid(7)
        let effectsAnimation = try AnimatableClipEffects(
            colorCorrection: AnimatableClipColorCorrection(
                exposure: Animatable(
                    base: .zero,
                    keyframes: [
                        Keyframe(
                            time: try time(0),
                            value: .zero,
                            interpolation: .linear
                        ),
                        Keyframe(
                            time: try time(12),
                            value: try rationalValue(1, 1),
                            interpolation: .hold
                        )
                    ]
                ),
                saturation: .constant(try rationalValue(3, 2))
            )
        )
        let clip = try makeClip(
            id: clipID,
            mediaID: mediaID,
            effectsAnimation: effectsAnimation
        )
        let sequence = try makeSequence(with: clip)
        let project = try makeProject(mediaPool: [makeMediaRef(id: mediaID)], sequences: [sequence])

        let firstGraph = try buildRenderGraph(for: sequence, at: try time(0), in: project)
        let repeatedFirstGraph = try buildRenderGraph(for: sequence, at: try time(0), in: project)
        let secondGraph = try buildRenderGraph(for: sequence, at: try time(12), in: project)
        let firstInput = try compositeInput(in: firstGraph)
        let secondInput = try compositeInput(in: secondGraph)

        XCTAssertEqual(firstInput.effects.colorCorrection.exposure, .zero)
        XCTAssertEqual(secondInput.effects.colorCorrection.exposure, try rationalValue(1, 1))
        XCTAssertEqual(
            firstGraph.outputNode?.contentHash,
            repeatedFirstGraph.outputNode?.contentHash
        )
        XCTAssertNotEqual(firstGraph.outputNode?.contentHash, secondGraph.outputNode?.contentHash)
    }

    func testFRCOMP005ADR0009EvaluatedLumaKeyParamsInvalidateCompositeHash() throws {
        let mediaID = try uuid(8)
        let clipID = try uuid(9)
        let effectsAnimation = try AnimatableClipEffects(
            lumaKey: AnimatableClipLumaKeySettings(
                enabled: true,
                lowThreshold: Animatable(
                    base: try rationalValue(1, 10),
                    keyframes: [
                        Keyframe(
                            time: try time(0),
                            value: try rationalValue(1, 10),
                            interpolation: .linear
                        ),
                        Keyframe(
                            time: try time(12),
                            value: try rationalValue(1, 4),
                            interpolation: .hold
                        )
                    ]
                ),
                highThreshold: .constant(try rationalValue(9, 10)),
                softness: .constant(try rationalValue(1, 10))
            )
        )
        let clip = try makeClip(
            id: clipID,
            mediaID: mediaID,
            effectsAnimation: effectsAnimation
        )
        let sequence = try makeSequence(with: clip)
        let project = try makeProject(mediaPool: [makeMediaRef(id: mediaID)], sequences: [sequence])

        let firstGraph = try buildRenderGraph(for: sequence, at: try time(0), in: project)
        let repeatedFirstGraph = try buildRenderGraph(for: sequence, at: try time(0), in: project)
        let secondGraph = try buildRenderGraph(for: sequence, at: try time(12), in: project)
        let firstInput = try compositeInput(in: firstGraph)
        let secondInput = try compositeInput(in: secondGraph)

        XCTAssertEqual(firstInput.effects.lumaKey.lowThreshold, try rationalValue(1, 10))
        XCTAssertEqual(secondInput.effects.lumaKey.lowThreshold, try rationalValue(1, 4))
        XCTAssertEqual(
            firstGraph.outputNode?.contentHash,
            repeatedFirstGraph.outputNode?.contentHash
        )
        XCTAssertNotEqual(firstGraph.outputNode?.contentHash, secondGraph.outputNode?.contentHash)
    }
}

private func compositeInput(in graph: RenderGraph) throws -> RenderCompositeInput {
    let output = try XCTUnwrap(graph.outputNode)
    guard case .composite(let composite) = output.kind else {
        throw TestGraphError.expectedComposite
    }
    return try XCTUnwrap(composite.inputs.first)
}

private func rectangleMask(in graph: RenderGraph) throws -> ClipRectangleMask {
    let input = try compositeInput(in: graph)
    let mask = try XCTUnwrap(input.effects.masks.first)
    guard case .rectangle(let rectangle) = mask.shape else {
        throw TestGraphError.expectedRectangleMask
    }
    return rectangle
}

private func makeProject(mediaPool: [MediaRef], sequences: [Sequence]) throws -> Project {
    Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 1_920, height: 1_080),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: mediaPool,
        sequences: sequences
    )
}

private func makeSequence(with clip: Clip) throws -> Sequence {
    Sequence(
        id: try uuid(800),
        name: "Chroma key graph sequence",
        videoTracks: [Track(id: try uuid(801), kind: .video, items: [.clip(clip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

private func makeMediaRef(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 24),
            duration: try time(240),
            colorSpace: .rec709,
            audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func makeClip(
    id: UUID,
    mediaID: UUID,
    effectsAnimation: AnimatableClipEffects
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try range(startFrame: 0, durationFrames: 24),
        timelineRange: try range(startFrame: 0, durationFrames: 24),
        kind: .video,
        name: "Chroma key graph clip",
        effects: effectsAnimation.baseEffects,
        effectsAnimation: effectsAnimation
    )
}

private func range(startFrame: Int64, durationFrames: Int64) throws -> TimeRange {
    try TimeRange(start: try time(startFrame), duration: try time(durationFrames))
}

private func time(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

private func rationalValue(_ numerator: Int64, _ denominator: Int64) throws -> RationalValue {
    try RationalValue(numerator: numerator, denominator: denominator)
}

private func uuid(_ value: Int) throws -> UUID {
    let uuidString = String(format: "00000000-0000-0000-0000-%012d", value)
    return try XCTUnwrap(UUID(uuidString: uuidString))
}

private enum TestGraphError: Error {
    case expectedComposite
    case expectedRectangleMask
}
