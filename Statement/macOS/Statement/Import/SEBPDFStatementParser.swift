//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import PDFKit

/// Parses SEB "Kontoutdrag" PDF statements into the same
/// `ParsedStatement` / `ParsedTransaction` value types that
/// `SEBStatementParser` emits from the XLSX path, so everything
/// downstream (import service, transfer pairing, rules, analytics)
/// works unchanged.
///
/// Reuses the regex + helpers from `docs/Extract-from-PDF.swift`:
/// a strict per-line transaction regex, an account-header regex, a
/// whitespace collapser, and a Swedish-number normalizer.
enum SEBPDFStatementParser {

    /// Per-line transaction regex — two ISO dates, a verification
    /// number, free-form text, and two Swedish-format amounts.
    /// Ported verbatim from `docs/Extract-from-PDF.swift`.
    private nonisolated static let transactionLineRegex: NSRegularExpression = {
        let pattern = #"^(\d{4}-\d{2}-\d{2})\s+(\d{4}-\d{2}-\d{2})\s+(\S+)\s+(.+?)\s+(-?\d[\d ]*,\d{2})\s+(-?\d[\d ]*,\d{2})$"#
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            fatalError("SEBPDFStatementParser tx regex failed: \(error)")
        }
    }()

    /// Account header line — e.g. `Privatkonto 5357 00 824 31 / SEK`.
    /// Account number is strictly `DDDD DD DDD DD` followed by ` / SEK`.
    private nonisolated static let accountHeaderRegex: NSRegularExpression = {
        let pattern = #"^(.+?) (\d{4} \d{2} \d{3} \d{2}) / SEK$"#
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            fatalError("SEBPDFStatementParser account regex failed: \(error)")
        }
    }()

    /// The display-name line has the user-facing account name on the left
    /// and a date range on the right (e.g. `Betalningar 4/14/2021 - 4/14/2026`).
    /// This regex captures a trailing `M/D/YYYY - M/D/YYYY` pattern that we
    /// then strip to get the clean name.
    private nonisolated static let trailingDateRangeRegex: NSRegularExpression = {
        let pattern = #"\s+\d{1,2}/\d{1,2}/\d{4}\s*-\s*\d{1,2}/\d{1,2}/\d{4}\s*$"#
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            fatalError("SEBPDFStatementParser date-range regex failed: \(error)")
        }
    }()

    // MARK: - Entry point

    nonisolated static func parse(fileURL: URL) throws -> ParsedStatement {
        guard let document = PDFDocument(url: fileURL) else {
            throw SEBStatementParseError.fileUnreadable("could not open PDF")
        }

        // Concatenate every page into a list of whitespace-normalized,
        // non-empty lines.
        var lines: [String] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let text = page.string else {
                continue
            }
            for rawLine in text.components(separatedBy: .newlines) {
                let line = normalizeWhitespace(rawLine)
                if !line.isEmpty {
                    lines.append(line)
                }
            }
        }

        guard let header = findAccountHeader(in: lines) else {
            throw SEBStatementParseError.accountLabelNotFound
        }
        let displayName = header.displayName
        let accountNumber = header.accountNumber

        var transactions: [ParsedTransaction] = []
        for (index, line) in lines.enumerated() {
            guard let tx = try? parseTransactionLine(line, at: index) else {
                continue
            }
            transactions.append(tx)
        }

        return ParsedStatement(
            accountNumber: accountNumber,
            displayName: displayName,
            exportTimestamp: nil,
            sourceFilename: fileURL.lastPathComponent,
            transactions: transactions
        )
    }

    // MARK: - Helpers

    private nonisolated static func normalizeWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func swedishNumberToDecimal(_ s: String) -> Decimal? {
        let cleaned = s
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The SEB PDF has two consecutive header lines:
    ///
    /// ```
    /// Privatkonto 5694 04 473 42 / SEK
    /// Betalningar                          4/14/2021 - 4/14/2026
    /// ```
    ///
    /// The first line is `<accountType> <number> / SEK`. The line
    /// immediately after is the user-facing display name of the account
    /// (e.g. "Betalningar", "Lönekonto", "Semesterkassa") followed by a
    /// right-aligned date range that PDFKit concatenates onto the same
    /// line after whitespace normalization. We strip the trailing
    /// `M/D/YYYY - M/D/YYYY` to get the clean name, so the result
    /// matches the format the XLSX parser produces (XLSX label is
    /// `Betalningar (5694 04 473 42)` — i.e. user-facing name + number),
    /// and the Account upsert in `StatementImportService` works across
    /// both paths.
    ///
    /// If the next line is missing or empty (or is only a date range),
    /// fall back to the account type prefix so the parser still produces
    /// a usable display name.
    private nonisolated static func findAccountHeader(in lines: [String]) -> (displayName: String, accountNumber: String)? {
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = accountHeaderRegex.firstMatch(in: line, range: range),
                  match.numberOfRanges == 3,
                  let typeRange = Range(match.range(at: 1), in: line),
                  let numRange = Range(match.range(at: 2), in: line) else {
                continue
            }
            let accountType = String(line[typeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let number = String(line[numRange])

            let nextLineName: String? = {
                guard index + 1 < lines.count else {
                    return nil
                }
                let next = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = stripTrailingDateRange(next)
                return cleaned.isEmpty ? nil : cleaned
            }()

            return (nextLineName ?? accountType, number)
        }
        return nil
    }

    /// Removes a trailing `" M/D/YYYY - M/D/YYYY"` pattern from a string
    /// so that `"Betalningar 4/14/2021 - 4/14/2026"` becomes `"Betalningar"`.
    /// Returns the input unchanged if no date range is present.
    private nonisolated static func stripTrailingDateRange(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        let stripped = trailingDateRangeRegex.stringByReplacingMatches(
            in: s,
            options: [],
            range: range,
            withTemplate: ""
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func parseTransactionLine(_ line: String, at index: Int) throws -> ParsedTransaction? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = transactionLineRegex.firstMatch(in: line, range: range),
              match.numberOfRanges == 7 else {
            return nil
        }

        func group(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: line) else {
                return nil
            }
            return String(line[r])
        }

        guard let bookingStr = group(1),
              let valueStr = group(2),
              let verifStr = group(3),
              let rawText = group(4),
              let amountStr = group(5),
              let balanceStr = group(6) else {
            return nil
        }

        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let bookingDate = DateFormatters.isoDay.date(from: bookingStr) else {
            throw SEBStatementParseError.invalidRow(rowNumber: index, reason: "bad booking date '\(bookingStr)'")
        }
        guard let valueDate = DateFormatters.isoDay.date(from: valueStr) else {
            throw SEBStatementParseError.invalidRow(rowNumber: index, reason: "bad value date '\(valueStr)'")
        }
        guard let amount = swedishNumberToDecimal(amountStr) else {
            throw SEBStatementParseError.invalidRow(rowNumber: index, reason: "bad amount '\(amountStr)'")
        }
        guard let balance = swedishNumberToDecimal(balanceStr) else {
            throw SEBStatementParseError.invalidRow(rowNumber: index, reason: "bad balance '\(balanceStr)'")
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
