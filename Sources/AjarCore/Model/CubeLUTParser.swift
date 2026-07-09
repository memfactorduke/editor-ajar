// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Typed failures while parsing a `.cube` LUT (FR-COL-004). Every malformed input maps to one
/// of these cases — the parser never traps (NFR-STAB-003).
public enum CubeLUTParseError: Error, Equatable, Sendable {
    /// UTF-8 decoding failed for the provided bytes.
    case invalidUTF8

    /// Input contained no usable size keyword or data rows.
    case emptyInput

    /// A keyword line was present but could not be parsed.
    case malformedKeyword(line: Int, keyword: String)

    /// `TITLE` appeared more than once.
    case duplicateTitle(line: Int)

    /// `LUT_1D_SIZE` or `LUT_3D_SIZE` appeared more than once, or both kinds were set.
    case duplicateOrConflictingSize(line: Int)

    /// `DOMAIN_MIN` or `DOMAIN_MAX` appeared more than once.
    case duplicateDomain(line: Int, keyword: String)

    /// A size keyword value is outside the inclusive limits.
    case sizeOutOfRange(line: Int, size: Int, dimensions: CubeLUTDimensions)

    /// Neither `LUT_1D_SIZE` nor `LUT_3D_SIZE` was declared before data rows ended.
    case missingSize

    /// A data row did not contain exactly three floats.
    case malformedDataRow(line: Int)

    /// Too many or too few RGB data rows for the declared size.
    case entryCountMismatch(expected: Int, actual: Int)

    /// A data row appeared after the table was already full (or beyond the absolute ceiling).
    case tooManyDataRows(line: Int, expected: Int)

    /// `DOMAIN_MIN` is not strictly less than `DOMAIN_MAX` on a channel.
    case domainMinNotLessThanMax(channel: String)

    /// A float token could not be parsed.
    case malformedFloat(line: Int, token: String)

    /// Clear diagnostic for callers and tests.
    public var message: String {
        switch self {
        case .invalidUTF8:
            return "LUT data is not valid UTF-8"
        case .emptyInput:
            return "LUT input is empty"
        case .malformedKeyword(let line, let keyword):
            return "Malformed \(keyword) on line \(line)"
        case .duplicateTitle(let line):
            return "Duplicate TITLE on line \(line)"
        case .duplicateOrConflictingSize(let line):
            return "Duplicate or conflicting LUT size keyword on line \(line)"
        case .duplicateDomain(let line, let keyword):
            return "Duplicate \(keyword) on line \(line)"
        case .sizeOutOfRange(let line, let size, let dimensions):
            let maximum = CubeLUTLimits.maximumSize(for: dimensions)
            return
                "LUT size \(size) on line \(line) is outside \(CubeLUTLimits.minimumSize)"
                + "...\(maximum) for \(dimensions.rawValue)"
        case .missingSize:
            return "LUT is missing LUT_1D_SIZE or LUT_3D_SIZE"
        case .malformedDataRow(let line):
            return "Malformed RGB data row on line \(line)"
        case .entryCountMismatch(let expected, let actual):
            return "LUT expects \(expected) RGB rows but has \(actual)"
        case .tooManyDataRows(let line, let expected):
            return "LUT has more than \(expected) RGB rows (extra at line \(line))"
        case .domainMinNotLessThanMax(let channel):
            return "LUT DOMAIN_MIN.\(channel) must be strictly less than DOMAIN_MAX.\(channel)"
        case .malformedFloat(let line, let token):
            return "Malformed float \"\(token)\" on line \(line)"
        }
    }
}

