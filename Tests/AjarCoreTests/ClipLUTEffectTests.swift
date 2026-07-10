// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-COL-004 LUT effect node: validation, codec round-trip, keyframe parity, nested legacy.
final class ClipLUTEffectTests: XCTestCase {
    func testFRCOL004ValidationRejectsStrengthOutOfRange() throws {
        let table = try makeInvertCube(size: 2)
        let node = ClipEffectNode(
            id: try editUUID(6_100_100),
            definition: .lut(
                ClipLUTEffectParameters(
                    table: table,
                    strength: try RationalValue(numerator: 3, denominator: 2)
                )
            )
        )
        let errors = ClipEffectStackValidator.errors(for: ClipEffectStack(nodes: [node]))
        XCTAssertTrue(
            errors.contains { error in
                if case .lutStrengthOutOfRange = error {
                    return true
                }
                return false
            }
        )
    }

    func testFRCOL004ValidationRejectsOversizedTablePayload() throws {
        // Synthesize an invalid table (size over ceiling) without going through the parser.
        let oversized = CubeLUTTable(
            dimensions: .threeD,
            size: 65,
            entries: []
        )
        let node = ClipEffectNode(
            id: try editUUID(6_100_101),
            definition: .lut(ClipLUTEffectParameters(table: oversized, strength: .one))
        )
        let errors = ClipEffectStackValidator.errors(for: ClipEffectStack(nodes: [node]))
        XCTAssertTrue(
            errors.contains { error in
                if case .lutTableInvalid = error {
                    return true
                }
                return false
            }
        )
    }

    func testFRCOL004ProjectCodecRoundTripsLUTNode() throws {
        let fixture = try makeEditFixture(seed: 6_110)
        let table = try makeTealOrangeCube(size: 2)
        let node = ClipEffectNode(
            id: try editUUID(6_110_100),
            enabled: true,
            definition: .lut(
                ClipLUTEffectParameters(
                    table: table,
                    strength: try RationalValue(numerator: 1, denominator: 2)
                )
            )
        )
        let clip = Clip(
            id: fixture.clipID,
            source: .media(id: fixture.mediaID),
            sourceRange: try editRange(startFrame: 0, durationFrames: 10),
            timelineRange: try editRange(startFrame: 0, durationFrames: 10),
            kind: .video,
            name: "LUT media",
            effectStack: ClipEffectStack(nodes: [node])
        )
        let project = try replacingVideoItems([.clip(clip)], in: fixture)
        XCTAssertTrue(project.validate().isValid)
        XCTAssertEqual(project.schemaMinor, AjarProjectCodec.currentSchemaMinor)

        let package = try AjarProjectCodec.encodeNewDocument(project)
        let loaded = try lutEditableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let loadedClip = try requiredClip(fixture.clipID, in: loaded, fixture: fixture)
        XCTAssertEqual(loadedClip.effectStack.nodes, [node])
        XCTAssertEqual(loadedClip.effectStackAnimation, .constant(loadedClip.effectStack))
        XCTAssertEqual(loaded, project)
    }

    func testFRCOL004StrengthKeyframingEvaluatesAndPreservesOnEnableToggle() throws {
        let fixture = try makeEditFixture(seed: 6_120)
        let table = try makeInvertCube(size: 2)
        let nodeID = try editUUID(6_120_100)
        let strength = try Animatable(
            base: RationalValue.zero,
            keyframes: [
                Keyframe(
                    time: try editTime(0),
                    value: RationalValue.zero,
                    interpolation: .linear
                ),
                Keyframe(
                    time: try editTime(10),
                    value: RationalValue.one,
                    interpolation: .linear
                )
            ]
        )
        let animated = AnimatableClipEffectStack(
            nodes: [
                AnimatableClipEffectNode(
                    id: nodeID,
                    enabled: true,
                    definition: .lut(AnimatableClipLUTSettings(table: table, strength: strength))
                )
            ]
        )
        let staticStack = animated.baseStack
        let clip = Clip(
            id: fixture.clipID,
            source: .media(id: fixture.mediaID),
            sourceRange: try editRange(startFrame: 0, durationFrames: 10),
            timelineRange: try editRange(startFrame: 0, durationFrames: 10),
            kind: .video,
            name: "Keyed LUT",
            effectStack: staticStack,
            effectStackAnimation: animated
        )
        let project = try replacingVideoItems([.clip(clip)], in: fixture)
        XCTAssertTrue(project.validate().isValid)

        let mid = animated.value(at: try editTime(5))
        guard case .lut(let midParams) = mid.nodes[0].definition else {
            return XCTFail("Expected lut definition")
        }
        // Midpoint of 0→1 linear over 10 frames is ~0.5.
        XCTAssertEqual(midParams.strength.doubleValue, 0.5, accuracy: 0.001)

        let disabled = try apply(
            .setClipEffectNodeEnabled(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                nodeID: nodeID,
                enabled: false
            ),
            to: project
        )
        let disabledClip = try requiredClip(fixture.clipID, in: disabled, fixture: fixture)
        XCTAssertEqual(
            disabledClip.effectStackAnimation.nodes[0].definition,
            animated.nodes[0].definition
        )
    }

