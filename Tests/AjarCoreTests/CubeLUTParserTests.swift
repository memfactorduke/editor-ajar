// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-COL-004 `.cube` parser coverage: grammar, size ceilings, and fuzz-style garbage inputs.
final class CubeLUTParserTests: XCTestCase {
    func testFRCOL004ParsesMinimalIdentity1D() throws {
        let text = """
            TITLE "Identity 1D"
            LUT_1D_SIZE 2
            0.0 0.0 0.0
            1.0 1.0 1.0
            """
        let table = try unwrapSuccess(CubeLUTParser.parse(text: text))
        XCTAssertEqual(table.title, "Identity 1D")
        XCTAssertEqual(table.dimensions, .oneD)
        XCTAssertEqual(table.size, 2)
        XCTAssertEqual(table.entries.count, 2)
        XCTAssertEqual(table.entries[0], .zero)
        XCTAssertEqual(table.entries[1], .one)
    }

    func testFRCOL004Parses3DWithDomainAndComments() throws {
        let text = """
            # comment header
            TITLE TealOrange
            LUT_3D_SIZE 2
            DOMAIN_MIN 0.0 0.0 0.0
            DOMAIN_MAX 1.0 1.0 1.0

            0 0 0
            1 0 0
            0 1 0
            1 1 0
            0 0 1
            1 0 1
            0 1 1
            1 1 1
            """
        let table = try unwrapSuccess(CubeLUTParser.parse(text: text))
        XCTAssertEqual(table.dimensions, .threeD)
        XCTAssertEqual(table.size, 2)
        XCTAssertEqual(table.entries.count, 8)
        XCTAssertEqual(table.domainMin, .zero)
        XCTAssertEqual(table.domainMax, .one)
        XCTAssertEqual(table.title, "TealOrange")
    }

    func testFRCOL004DataBytesRoundTripThroughParseData() throws {
        let text = "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n"
        let table = try unwrapSuccess(CubeLUTParser.parse(data: Data(text.utf8)))
        XCTAssertEqual(table.size, 2)
    }

    func testFRCOL004RejectsMissingSize() {
        let result = CubeLUTParser.parse(text: "0 0 0\n1 1 1\n")
        guard case .failure(.missingSize) = result else {
            return XCTFail("Expected missingSize, got \(result)")
        }
    }

    func testFRCOL004RejectsConflictingSizes() {
        let text = """
            LUT_1D_SIZE 2
            LUT_3D_SIZE 2
            0 0 0
            1 1 1
            """
        let result = CubeLUTParser.parse(text: text)
        guard case .failure(.duplicateOrConflictingSize) = result else {
            return XCTFail("Expected duplicateOrConflictingSize, got \(result)")
        }
    }

    func testFRCOL004Rejects3DSizeAboveCeiling() {
        let text = "LUT_3D_SIZE 65\n"
        let result = CubeLUTParser.parse(text: text)
        guard case .failure(.sizeOutOfRange(_, 65, .threeD)) = result else {
            return XCTFail("Expected sizeOutOfRange for 65, got \(result)")
        }
    }

    func testFRCOL004Rejects1DSizeAboveCeiling() {
        let text = "LUT_1D_SIZE 4097\n"
        let result = CubeLUTParser.parse(text: text)
        guard case .failure(.sizeOutOfRange(_, 4097, .oneD)) = result else {
            return XCTFail("Expected sizeOutOfRange for 4097, got \(result)")
        }
    }

    func testFRCOL004RejectsEntryCountMismatch() {
        let text = """
            LUT_1D_SIZE 2
            0 0 0
            """
        let result = CubeLUTParser.parse(text: text)
        guard case .failure(.entryCountMismatch(expected: 2, actual: 1)) = result else {
            return XCTFail("Expected entryCountMismatch, got \(result)")
        }
    }

    func testFRCOL004RejectsMalformedDataRow() {
        let text = """
            LUT_1D_SIZE 2
            0 0
            1 1 1
            """
        let result = CubeLUTParser.parse(text: text)
        guard case .failure(.malformedDataRow) = result else {
            return XCTFail("Expected malformedDataRow, got \(result)")
        }
    }

    func testFRCOL004RejectsNonFiniteFloat() {
        let text = """
            LUT_1D_SIZE 2
            nan 0 0
            1 1 1
            """
        let result = CubeLUTParser.parse(text: text)
        guard case .failure(.malformedFloat) = result else {
            return XCTFail("Expected malformedFloat, got \(result)")
        }
    }

