//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import CoreXLSX

// MARK: - ParsedTransaction

struct ParsedTransaction: Sendable, Hashable {
    let bookingDate: Date
    let valueDate: Date
    let verificationNumber: String?
    let text: String
    let amount: Decimal
    let runningBalance: Decimal
}

// MARK: - ParsedStatement

struct ParsedStatement: Sendable {
    let accountNumber: String
    let displayName: String
    let exportTimestamp: Date?
    let sourceFilename: String
    let transactions: [ParsedTransaction]
}

// MARK: - Errors

enum SEBStatementParseError: LocalizedError {
    case fileUnreadable(String)
    case noWorksheet
    case headerNotFound
    case accountLabelNotFound
    case invalidRow(rowNumber: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .fileUnreadable(let why): "Could not read the file: \(why)"
        case .noWorksheet: "The file contains no worksheets."
        case .headerNotFound: "The expected SEB header row (Bokföringsdatum, Valutadatum, …) was not found."
        case .accountLabelNotFound: "The account label (e.g. 'Privatkonto (5357 00 824 31)') was not found."
        case .invalidRow(let rowNumber, let reason): "Row \(rowNumber) is invalid: \(reason)"
        }
    }
}

// MARK: - Parser

enum SEBStatementParser {

    private nonisolated static let expectedHeaders: [String] = [
        "Bokföringsdatum",
        "Valutadatum",
        "Verifikationsnummer",
        "Text",
        "Belopp",
        "Saldo"
    ]

    nonisolated static func parse(fileURL: URL) throws -> ParsedStatement {
        let file: XLSXFile
        do {
            guard let f = XLSXFile(filepath: fileURL.path) else {
                throw SEBStatementParseError.fileUnreadable("unsupported or corrupt xlsx")
            }
            file = f
        }

        let sharedStrings: SharedStrings
        do {
            guard let s = try file.parseSharedStrings() else {
                throw SEBStatementParseError.fileUnreadable("missing shared strings")
            }
            sharedStrings = s
        } catch {
            throw SEBStatementParseError.fileUnreadable(error.localizedDescription)
        }

        let worksheetPaths = try file.parseWorksheetPaths()
        guard let firstPath = worksheetPaths.first else {
            throw SEBStatementParseError.noWorksheet
        }
        let worksheet = try file.parseWorksheet(at: firstPath)
        guard let rows = worksheet.data?.rows else {
            throw SEBStatementParseError.noWorksheet
        }

        let matrix = buildMatrix(rows: rows, sharedStrings: sharedStrings)

        // Find header row
        guard let headerRowNum = findHeaderRow(in: matrix) else {
            throw SEBStatementParseError.headerNotFound
        }
        try validateHeader(in: matrix, at: headerRowNum)

        // Find account label (any row containing text matching "Name (digits with spaces)")
        guard let (displayName, accountNumber) = findAccountLabel(in: matrix) else {
            throw SEBStatementParseError.accountLabelNotFound
        }

        // Export timestamp (row whose value matches "yyyy-MM-dd HH:mm")
        let exportTimestamp = findExportTimestamp(in: matrix)

        // Data rows
        let dataStart = headerRowNum + 1
        let dataRowNums = matrix.keys.filter { $0 >= dataStart }.sorted()

        var transactions: [ParsedTransaction] = []
        transactions.reserveCapacity(dataRowNums.count)

        for rowNum in dataRowNums {
            guard let row = matrix[rowNum] else { continue }
            // A row with only a couple of empty cells is a trailing blank — skip.
            if row.values.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }
            let parsed = try parseDataRow(row: row, rowNumber: rowNum)
            transactions.append(parsed)
        }