/// Pure `.cube` text parser (FR-COL-004). Accepts `Data` or `String`; performs no filesystem I/O.
///
/// Grammar coverage (Adobe/IRIDAS-style `.cube`):
/// - Optional `TITLE "…"` (quoted or bare remainder)
/// - Exactly one of `LUT_1D_SIZE N` / `LUT_3D_SIZE N`
/// - Optional `DOMAIN_MIN r g b` / `DOMAIN_MAX r g b` (default 0/1 per channel)
/// - Exactly `N` (1D) or `N³` (3D) data rows of three floats
/// - `#` comments and blank lines ignored; mixed whitespace tolerated
public enum CubeLUTParser {
    /// Parses UTF-8 `.cube` bytes into a validated table.
    public static func parse(data: Data) -> Result<CubeLUTTable, CubeLUTParseError> {
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.invalidUTF8)
        }
        return parse(text: text)
    }

    /// Parses `.cube` text into a validated table.
    public static func parse(text: String) -> Result<CubeLUTTable, CubeLUTParseError> {
        parseBody(text: text)
    }

    // Keyword dispatch + row accumulation exceed default complexity / body-length budgets.
    // swiftlint:disable cyclomatic_complexity function_body_length
    private static func parseBody(text: String) -> Result<CubeLUTTable, CubeLUTParseError> {
        var title: String?
        var dimensions: CubeLUTDimensions?
        var size: Int?
        var domainMin = CubeLUTColor.zero
        var domainMax = CubeLUTColor.one
        var sawDomainMin = false
        var sawDomainMax = false
        var entries: [CubeLUTColor] = []

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = stripCommentAndTrim(String(rawLine))
            if line.isEmpty {
                continue
            }

            let tokens = tokenize(line)
            guard let head = tokens.first else {
                continue
            }

            let keyword = head.uppercased()
            switch keyword {
            case "TITLE":
                if title != nil {
                    return .failure(.duplicateTitle(line: lineNumber))
                }
                title = parseTitle(line: line, tokens: tokens, lineNumber: lineNumber)
            case "LUT_1D_SIZE", "LUT_3D_SIZE":
                let parsed = parseSize(
                    keyword: keyword,
                    tokens: tokens,
                    lineNumber: lineNumber,
                    existingDimensions: dimensions
                )
                switch parsed {
                case .failure(let error):
                    return .failure(error)
                case .success(let value):
                    dimensions = value.dimensions
                    size = value.size
                }
            case "DOMAIN_MIN":
                if sawDomainMin {
                    return .failure(.duplicateDomain(line: lineNumber, keyword: keyword))
                }
                switch parseColor(tokens: tokens, lineNumber: lineNumber, keyword: keyword) {
                case .failure(let error):
                    return .failure(error)
                case .success(let color):
                    domainMin = color
                    sawDomainMin = true
                }
            case "DOMAIN_MAX":
                if sawDomainMax {
                    return .failure(.duplicateDomain(line: lineNumber, keyword: keyword))
                }
                switch parseColor(tokens: tokens, lineNumber: lineNumber, keyword: keyword) {
                case .failure(let error):
                    return .failure(error)
                case .success(let color):
                    domainMax = color
                    sawDomainMax = true
                }
            default:
                switch parseDataRow(tokens: tokens, lineNumber: lineNumber) {
                case .failure(let error):
                    return .failure(error)
                case .success(let color):
                    if let reject = rejectExcessDataRow(
                        entriesCount: entries.count,
                        dimensions: dimensions,
                        size: size,
                        lineNumber: lineNumber
                    ) {
                        return .failure(reject)
                    }
                    entries.append(color)
                }
            }
        }

        guard let dimensions, let size else {
            if entries.isEmpty && title == nil && !sawDomainMin && !sawDomainMax {
                return .failure(.emptyInput)
            }
            return .failure(.missingSize)
        }
        guard let expected = CubeLUTLimits.expectedEntryCount(size: size, dimensions: dimensions)
        else {
            return .failure(
                .sizeOutOfRange(line: 0, size: size, dimensions: dimensions)
            )
        }
        guard entries.count == expected else {
            return .failure(.entryCountMismatch(expected: expected, actual: entries.count))
        }

        let table = CubeLUTTable(
            title: title,
            dimensions: dimensions,
            size: size,
            domainMin: domainMin,
            domainMax: domainMax,
            entries: entries
        )
        switch table.validated() {
        case .success(let valid):
            return .success(valid)
        case .failure(let error):
            return .failure(mapValidationError(error))
        }
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    // MARK: - Line helpers

    private static func stripCommentAndTrim(_ line: String) -> String {
        let withoutComment: String
        if let hash = line.firstIndex(of: "#") {
            withoutComment = String(line[..<hash])
        } else {
            withoutComment = line
        }
        return withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenize(_ line: String) -> [String] {
        line.split(whereSeparator: { character in
            character.isWhitespace
        }).map(String.init)
    }

    private static func parseTitle(line: String, tokens: [String], lineNumber: Int) -> String? {
        // Prefer quoted title: TITLE "My LUT"
        if let firstQuote = line.firstIndex(of: "\""),
           let lastQuote = line.lastIndex(of: "\""),
           firstQuote < lastQuote {
            let start = line.index(after: firstQuote)
            return String(line[start..<lastQuote])
        }
        // Bare remainder after TITLE token.
        guard tokens.count >= 2 else {
            return ""
        }
        return tokens.dropFirst().joined(separator: " ")
    }

    private static func parseSize(
        keyword: String,
        tokens: [String],
        lineNumber: Int,
        existingDimensions: CubeLUTDimensions?
    ) -> Result<(dimensions: CubeLUTDimensions, size: Int), CubeLUTParseError> {
        if existingDimensions != nil {
            return .failure(.duplicateOrConflictingSize(line: lineNumber))
        }
        guard tokens.count >= 2 else {
            return .failure(.malformedKeyword(line: lineNumber, keyword: keyword))
        }
        let dimensions: CubeLUTDimensions = keyword == "LUT_1D_SIZE" ? .oneD : .threeD
        switch parseInt(tokens[1], lineNumber: lineNumber) {
        case .failure(let error):
            return .failure(error)
        case .success(let size):
            let maximum = CubeLUTLimits.maximumSize(for: dimensions)
            if size < CubeLUTLimits.minimumSize || size > maximum {
                return .failure(
                    .sizeOutOfRange(line: lineNumber, size: size, dimensions: dimensions)
                )
            }
            return .success((dimensions, size))
        }
    }

    private static func parseColor(
        tokens: [String],
        lineNumber: Int,
        keyword: String
    ) -> Result<CubeLUTColor, CubeLUTParseError> {
        guard tokens.count >= 4 else {
            return .failure(.malformedKeyword(line: lineNumber, keyword: keyword))
        }
        switch parseFloatTriple(
            tokens[1],
            tokens[2],
            tokens[3],
            lineNumber: lineNumber
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let color):
            return .success(color)
        }
    }

    private static func parseDataRow(
        tokens: [String],
        lineNumber: Int
    ) -> Result<CubeLUTColor, CubeLUTParseError> {
        guard tokens.count == 3 else {
            return .failure(.malformedDataRow(line: lineNumber))
        }
        return parseFloatTriple(tokens[0], tokens[1], tokens[2], lineNumber: lineNumber)
    }

    private static func parseFloatTriple(
        _ rToken: String,
        _ gToken: String,
        _ bToken: String,
        lineNumber: Int
    ) -> Result<CubeLUTColor, CubeLUTParseError> {
        switch (
            parseFloat(rToken, lineNumber: lineNumber),
            parseFloat(gToken, lineNumber: lineNumber),
            parseFloat(bToken, lineNumber: lineNumber)
        ) {
        case (.failure(let error), _, _):
            return .failure(error)
        case (_, .failure(let error), _):
            return .failure(error)
        case (_, _, .failure(let error)):
            return .failure(error)
        case (.success(let r), .success(let g), .success(let b)):
            return .success(CubeLUTColor(r: r, g: g, b: b))
        }
    }

    private static func parseFloat(
        _ token: String,
        lineNumber: Int
    ) -> Result<Float, CubeLUTParseError> {
        // Reject empty / non-numeric without trapping. `Float` init is failable.
        guard let value = Float(token) else {
            return .failure(.malformedFloat(line: lineNumber, token: token))
        }
        // Reject NaN / infinite so sampling stays defined.
        guard value.isFinite else {
            return .failure(.malformedFloat(line: lineNumber, token: token))
        }
        return .success(value)
    }

    private static func parseInt(
        _ token: String,
        lineNumber: Int
    ) -> Result<Int, CubeLUTParseError> {
        guard let value = Int(token) else {
            return .failure(.malformedFloat(line: lineNumber, token: token))
        }
        return .success(value)
    }

    private static func mapValidationError(_ error: CubeLUTValidationError) -> CubeLUTParseError {
        switch error {
        case .sizeOutOfRange(let size, let dimensions):
            .sizeOutOfRange(line: 0, size: size, dimensions: dimensions)
        case .entryCountMismatch(let expected, let actual, _, _):
            .entryCountMismatch(expected: expected, actual: actual)
        case .domainMinNotLessThanMax(let channel):
            .domainMinNotLessThanMax(channel: channel)
        }
    }

    /// Rejects rows once the declared table is full, or past the absolute payload ceiling.
    private static func rejectExcessDataRow(
        entriesCount: Int,
        dimensions: CubeLUTDimensions?,
        size: Int?,
        lineNumber: Int
    ) -> CubeLUTParseError? {
        if entriesCount >= CubeLUTLimits.absoluteMaximumEntryCount {
            return .tooManyDataRows(
                line: lineNumber,
                expected: CubeLUTLimits.absoluteMaximumEntryCount
            )
        }
        guard let dimensions, let size,
              let expected = CubeLUTLimits.expectedEntryCount(size: size, dimensions: dimensions)
        else {
            return nil
        }
        if entriesCount >= expected {
            return .tooManyDataRows(line: lineNumber, expected: expected)
        }
        return nil
    }
}
