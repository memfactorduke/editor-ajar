// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-COL-002 color-curve model: interpolation, validation, codec, graph, blade/parity.
final class ClipCurvesEffectTests: XCTestCase {
    // MARK: - Interpolation unit / property

    func testFRCOL002IdentityCurveIsExactOnUnitInterval() {
        let curve = ColorCurve.identity
        // Structural identity is bit-exact passthrough (no Hermite float noise).
        for sample in stride(from: Float(0), through: 1, by: 0.01) {
            XCTAssertEqual(curve.evaluate(at: sample), sample)
        }
        let ramp = curve.bakeRamp()
        XCTAssertEqual(ramp.count, ColorCurveLimits.rampSampleCount)
        for (index, value) in ramp.enumerated() {
            let expected = Float(index) / Float(ColorCurveLimits.rampSampleCount - 1)
            XCTAssertEqual(value, expected, "identity ramp[\(index)]")
        }
    }

    func testFRCOL002MonotoneCubicPreservesMonotonicity() {
        let curve = ColorCurve.rgbSCurve
        XCTAssertEqual(curve.validated(), .success(curve))
        var previous = curve.evaluate(at: 0)
        for sample in stride(from: Float(0.01), through: 1, by: 0.005) {
            let value = curve.evaluate(at: sample)
            XCTAssertGreaterThanOrEqual(
                value + 1.0e-5,
                previous,
                "S-curve must stay non-decreasing at \(sample)"
            )
            previous = value
        }
    }

    func testFRCOL002PassesThroughControlPoints() {
        let curve = ColorCurve.redLift
        for point in curve.points {
            XCTAssertEqual(curve.evaluate(at: point.x), point.y, accuracy: 1.0e-5)
        }
    }

    func testFRCOL002ValidationTypedErrors() {
        XCTAssertEqual(
            ColorCurve(points: [ColorCurveControlPoint(x: 0, y: 0)]).validated(),
            .failure(.pointCountOutOfRange(1))
        )
        let tooMany = (0..<17).map { index in
            ColorCurveControlPoint(x: Float(index) / 16, y: Float(index) / 16)
        }
        XCTAssertEqual(
            ColorCurve(points: tooMany).validated(),
            .failure(.pointCountOutOfRange(17))
        )
        let outOfRange = ColorCurve(
            points: [
                ColorCurveControlPoint(x: 0, y: 0),
                ColorCurveControlPoint(x: 1.5, y: 0.5)
            ]
        )
        if case .failure(.pointOutOfUnitRange(index: 1, _)) = outOfRange.validated() {
            // expected
        } else {
            XCTFail("expected pointOutOfUnitRange")
        }
        let nonIncreasing = ColorCurve(
            points: [
                ColorCurveControlPoint(x: 0, y: 0),
                ColorCurveControlPoint(x: 0.5, y: 0.5),
                ColorCurveControlPoint(x: 0.5, y: 0.6)
            ]
        )
        switch nonIncreasing.validated() {
        case .failure(.xNotStrictlyIncreasing(index: 2, previousX: 0.5, x: 0.5)):
            break
        default:
            XCTFail("expected xNotStrictlyIncreasing")
        }
    }

    /// NaN fails every range comparison; validation must reject with the typed unit-range error.
    func testFRCOL002ValidationRejectsNaNControlPoint() {
        let nanX = ColorCurve(
            points: [
                ColorCurveControlPoint(x: 0, y: 0),
                ColorCurveControlPoint(x: Float.nan, y: 0.5)
            ]
        )
        switch nanX.validated() {
        case .failure(.pointOutOfUnitRange(index: 1, let point)):
            XCTAssertTrue(point.x.isNaN)
        default:
            XCTFail("expected pointOutOfUnitRange for NaN x")
        }

        let nanY = ColorCurve(
            points: [
                ColorCurveControlPoint(x: 0, y: 0),
                ColorCurveControlPoint(x: 1, y: Float.nan)
            ]
        )
        switch nanY.validated() {
        case .failure(.pointOutOfUnitRange(index: 1, let point)):
            XCTAssertTrue(point.y.isNaN)
        default:
            XCTFail("expected pointOutOfUnitRange for NaN y")
        }
    }