    func testFRCOL004ResetPreservesTableAndZeroesStrength() throws {
        let fixture = try makeEditFixture(seed: 6_130)
        let table = try makeTealOrangeCube(size: 2)
        let nodeID = try editUUID(6_130_100)
        let node = ClipEffectNode(
            id: nodeID,
            definition: .lut(ClipLUTEffectParameters(table: table, strength: .one))
        )
        let clip = Clip(
            id: fixture.clipID,
            source: .media(id: fixture.mediaID),
            sourceRange: try editRange(startFrame: 0, durationFrames: 10),
            timelineRange: try editRange(startFrame: 0, durationFrames: 10),
            kind: .video,
            name: "Reset LUT",
            effectStack: ClipEffectStack(nodes: [node])
        )
        let project = try replacingVideoItems([.clip(clip)], in: fixture)
        let reset = try apply(
            .resetClipEffectNode(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                nodeID: nodeID
            ),
            to: project
        )
        let resetClip = try requiredClip(fixture.clipID, in: reset, fixture: fixture)
        guard case .lut(let parameters) = resetClip.effectStack.nodes[0].definition else {
            return XCTFail("Expected lut")
        }
        XCTAssertEqual(parameters.table, table)
        XCTAssertEqual(parameters.strength, .zero)
    }

    /// Reset must constant-replace animation even when static base already matches identity.
    func testFRCOL004ResetClearsStrengthKeyframesWhenBaseAlreadyZero() throws {
        let fixture = try makeEditFixture(seed: 6_135)
        let table = try makeInvertCube(size: 2)
        let nodeID = try editUUID(6_135_100)
        let (project, animated) = try keyedZeroBaseLUTProject(
            fixture: fixture,
            nodeID: nodeID,
            table: table
        )
        guard case .lut(let beforeAnim) = animated.nodes[0].definition else {
            return XCTFail("Expected keyed lut")
        }
        XCTAssertFalse(beforeAnim.strength.keyframes.isEmpty)

        let reset = try apply(
            .resetClipEffectNode(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                nodeID: nodeID
            ),
            to: project
        )
        let resetClip = try requiredClip(fixture.clipID, in: reset, fixture: fixture)
        guard case .lut(let staticParams) = resetClip.effectStack.nodes[0].definition else {
            return XCTFail("Expected lut static")
        }
        XCTAssertEqual(staticParams.strength, .zero)
        guard case .lut(let animParams) = resetClip.effectStackAnimation.nodes[0].definition
        else {
            return XCTFail("Expected lut animation")
        }
        XCTAssertTrue(animParams.strength.keyframes.isEmpty)
        XCTAssertEqual(animParams.strength.base, .zero)
        let mid = resetClip.effectStackAnimation.value(at: try editTime(5))
        guard case .lut(let midParams) = mid.nodes[0].definition else {
            return XCTFail("Expected lut at mid")
        }
        XCTAssertEqual(midParams.strength, .zero)
    }