    func testFRCOL004RejectsInvalidUTF8() {
        let data = Data([0xFF, 0xFE, 0xFD])
        let result = CubeLUTParser.parse(data: data)
        guard case .failure(.invalidUTF8) = result else {
            return XCTFail("Expected invalidUTF8, got \(result)")
        }
    }

    func testFRCOL004RejectsEmptyInput() {
        let result = CubeLUTParser.parse(text: "   \n# only comments\n")
        guard case .failure(.emptyInput) = result else {
            return XCTFail("Expected emptyInput, got \(result)")
        }
    }

    /// Fuzz-style sweep: truncated, garbage, and mixed inputs must never trap and always
    /// produce a typed parse error or a successfully validated table (NFR-STAB-003).
    func testFRCOL004FuzzStyleGarbageNeverTraps() {
        let seeds: [Data] = [
            Data(),
            Data("LUT_3D_SIZE 2\n".utf8),
            Data("LUT_1D_SIZE 2\n0 0 0\n1 1".utf8),
            Data([0x00, 0x01, 0x02, 0xFF]),
            Data(repeating: 0x41, count: 256),
            Data("TITLE \"x\nLUT_3D_SIZE abc\n".utf8),
            Data("DOMAIN_MIN 1\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n".utf8),
            Data("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n".utf8),
            Data("#\n\n\tLUT_1D_SIZE\t2\n0.0\t0.0\t0.0\n1.0\t1.0\t1.0\n".utf8)
        ]

        for (index, data) in seeds.enumerated() {
            let result = CubeLUTParser.parse(data: data)
            switch result {
            case .success(let table):
                XCTAssertEqual(
                    table.validated().map(\.size).getOrNil(),
                    table.size,
                    "seed \(index) produced invalid success"
                )
            case .failure(let error):
                XCTAssertFalse(error.message.isEmpty, "seed \(index) empty message")
            }
        }
    }

    func testFRCOL004TableValidationRejectsMismatchedEntries() {
        let table = CubeLUTTable(
            dimensions: .threeD,
            size: 2,
            entries: [.zero, .one]
        )
        guard case .failure(.entryCountMismatch) = table.validated() else {
            return XCTFail("Expected entryCountMismatch")
        }
    }

    func testFRCOL004RejectsTooManyDataRowsBeforeAccumulating() {
        let text = """
            LUT_1D_SIZE 2
            0 0 0
            1 1 1
            0.5 0.5 0.5
            """
        let result = CubeLUTParser.parse(text: text)
        guard case .failure(.tooManyDataRows(_, 2)) = result else {
            return XCTFail("Expected tooManyDataRows, got \(result)")
        }
    }

    func testFRCOL004RejectsDomainMinNotLessThanMax() {
        let text = """
            LUT_1D_SIZE 2
            DOMAIN_MIN 1 0 0
            DOMAIN_MAX 0 1 1
            0 0 0
            1 1 1
            """
        let result = CubeLUTParser.parse(text: text)
        guard case .failure(.domainMinNotLessThanMax("r")) = result else {
            return XCTFail("Expected domainMinNotLessThanMax, got \(result)")
        }
    }

    func testFRCOL004ContentDigestIsStableAndIgnoresTitle() {
        let a = CubeLUTTable(
            title: "A",
            dimensions: .oneD,
            size: 2,
            entries: [.zero, .one]
        )
        let b = CubeLUTTable(
            title: "B",
            dimensions: .oneD,
            size: 2,
            entries: [.zero, .one]
        )
        XCTAssertEqual(a.contentDigest, b.contentDigest)
        let inverted = CubeLUTTable(
            title: "A",
            dimensions: .oneD,
            size: 2,
            entries: [.one, .zero]
        )
        XCTAssertNotEqual(a.contentDigest, inverted.contentDigest)
    }
}

private func unwrapSuccess<T, E: Error>(
    _ result: Result<T, E>,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        XCTFail("Unexpected failure: \(error)", file: file, line: line)
        throw error
    }
}

private extension Result where Failure == CubeLUTValidationError {
    func getOrNil() -> Success? {
        if case .success(let value) = self {
            return value
        }
        return nil
    }
}
