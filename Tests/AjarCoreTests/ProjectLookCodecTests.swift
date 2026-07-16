// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-COL-007 project-look persistence and legacy-default coverage.
final class ProjectLookCodecTests: XCTestCase {
    func testFRCOL007ColorGradeKindSetIsExact() {
        XCTAssertEqual(
            Set(ClipEffectKind.allCases.filter(\.isColorGrade)),
            Set([.colorAdjust, .curves, .lut, .posterize, .invert])
        )
    }

    func testFRCOL007LooksRoundTripInProjectJSONOnlyAtSchemaMinorNine() throws {
        let fixture = try makeCompoundClipFixture(seed: 9_100)
        let look = try representativeProjectLook(seed: 9_100)
        let project = project(fixture.project, looks: [look])

        let package = try AjarProjectCodec.encodeNewDocument(project)
        let projectObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: package.projectJSON) as? [String: Any]
        )
        let mediaObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: package.mediaJSON) as? [String: Any]
        )
        let storedLooks = try XCTUnwrap(projectObject["looks"] as? [[String: Any]])

        XCTAssertEqual(AjarProjectCodec.currentSchemaMinor, 15)
        XCTAssertEqual(storedLooks.count, 1)
        XCTAssertNil(mediaObject["looks"], "looks belong in project.json, not media.json")

        let loaded = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        XCTAssertEqual(loaded, project)
        XCTAssertEqual(loaded.looks, [look])
        XCTAssertTrue(loaded.validate().isValid)
    }

    func testFRCOL007NestedLegacyProjectWithoutLooksDefaultsEmpty() throws {
        let fixture = try makeCompoundClipFixture(seed: 9_110)
        let look = try representativeProjectLook(seed: 9_110)
        let package = try AjarProjectCodec.encodeNewDocument(
            project(fixture.project, looks: [look])
        )
        let legacyProjectJSON = try legacyJSON(
            package.projectJSON,
            removing: "looks",
            schemaMinor: 8
        )
        let legacyMediaJSON = try legacyJSON(
            package.mediaJSON,
            removing: nil,
            schemaMinor: 8
        )

        let loaded = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: legacyMediaJSON
            )
        )

        XCTAssertEqual(loaded.schemaMinor, 8)
        XCTAssertEqual(loaded.looks, [])
        XCTAssertEqual(loaded.sequences, fixture.project.sequences)
        XCTAssertEqual(loaded.mediaPool, fixture.project.mediaPool)
        XCTAssertTrue(loaded.validate().isValid)
        XCTAssertEqual(
            try requiredCompoundClip(in: loaded, fixture: fixture).source,
            .sequence(id: fixture.innerSequenceID)
        )
    }

    func testFRCOL007UnrelatedProjectEditsPreserveLooks() throws {
        let fixture = try makeCompoundClipFixture(seed: 9_120)
        let look = try representativeProjectLook(seed: 9_120)
        let project = project(fixture.project, looks: [look])

        let renamed = try apply(
            .renameSequence(sequenceID: fixture.outerSequenceID, name: "Renamed"),
            to: project
        )
        XCTAssertEqual(renamed.looks, [look])

        let settings = ProjectSettings(
            frameRate: project.settings.frameRate,
            resolution: PixelDimensions(width: 1_280, height: 720),
            colorSpace: project.settings.colorSpace,
            audioSampleRate: project.settings.audioSampleRate
        )
        let settingsChanged = try apply(.setProjectSettings(settings), to: renamed)
        XCTAssertEqual(settingsChanged.looks, [look])
    }

    func testFRCOL007PersistedLookValidationReturnsIdentityNameAndEmptyErrors() throws {
        let fixture = try makeCompoundClipFixture(seed: 9_130)
        let valid = try representativeProjectLook(seed: 9_130)
        let duplicateID = ProjectLook(id: valid.id, name: "Other", grade: valid.grade)
        let duplicateName = ProjectLook(
            id: try editUUID(9_130_200),
            name: " WARM FILM ",
            grade: valid.grade
        )
        let empty = ProjectLook(
            id: try editUUID(9_130_201),
            name: "Empty",
            grade: .empty
        )
        let candidate = project(
            fixture.project,
            looks: [valid, duplicateID, duplicateName, empty]
        )

        guard case .invalid(let errors) = candidate.validate() else {
            return XCTFail("expected invalid persisted looks")
        }
        XCTAssertTrue(errors.contains(.duplicateLookID(valid.id)))
        XCTAssertTrue(errors.contains(.duplicateLookName(" WARM FILM ")))
        XCTAssertTrue(
            errors.contains(.invalidLook(lookID: empty.id, error: .emptyGrade))
        )
    }

    func testFRCOL007PersistedLookValidationReturnsBlankAndNonColorErrors() throws {
        let fixture = try makeCompoundClipFixture(seed: 9_130)
        let nonColorNodeID = try editUUID(9_130_203)
        let nonColor = ProjectLook(
            id: try editUUID(9_130_202),
            name: " \n ",
            grade: ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: nonColorNodeID,
                        definition: .gaussianBlur(
                            ClipGaussianBlurParameters(radius: RationalValue(1))
                        )
                    )
                ]
            )
        )
        let candidate = project(fixture.project, looks: [nonColor])

        guard case .invalid(let errors) = candidate.validate() else {
            return XCTFail("expected invalid persisted look")
        }
        XCTAssertTrue(
            errors.contains(.invalidLook(lookID: nonColor.id, error: .blankName))
        )
        XCTAssertTrue(
            errors.contains(
                .invalidLook(
                    lookID: nonColor.id,
                    error: .nonColorGradeNode(nodeID: nonColorNodeID, kind: .gaussianBlur)
                )
            )
        )
    }

    func testFRCOL007PersistedLookValidationReturnsInvalidGradeErrors() throws {
        let fixture = try makeCompoundClipFixture(seed: 9_130)
        let invalidValue = RationalValue(2)
        let invalidParameters = ProjectLook(
            id: try editUUID(9_130_204),
            name: "Invalid parameters",
            grade: ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: try editUUID(9_130_205),
                        definition: .colorAdjust(
                            ClipColorAdjustParameters(brightness: invalidValue)
                        )
                    )
                ]
            )
        )
        let candidate = project(fixture.project, looks: [invalidParameters])

        guard case .invalid(let errors) = candidate.validate() else {
            return XCTFail("expected invalid persisted look")
        }
        XCTAssertTrue(
            errors.contains(
                .invalidLook(
                    lookID: invalidParameters.id,
                    error: .invalidGrade(.colorAdjustBrightnessOutOfRange(invalidValue))
                )
            )
        )
    }
}