    func testFRCOL004PlacementDefaultsToLookAndRoundTrips() throws {
        let fixture = try makeEditFixture(seed: 6_140)
        let table = try makeInvertCube(size: 2)
        let node = ClipEffectNode(
            id: try editUUID(6_140_100),
            definition: .lut(
                ClipLUTEffectParameters(
                    table: table,
                    strength: .one,
                    placement: .input
                )
            )
        )
        let clip = Clip(
            id: fixture.clipID,
            source: .media(id: fixture.mediaID),
            sourceRange: try editRange(startFrame: 0, durationFrames: 10),
            timelineRange: try editRange(startFrame: 0, durationFrames: 10),
            kind: .video,
            name: "Placement",
            effectStack: ClipEffectStack(nodes: [node])
        )
        let project = try replacingVideoItems([.clip(clip)], in: fixture)
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let loaded = try lutEditableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let loadedClip = try requiredClip(fixture.clipID, in: loaded, fixture: fixture)
        guard case .lut(let params) = loadedClip.effectStack.nodes[0].definition else {
            return XCTFail("Expected lut")
        }
        XCTAssertEqual(params.placement, .input)

        // Absent placement key decodes as look.
        let legacyJSON = Data(
            """
            {"kind":"lut","parameters":{"table":{"dimensions":"1d","size":2,\
            "domainMin":{"r":0,"g":0,"b":0},"domainMax":{"r":1,"g":1,"b":1},\
            "entries":[{"r":0,"g":0,"b":0},{"r":1,"g":1,"b":1}]},"strength":\
            {"numerator":1,"denominator":1}}}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(ClipEffectDefinition.self, from: legacyJSON)
        guard case .lut(let legacyParams) = decoded else {
            return XCTFail("Expected lut")
        }
        XCTAssertEqual(legacyParams.placement, .look)
    }

    func testFRCOL004UnknownKindStillSurfacesTypedDecodeError() throws {
        let json = Data(
            """
            {"kind":"future-kind","parameters":{}}
            """.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(ClipEffectDefinition.self, from: json)
        ) { error in
            let effectError = nestedEffectError(from: error)
            guard case .unknownKind("future-kind") = effectError else {
                return XCTFail("Expected unknownKind, got \(String(describing: error))")
            }
        }
    }

    func testFRCOL004SchemaMinorIsTwoForLUTKind() {
        // ADR-0018: LUT gate is minor 3. Current build is 6 after FR-TXT-002 (4),
        // FR-FX-002 batch 2 (5), and FR-FX-001 transitions (6).
        XCTAssertGreaterThanOrEqual(AjarProjectCodec.currentSchemaMinor, 3)
        XCTAssertEqual(AjarProjectCodec.currentSchemaMinor, 8)
        XCTAssertTrue(ClipEffectKind.allCases.contains(.lut))
    }
}

// MARK: - Fixtures

func makeInvertCube(size: Int) throws -> CubeLUTTable {
    var entries: [CubeLUTColor] = []
    entries.reserveCapacity(size * size * size)
    let denom = Float(max(size - 1, 1))
    for blue in 0..<size {
        for green in 0..<size {
            for red in 0..<size {
                entries.append(
                    CubeLUTColor(
                        r: 1.0 - (Float(red) / denom),
                        g: 1.0 - (Float(green) / denom),
                        b: 1.0 - (Float(blue) / denom)
                    )
                )
            }
        }
    }
    let table = CubeLUTTable(
        title: "Invert \(size)",
        dimensions: .threeD,
        size: size,
        entries: entries
    )
    return try unwrapValidated(table)
}

func makeTealOrangeCube(size: Int) throws -> CubeLUTTable {
    var entries: [CubeLUTColor] = []
    entries.reserveCapacity(size * size * size)
    let denom = Float(max(size - 1, 1))
    for blue in 0..<size {
        for green in 0..<size {
            for red in 0..<size {
                let r = Float(red) / denom
                let g = Float(green) / denom
                let b = Float(blue) / denom
                // Mild teal-orange: lift blue in lows, lift red in highs.
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let outR = min(1.0, r + (luma * 0.15))
                let outG = g
                let outB = min(1.0, b + ((1.0 - luma) * 0.15))
                entries.append(CubeLUTColor(r: outR, g: outG, b: outB))
            }
        }
    }
    let table = CubeLUTTable(
        title: "TealOrange \(size)",
        dimensions: .threeD,
        size: size,
        entries: entries
    )
    return try unwrapValidated(table)
}

private func unwrapValidated(_ table: CubeLUTTable) throws -> CubeLUTTable {
    switch table.validated() {
    case .success(let valid):
        return valid
    case .failure(let error):
        throw error
    }
}

private func keyedZeroBaseLUTProject(
    fixture: EditFixture,
    nodeID: UUID,
    table: CubeLUTTable
) throws -> (Project, AnimatableClipEffectStack) {
    let strength = try Animatable(
        base: RationalValue.zero,
        keyframes: [
            Keyframe(
                time: try editTime(0),
                value: RationalValue.zero,
                interpolation: .linear
            ),
            Keyframe(
                time: try editTime(10),
                value: RationalValue.one,
                interpolation: .linear
            )
        ]
    )
    let animated = AnimatableClipEffectStack(
        nodes: [
            AnimatableClipEffectNode(
                id: nodeID,
                enabled: true,
                definition: .lut(AnimatableClipLUTSettings(table: table, strength: strength))
            )
        ]
    )
    let clip = Clip(
        id: fixture.clipID,
        source: .media(id: fixture.mediaID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Keyed reset",
        effectStack: animated.baseStack,
        effectStackAnimation: animated
    )
    return (try replacingVideoItems([.clip(clip)], in: fixture), animated)
}

private func lutEditableProject(from result: AjarProjectLoadResult) throws -> Project {
    switch result {
    case .editable(let project):
        return project
    case .readOnly:
        throw AjarProjectCodecError.malformedProjectJSON("unexpected read-only result")
    }
}

private func nestedEffectError(from error: Error) -> ClipEffectDecodingError? {
    if let effectError = error as? ClipEffectDecodingError {
        return effectError
    }
    if let decoding = error as? DecodingError {
        switch decoding {
        case .dataCorrupted(let context),
            .keyNotFound(_, let context),
            .typeMismatch(_, let context),
            .valueNotFound(_, let context):
            if let underlying = context.underlyingError {
                return nestedEffectError(from: underlying)
            }
        @unknown default:
            break
        }
    }
    let nsError = error as NSError
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        return nestedEffectError(from: underlying)
    }
    return nil
}