        return ParsedStatement(
            accountNumber: accountNumber,
            displayName: displayName,
            exportTimestamp: exportTimestamp,
            sourceFilename: fileURL.lastPathComponent,
            transactions: transactions
        )
    }

    // MARK: Matrix

    private nonisolated static func buildMatrix(rows: [Row], sharedStrings: SharedStrings) -> [Int: [String: String]] {
        var matrix: [Int: [String: String]] = [:]
        for row in rows {
            var cols: [String: String] = [:]
            for cell in row.cells {
                let col = cell.reference.column.value
                let value = cell.stringValue(sharedStrings) ?? cell.value
                if let v = value, !v.isEmpty {
                    cols[col] = v
                }
            }
            matrix[Int(row.reference)] = cols
        }
        return matrix
    }

    // MARK: Header

    private nonisolated static func findHeaderRow(in matrix: [Int: [String: String]]) -> Int? {
        for (rowNum, cols) in matrix {
            if let a = cols["A"], a.trimmingCharacters(in: .whitespacesAndNewlines) == "Bokföringsdatum" {
                return rowNum
            }
        }
        return nil
    }

    private nonisolated static func validateHeader(in matrix: [Int: [String: String]], at rowNum: Int) throws {
        guard let cols = matrix[rowNum] else {
            throw SEBStatementParseError.headerNotFound
        }
        let letters = ["A", "B", "C", "D", "E", "F"]
        for (i, letter) in letters.enumerated() {
            let expected = expectedHeaders[i]
            let got = (cols[letter] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard got == expected else {
                throw SEBStatementParseError.headerNotFound
            }
        }
    }

    // MARK: Account label

    /// Matches things like "Privatkonto (5357 00 824 31)".
    private nonisolated static let accountLabelRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"^(.+?)\s*\(([\d\s]+)\)\s*$"#)
        } catch {
            fatalError("SEBStatementParser regex failed: \(error)")
        }
    }()

    private nonisolated static func findAccountLabel(in matrix: [Int: [String: String]]) -> (name: String, number: String)? {
        for (_, cols) in matrix {
            for value in cols.values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if let match = accountLabelRegex.firstMatch(in: trimmed, range: range),
                   match.numberOfRanges == 3,
                   let nameRange = Range(match.range(at: 1), in: trimmed),
                   let numRange = Range(match.range(at: 2), in: trimmed) {
                    let name = String(trimmed[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let number = String(trimmed[numRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    // Guard against non-account-like things that happen to have parentheses
                    if number.replacingOccurrences(of: " ", with: "").count >= 6 {
                        return (name, number)
                    }
                }
            }
        }
        return nil
    }

    // MARK: Export timestamp

    private nonisolated static func findExportTimestamp(in matrix: [Int: [String: String]]) -> Date? {
        for (_, cols) in matrix {
            for value in cols.values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let date = DateFormatters.exportStamp.date(from: trimmed) {
                    return date
                }
            }
        }
        return nil
    }

    // MARK: Data row

    private nonisolated static func parseDataRow(row: [String: String], rowNumber: Int) throws -> ParsedTransaction {
        func get(_ col: String) -> String {
            (row[col] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bookingStr = get("A")
        let valueStr = get("B")
        let verifStr = get("C")
        let text = TextCleanup.cleanXLSXText(get("D"))
        let amountStr = get("E")
        let balanceStr = get("F")

        guard let bookingDate = DateFormatters.isoDay.date(from: bookingStr) else {
            throw SEBStatementParseError.invalidRow(rowNumber: rowNumber, reason: "bad booking date '\(bookingStr)'")
        }
        guard let valueDate = DateFormatters.isoDay.date(from: valueStr) else {
            throw SEBStatementParseError.invalidRow(rowNumber: rowNumber, reason: "bad value date '\(valueStr)'")
        }
        guard let amount = Decimal(string: amountStr, locale: Locale(identifier: "en_US_POSIX")) else {
            throw SEBStatementParseError.invalidRow(rowNumber: rowNumber, reason: "bad amount '\(amountStr)'")
        }
        guard let balance = Decimal(string: balanceStr, locale: Locale(identifier: "en_US_POSIX")) else {
            throw SEBStatementParseError.invalidRow(rowNumber: rowNumber, reason: "bad balance '\(balanceStr)'")
        }

        return ParsedTransaction(
            bookingDate: bookingDate,
            valueDate: valueDate,
            verificationNumber: verifStr.isEmpty ? nil : verifStr,
            text: text,
            amount: amount,
            runningBalance: balance
        )
    }
}
