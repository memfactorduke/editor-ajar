// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

struct TitleProjectFixture {
    let project: Project
    let sequenceID: UUID
    let videoTrackID: UUID
    let clipID: UUID
    let titleSource: TitleSource
}

func makeTitleProjectFixture(seed: Int) throws -> TitleProjectFixture {
    let base = try makeEditFixture(seed: seed)
    let title = try makeSampleTitle(seed: seed)
    let clip = Clip(
        id: base.clipID,
        source: .title(title),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Title \(seed)"
    )
    let project = try replacingVideoItems([.clip(clip)], in: base)
    return TitleProjectFixture(
        project: project,
        sequenceID: base.sequenceID,
        videoTrackID: base.videoTrackID,
        clipID: base.clipID,
        titleSource: title
    )
}

func makeSampleTitle(seed: Int) throws -> TitleSource {
    TitleSource(boxes: [
        TitleTextBox(
            id: try editUUID(seed * 1_000 + 50),
            text: "Title \(seed)",
            origin: CanvasPoint(x: RationalValue(16), y: RationalValue(16)),
            width: RationalValue(200),
            height: RationalValue(48),
            style: TitleTextStyle(
                fontFamily: TitleSource.deterministicFontFamily,
                fontSize: RationalValue(32),
                fontWeight: .bold,
                color: ClipRGBColor(red: .one, green: .one, blue: .one),
                alignment: .left
            )
        )
    ])
}

func editableTitleProject(from result: AjarProjectLoadResult) throws -> Project {
    switch result {
    case .editable(let project):
        return project
    case .readOnly:
        XCTFail("Expected editable project")
        throw AjarProjectCodecError.malformedProjectJSON("unexpected read-only result")
    }
}

func titleProjectJSONWithoutKey(_ key: String, in data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    let stripped = try titleStrippingKey(key, from: object)
    return try JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
}

func titleStrippingKey(_ key: String, from value: Any) throws -> Any {
    if var dictionary = value as? [String: Any] {
        dictionary.removeValue(forKey: key)
        for (nestedKey, nested) in dictionary {
            dictionary[nestedKey] = try titleStrippingKey(key, from: nested)
        }
        return dictionary
    }
    if let array = value as? [Any] {
        return try array.map { try titleStrippingKey(key, from: $0) }
    }
    return value
}

func titleClip(
    _ clipID: UUID,
    trackID: UUID,
    in project: Project,
    sequenceID: UUID
) throws -> Clip {
    try requiredClip(clipID, trackID: trackID, in: project, sequenceID: sequenceID)
}