private func representativeProjectLook(seed: Int) throws -> ProjectLook {
    let base = seed * 1_000
    return ProjectLook(
        id: try editUUID(base + 100),
        name: "Warm Film",
        grade: ClipEffectStack(
            nodes: [
                ClipEffectNode(
                    id: try editUUID(base + 101),
                    definition: .colorAdjust(
                        ClipColorAdjustParameters(
                            brightness: try rational(1, 10),
                            contrast: try rational(6, 5),
                            saturation: try rational(4, 5),
                            tint: try rational(1, 5)
                        )
                    )
                ),
                ClipEffectNode(
                    id: try editUUID(base + 102),
                    definition: .curves(
                        ClipCurvesEffectParameters(
                            rgb: .rgbSCurve,
                            red: .redLift,
                            strength: .one
                        )
                    )
                ),
                ClipEffectNode(
                    id: try editUUID(base + 103),
                    definition: .lut(
                        ClipLUTEffectParameters(
                            table: .identityOneD,
                            strength: .one,
                            placement: .look
                        )
                    )
                ),
                ClipEffectNode(
                    id: try editUUID(base + 104),
                    definition: .posterize(
                        ClipPosterizeParameters(levels: RationalValue(8))
                    )
                ),
                ClipEffectNode(
                    id: try editUUID(base + 105),
                    definition: .invert(ClipInvertParameters())
                )
            ]
        )
    )
}

private func project(_ project: Project, looks: [ProjectLook]) -> Project {
    Project(
        schemaVersion: project.schemaVersion,
        schemaMinor: project.schemaMinor,
        settings: project.settings,
        mediaPool: project.mediaPool,
        sequences: project.sequences,
        looks: looks
    )
}

private func editableProject(from result: AjarProjectLoadResult) throws -> Project {
    guard case .editable(let project) = result else {
        XCTFail("expected editable project")
        throw ProjectLookCodecTestError.expectedEditableProject
    }
    return project
}

private func legacyJSON(
    _ data: Data,
    removing key: String?,
    schemaMinor: Int
) throws -> Data {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    if let key {
        object.removeValue(forKey: key)
    }
    object["schemaMinor"] = schemaMinor
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private enum ProjectLookCodecTestError: Error {
    case expectedEditableProject
}
