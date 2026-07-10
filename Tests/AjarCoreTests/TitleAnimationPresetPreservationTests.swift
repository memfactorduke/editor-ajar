// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-TXT-004 preservation paths: legacy decode, blade/copy, content-hash identity.
final class TitleAnimationPresetPreservationTests: XCTestCase {
    func testFRTXT004NestedLegacyDecodeDefaultsRevealFractionToOne() throws {
        let seed = 9_190
        let project = try makeNestedTitleCompoundForPreset(seed: seed)
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let stripped = try titleProjectJSONWithoutKey("revealFraction", in: package.projectJSON)
        let legacyProjectJSON = try jsonSettingSchemaMinor(6, in: stripped)
        let legacyMediaJSON = try jsonSettingSchemaMinor(6, in: package.mediaJSON)
        let loaded = try editableTitleProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: legacyMediaJSON
            )
        )
        XCTAssertTrue(loaded.validate().isValid)
        XCTAssertEqual(loaded.schemaMinor, 6)
        let innerSequenceID = try editUUID(seed * 1_000 + 300)
        let inner = try XCTUnwrap(loaded.sequences.first { $0.id == innerSequenceID })
        guard case .clip(let nestedClip) = inner.videoTracks[0].items[0] else {
            return XCTFail("expected nested title clip")
        }
        let title = try titleSource(from: nestedClip)
        XCTAssertEqual(title.revealFraction, .constant(.one))
        XCTAssertEqual(title.revealFraction.base, .one)
        XCTAssertTrue(title.revealFraction.keyframes.isEmpty)
    }

    func testFRTXT004BladeAndCopyPreserveRevealFractionProgram() throws {
        let fixture = try makeTitleProjectFixture(seed: 9_191)
        let applied = try EditReducer.apply(
            .applyTitleAnimationPreset(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                preset: TitleAnimationPreset(kind: .typewriter, duration: try editTime(8))
            ),
            to: fixture.project
        )
        let rightClipID = try editUUID(9_191_090)
        let bladed = try EditReducer.apply(
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                atTime: try editTime(4),
                rightClipID: rightClipID
            ),
            to: applied
        )
        try assertBladeRevealParity(
            applied: applied,
            bladed: bladed,
            fixture: fixture,
            rightClipID: rightClipID
        )
    }

    func testFRTXT004ContentHashIncludesRevealFraction() throws {
        let fixture = try makeTitleProjectFixture(seed: 9_192)
        let applied = try EditReducer.apply(
            .applyTitleAnimationPreset(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                preset: TitleAnimationPreset(kind: .typewriter, duration: try editTime(8))
            ),
            to: fixture.project
        )
        let sequence = try XCTUnwrap(
            applied.sequences.first { $0.id == fixture.sequenceID }
        )
        let startHash = try firstTitleRenderNode(
            in: try buildRenderGraph(for: sequence, at: try editTime(0), in: applied)
        ).contentHash
        let midHash = try firstTitleRenderNode(
            in: try buildRenderGraph(for: sequence, at: try editTime(4), in: applied)
        ).contentHash
        let endHash = try firstTitleRenderNode(
            in: try buildRenderGraph(for: sequence, at: try editTime(8), in: applied)
        ).contentHash
        XCTAssertNotEqual(startHash, midHash)
        XCTAssertNotEqual(midHash, endHash)
        XCTAssertNotEqual(startHash, endHash)
        let startHash2 = try firstTitleRenderNode(
            in: try buildRenderGraph(for: sequence, at: try editTime(0), in: applied)
        ).contentHash
        XCTAssertEqual(startHash2, startHash)
    }

    private func assertBladeRevealParity(
        applied: Project,
        bladed: Project,
        fixture: TitleProjectFixture,
        rightClipID: UUID
    ) throws {
        let left = try titleClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: bladed,
            sequenceID: fixture.sequenceID
        )
        let right = try titleClip(
            rightClipID,
            trackID: fixture.videoTrackID,
            in: bladed,
            sequenceID: fixture.sequenceID
        )
        let original = try titleClip(
            fixture.clipID,
            trackID: fixture.videoTrackID,
            in: applied,
            sequenceID: fixture.sequenceID
        )
        let leftTitle = try titleSource(from: left)
        let rightTitle = try titleSource(from: right)
        let originalTitle = try titleSource(from: original)
        let cut = try editTime(4)
        XCTAssertEqual(
            leftTitle.revealFraction.value(at: cut),
            originalTitle.revealFraction.value(at: cut)
        )
        XCTAssertEqual(
            rightTitle.revealFraction.value(at: cut),
            originalTitle.revealFraction.value(at: cut)
        )
        XCTAssertEqual(
            leftTitle.revealFraction.value(at: try editTime(0)),
            originalTitle.revealFraction.value(at: try editTime(0))
        )
        XCTAssertEqual(
            rightTitle.revealFraction.value(at: try editTime(8)),
            originalTitle.revealFraction.value(at: try editTime(8))
        )
        let copied = EditReducer.copying(
            left,
            timelineRange: try editRange(startFrame: 20, durationFrames: 5)
        )
        let copiedTitle = try titleSource(from: copied)
        XCTAssertEqual(copiedTitle.revealFraction, leftTitle.revealFraction)
        XCTAssertEqual(copiedTitle.boxes, leftTitle.boxes)
    }
}