    func testFRCOL002StackValidationSurfacesChannelAndStrength() throws {
        let badCurve = ColorCurve(points: [ColorCurveControlPoint(x: 0, y: 0)])
        let stack = ClipEffectStack(
            nodes: [
                ClipEffectNode(
                    id: try curvesUUID(100),
                    definition: .curves(
                        ClipCurvesEffectParameters(
                            rgb: badCurve,
                            strength: try RationalValue(numerator: 3, denominator: 2)
                        )
                    )
                )
            ]
        )
        let errors = ClipEffectStackValidator.errors(for: stack)
        XCTAssertTrue(
            errors.contains {
                if case .curvesInvalid(channel: .rgb, error: .pointCountOutOfRange(1)) = $0 {
                    return true
                }
                return false
            }
        )
        XCTAssertTrue(
            errors.contains {
                if case .curvesStrengthOutOfRange = $0 {
                    return true
                }
                return false
            }
        )
    }

    // MARK: - Codable + nested-legacy

    func testFRCOL002TypedStackCodableRoundTrip() throws {
        let stack = try representativeCurvesStack()
        let encoded = try JSONEncoder().encode(stack)
        XCTAssertEqual(try JSONDecoder().decode(ClipEffectStack.self, from: encoded), stack)
    }

    func testFRCOL002NestedLegacyMissingFieldsDefaultIdentity() throws {
        let json = Data(
            """
            {
              "kind": "curves",
              "parameters": {}
            }
            """.utf8
        )
        let decoded = try JSONDecoder().decode(ClipEffectDefinition.self, from: json)
        guard case .curves(let parameters) = decoded else {
            return XCTFail("expected curves")
        }
        XCTAssertEqual(parameters.rgb, .identity)
        XCTAssertEqual(parameters.red, .identity)
        XCTAssertEqual(parameters.green, .identity)
        XCTAssertEqual(parameters.blue, .identity)
        XCTAssertEqual(parameters.strength, .one)
    }

    func testFRCOL002ProjectCodecRoundTripPreservesCurves() throws {
        let stack = try representativeCurvesStack()
        let project = try curvesProject(stack: stack)
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let loaded = try AjarProjectCodec.decode(
            projectJSON: package.projectJSON,
            mediaJSON: package.mediaJSON
        )
        guard case .editable(let restored) = loaded else {
            return XCTFail("expected editable open")
        }
        XCTAssertEqual(restored.schemaMinor, AjarProjectCodec.currentSchemaMinor)
        XCTAssertEqual(AjarProjectCodec.currentSchemaMinor, 10)
        let clip = try XCTUnwrap(
            restored.sequences.first?.videoTracks.first?.items.compactMap { item -> Clip? in
                if case .clip(let clip) = item {
                    return clip
                }
                return nil
            }.first
        )
        XCTAssertEqual(clip.effectStack, stack)
        guard case .curves(let parameters) = clip.effectStack.nodes[0].definition else {
            return XCTFail("expected curves node")
        }
        XCTAssertEqual(parameters.rgb, .rgbSCurve)
        XCTAssertEqual(parameters.red, .redLift)
    }

    // MARK: - Blade / parity / graph

    func testFRCOL002BladeSplitsStrengthOnly() throws {
        let start = RationalTime.zero
        let end = try RationalTime(value: 1, timescale: 1)
        let mid = try RationalTime(value: 1, timescale: 2)
        let strength = try Animatable(
            base: RationalValue.zero,
            keyframes: [
                Keyframe(time: start, value: RationalValue.zero, interpolation: .linear),
                Keyframe(time: end, value: RationalValue.one, interpolation: .linear)
            ]
        )
        let animated = AnimatableClipEffectDefinition.curves(
            AnimatableClipCurvesSettings(
                rgb: .rgbSCurve,
                strength: strength
            )
        )
        let bladed = try animated.bladed(at: mid)
        guard case .curves(let left) = bladed.left,
            case .curves(let right) = bladed.right
        else {
            return XCTFail("expected curves on both sides")
        }
        XCTAssertEqual(left.rgb, .rgbSCurve)
        XCTAssertEqual(right.rgb, .rgbSCurve)
        XCTAssertEqual(left.strength.value(at: start), .zero)
        XCTAssertEqual(right.strength.value(at: end), .one)
    }

