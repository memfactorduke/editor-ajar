// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import XCTest

@testable import AjarRender

/// FR-COL-007 render-level proof that fresh copied-node IDs do not change grade pixels.
final class MetalCopiedGradeRenderTests: XCTestCase {
    func testFRCOL007CopiedGradeRendersBitIdenticalOnIdenticalClip() throws {
        let device = try effectStackMetalDeviceOrSkip()
        let fixture = try makeGradeCopyRenderFixture()
        let copiedProject = try apply(
            .copyClipGrade(
                source: fixture.source,
                target: fixture.target,
                newNodeIDs: fixture.newNodeIDs
            ),
            to: fixture.project
        )
        let sourceClip = try gradeClip(fixture.source, in: copiedProject)
        let targetClip = try gradeClip(fixture.target, in: copiedProject)

        XCTAssertEqual(
            sourceClip.effectStack.nodes.map(\.definition),
            targetClip.effectStack.nodes.map(\.definition)
        )
        XCTAssertNotEqual(
            sourceClip.effectStack.nodes.map(\.id),
            targetClip.effectStack.nodes.map(\.id)
        )
        XCTAssertEqual(targetClip.effectStack.nodes.map(\.id), fixture.newNodeIDs)

        let size = 16
        let sourceTexture = try makeCheckerboardTexture(device: device, size: size, cellSize: 2)
        let sourcePixels = try renderEffectStackGraph(
            device: device,
            source: sourceTexture,
            size: size,
            graph: try makeEffectStackGraph(size: size, stack: sourceClip.effectStack)
        )
        let copiedPixels = try renderEffectStackGraph(
            device: device,
            source: sourceTexture,
            size: size,
            graph: try makeEffectStackGraph(size: size, stack: targetClip.effectStack)
        )

        XCTAssertEqual(sourcePixels, copiedPixels)
        XCTAssertEqual(
            ContentHash.sha256(data: Data(sourcePixels)),
            ContentHash.sha256(data: Data(copiedPixels))
        )
    }
}

private struct GradeCopyRenderFixture {
    let project: Project
    let source: ProjectClipReference
    let target: ProjectClipReference
    let newNodeIDs: [UUID]
}

private func makeGradeCopyRenderFixture() throws -> GradeCopyRenderFixture {
    let mediaID = try effectStackUUID(9_301)
    let sequenceID = try effectStackUUID(9_302)
    let sourceTrackID = try effectStackUUID(9_303)
    let targetTrackID = try effectStackUUID(9_304)
    let sourceClipID = try effectStackUUID(9_305)
    let targetClipID = try effectStackUUID(9_306)
    let media = try effectStackMediaRef(id: mediaID, size: 16, path: "/media/copied-grade.mov")
    let range = try TimeRange(start: .zero, duration: media.metadata.duration)
    let sourceStack = try renderGradeStack()
    let sourceClip = Clip(
        id: sourceClipID,
        source: .media(id: mediaID),
        sourceRange: range,
        timelineRange: range,
        kind: .video,
        name: "Grade source",
        effectStack: sourceStack
    )
    let targetClip = Clip(
        id: targetClipID,
        source: .media(id: mediaID),
        sourceRange: range,
        timelineRange: range,
        kind: .video,
        name: "Grade target",
        effectStack: try initialTargetGradeStack()
    )
    let sequence = Sequence(
        id: sequenceID,
        name: "Copied grade render",
        videoTracks: [
            Track(id: sourceTrackID, kind: .video, items: [.clip(sourceClip)]),
            Track(id: targetTrackID, kind: .video, items: [.clip(targetClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    return GradeCopyRenderFixture(
        project: Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: try effectStackProjectSettings(size: 16),
            mediaPool: [media],
            sequences: [sequence]
        ),
        source: ProjectClipReference(
            sequenceID: sequenceID,
            trackID: sourceTrackID,
            clipID: sourceClipID
        ),
        target: ProjectClipReference(
            sequenceID: sequenceID,
            trackID: targetTrackID,
            clipID: targetClipID
        ),
        newNodeIDs: try (9_330...9_334).map(effectStackUUID)
    )
}

private func initialTargetGradeStack() throws -> ClipEffectStack {
    ClipEffectStack(
        nodes: [
            ClipEffectNode(
                id: try effectStackUUID(9_320),
                definition: .invert(ClipInvertParameters())
            )
        ]
    )
}

private func renderGradeStack() throws -> ClipEffectStack {
    ClipEffectStack(
        nodes: [
            ClipEffectNode(
                id: try effectStackUUID(9_310),
                definition: .colorAdjust(
                    ClipColorAdjustParameters(
                        brightness: try RationalValue(numerator: 1, denominator: 10),
                        contrast: try RationalValue(numerator: 6, denominator: 5),
                        saturation: try RationalValue(numerator: 4, denominator: 5),
                        tint: try RationalValue(numerator: 1, denominator: 10)
                    )
                )
            ),
            ClipEffectNode(
                id: try effectStackUUID(9_311),
                definition: .curves(
                    ClipCurvesEffectParameters(rgb: .rgbSCurve, strength: .one)
                )
            ),
            ClipEffectNode(
                id: try effectStackUUID(9_312),
                definition: .lut(
                    ClipLUTEffectParameters(table: .identityOneD, strength: .one)
                )
            ),
            ClipEffectNode(
                id: try effectStackUUID(9_313),
                definition: .posterize(ClipPosterizeParameters(levels: RationalValue(8)))
            ),
            ClipEffectNode(
                id: try effectStackUUID(9_314),
                definition: .invert(ClipInvertParameters())
            )
        ]
    )
}

private func gradeClip(_ reference: ProjectClipReference, in project: Project) throws -> Clip {
    let sequence = try XCTUnwrap(
        project.sequences.first(where: { $0.id == reference.sequenceID })
    )
    let track = try XCTUnwrap(
        sequence.videoTracks.first(where: { $0.id == reference.trackID })
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