    func testFRCOL002RenderGraphRoundTripNonIdentity() throws {
        let expected = try representativeCurvesStack()
        let graph = try curvesRenderGraph(stack: expected)
        let encoded = try JSONEncoder().encode(graph)
        let decoded = try JSONDecoder().decode(RenderGraph.self, from: encoded)
        guard case .composite(let composite) = decoded.outputNode?.kind else {
            return XCTFail("expected composite graph output")
        }
        let carried = try XCTUnwrap(composite.inputs.first?.effectStack)
        XCTAssertEqual(carried, expected)
        XCTAssertEqual(carried.nodes.map(\.kind), [.curves])
        XCTAssertNotEqual(
            carried.nodes[0].definition,
            ClipEffectDefinition.identity(for: .curves)
        )
    }

    func testFRCOL002SchemaMinorAndKindRegistration() {
        XCTAssertGreaterThanOrEqual(AjarProjectCodec.currentSchemaMinor, 8)
        XCTAssertEqual(AjarProjectCodec.currentSchemaMinor, 10)
        XCTAssertTrue(ClipEffectKind.allCases.contains(.curves))
        XCTAssertEqual(ClipEffectKind.curves.rawValue, "curves")
    }

    func testFRCOL002RampDigestStableAndContentSensitive() {
        let a = ClipCurvesEffectParameters(rgb: .rgbSCurve)
        let b = ClipCurvesEffectParameters(rgb: .rgbSCurve)
        let lifted = ClipCurvesEffectParameters(red: .redLift)
        XCTAssertEqual(a.rampContentDigest, b.rampContentDigest)
        XCTAssertNotEqual(a.rampContentDigest, lifted.rampContentDigest)
    }
}

// MARK: - Fixtures

private func representativeCurvesStack() throws -> ClipEffectStack {
    ClipEffectStack(
        nodes: [
            ClipEffectNode(
                id: try curvesUUID(200),
                definition: .curves(
                    ClipCurvesEffectParameters(
                        rgb: .rgbSCurve,
                        red: .redLift,
                        strength: .one
                    )
                )
            )
        ]
    )
}

private func curvesProject(stack: ClipEffectStack) throws -> Project {
    let mediaID = try curvesUUID(300)
    let frameRate = try FrameRate(frames: 24)
    let duration = try RationalTime.atFrame(24, frameRate: frameRate)
    let media = MediaRef(
        id: mediaID,
        sourceURL: URL(fileURLWithPath: "/media/curves.mov"),
        contentHash: ContentHash.sha256(data: Data(mediaID.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 96, height: 96),
            frameRate: frameRate,
            duration: duration,
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
    let clip = Clip(
        id: try curvesUUID(301),
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: .zero, duration: duration),
        timelineRange: try TimeRange(start: .zero, duration: duration),
        kind: .video,
        name: "Curves",
        effectStack: stack
    )
    let sequence = Sequence(
        id: try curvesUUID(302),
        name: "Curves sequence",
        videoTracks: [
            Track(id: try curvesUUID(303), kind: .video, items: [.clip(clip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: frameRate
    )
    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: frameRate,
            resolution: PixelDimensions(width: 96, height: 96),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [media],
        sequences: [sequence]
    )
}

private func curvesRenderGraph(stack: ClipEffectStack) throws -> RenderGraph {
    let project = try curvesProject(stack: stack)
    let sequence = try XCTUnwrap(project.sequences.first)
    return try buildRenderGraph(
        for: sequence,
        at: try RationalTime.atFrame(0, frameRate: sequence.timebase),
        in: project
    )
}

private func curvesUUID(_ value: Int) throws -> UUID {
    let string = String(format: "00000000-0000-0000-0000-%012d", value)
    guard let uuid = UUID(uuidString: string) else {
        throw NSError(
            domain: "ClipCurvesEffectTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "bad uuid \(value)"]
        )
    }
    return uuid
}
