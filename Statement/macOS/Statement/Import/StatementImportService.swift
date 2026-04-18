//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData
import SwiftUI

// MARK: - Result types

struct ImportFileResult: Identifiable, Sendable {
    let id = UUID()
    let filename: String
    let success: Bool
    let accountName: String?
    let inserted: Int
    let skipped: Int
    let total: Int
    let errorMessage: String?
}

struct ImportRunResult: Sendable {
    let files: [ImportFileResult]
    /// Persistent IDs of outgoing transfers that ended up `.ambiguous` or
    /// `.unmatched` after this run. The coordinator uses these to drive the
    /// Review Transfers sheet when the import summary is dismissed.
    var unresolvedTransferIDs: [PersistentIdentifier] = []
    var totalInserted: Int { files.reduce(0) { $0 + $1.inserted } }
    var totalSkipped: Int { files.reduce(0) { $0 + $1.skipped } }
    var failureCount: Int { files.filter { !$0.success }.count }
}

// MARK: - Source format

/// Which file format a given URL came from. Dictates which parser runs and
/// whether the loose-key upsert path is allowed to overwrite existing text
/// (PDF only — PDF text is treated as authoritative).
enum ImportSourceFormat: Sendable {
    case xlsx
    case pdf
}

// MARK: - Import service

/// Atomically imports SEB .xlsx and .pdf statements into SwiftData.
///
/// Each file is wrapped in its own save attempt. If any step fails, the service
/// rolls back that file's changes by deleting the batch and its inserted transactions
/// and reports the error; earlier successful files in the same run stay committed.
enum StatementImportService {

    nonisolated static func importFiles(_ urls: [URL], context: ModelContext) -> ImportRunResult {
        var results: [ImportFileResult] = []
        for url in urls {
            let result = importFile(url, context: context)
            results.append(result)
        }
        // After every file in the run has been committed individually, run a
        // single store-wide rescan so cross-file pairing has the newest data.
        let counts = TransferPairingService.rescanAll(in: context)
        try? context.save()
        return ImportRunResult(
            files: results,
            unresolvedTransferIDs: counts.unresolvedTransactionIDs
        )
    }

    nonisolated static func detectFormat(_ url: URL) -> ImportSourceFormat? {
        switch url.pathExtension.lowercased() {
        case "xlsx": return .xlsx
        case "pdf":  return .pdf
        default:     return nil
        }
    }

    private nonisolated static func parse(_ url: URL, format: ImportSourceFormat) throws -> ParsedStatement {
        switch format {
        case .xlsx:
            return try SEBStatementParser.parse(fileURL: url)
        case .pdf:
            return try SEBPDFStatementParser.parse(fileURL: url)
        }
    }

    nonisolated static func importFile(_ url: URL, context: ModelContext) -> ImportFileResult {
        let filename = url.lastPathComponent

        guard let format = detectFormat(url) else {
            return ImportFileResult(
                filename: filename, success: false, accountName: nil,
                inserted: 0, skipped: 0, total: 0,
                errorMessage: "Unsupported file type — only .xlsx and .pdf are accepted."
            )
        }

        let parsed: ParsedStatement
        do {
            parsed = try parse(url, format: format)
        } catch {
            return ImportFileResult(
                filename: filename, success: false, accountName: nil,
                inserted: 0, skipped: 0, total: 0,
                errorMessage: error.localizedDescription
            )
        }

        // Upsert account
        let account: Account
        do {
            account = try upsertAccount(
                number: parsed.accountNumber,
                name: parsed.displayName,
                in: context
            )
        } catch {
            return ImportFileResult(
                filename: filename, success: false, accountName: parsed.displayName,
                inserted: 0, skipped: 0, total: parsed.transactions.count,
                errorMessage: error.localizedDescription
            )
        }

        // Precompute dedup hashes
        let rows: [(ParsedTransaction, String)] = parsed.transactions.map { tx in
            let h = DedupHasher.hash(
                accountNumber: account.accountNumber,
                bookingDate: tx.bookingDate,
                valueDate: tx.valueDate,
                text: tx.text,
                amount: tx.amount,
                runningBalance: tx.runningBalance
            )
            return (tx, h)
        }

        // Dedup against existing
        let existingHashes: Set<String>
        do {
            existingHashes = try loadExistingHashes(context: context)
        } catch {
            return ImportFileResult(
                filename: filename, success: false, accountName: parsed.displayName,
                inserted: 0, skipped: 0, total: parsed.transactions.count,
                errorMessage: "Failed to fetch existing transactions: \(error.localizedDescription)"
            )
        }

        // Loose-key map: keyed on everything *except* text. Used to upsert
        // across formats so importing a PDF after an XLSX (or vice versa)
        // doesn't duplicate rows; instead the PDF text upgrades the
        // existing row's text in place.
        let existingLooseMap: [String: Transaction]
        do {
            existingLooseMap = try loadLooseKeyMap(for: account, context: context)
        } catch {
            return ImportFileResult(
                filename: filename, success: false, accountName: parsed.displayName,
                inserted: 0, skipped: 0, total: parsed.transactions.count,
                errorMessage: "Failed to fetch existing loose-key map: \(error.localizedDescription)"
            )
        }

        // Create batch + transactions
        let batch = ImportBatch(
            sourceFilename: parsed.sourceFilename,
            exportTimestamp: parsed.exportTimestamp,
            rowCountTotal: parsed.transactions.count,
            account: account
        )
        context.insert(batch)

        var seenInThisFile = Set<String>()
        var insertedCount = 0
        var skippedCount = 0

        for (parsedTx, hash) in rows {
            // 1. Exact-hash skip — same text, everything matches → duplicate.
            if existingHashes.contains(hash) || seenInThisFile.contains(hash) {
                skippedCount += 1
                continue
            }

            // 2. Loose-key cross-format handling. Everything except text
            //    matches, so this is the same underlying transaction in
            //    a different format (or a text update from the bank).
            let looseKey = makeLooseKey(
                accountNumber: account.accountNumber,
                bookingDate: parsedTx.bookingDate,
                valueDate: parsedTx.valueDate,
                amount: parsedTx.amount,
                balance: parsedTx.runningBalance
            )
            if let existing = existingLooseMap[looseKey] {
                switch format {
                case .pdf:
                    // Upgrade: PDF text is authoritative. Overwrite text +
                    // recompute dedupHash so subsequent re-imports of the
                    // same PDF short-circuit on the exact-hash path.
                    if existing.text != parsedTx.text {
                        existing.text = parsedTx.text
                        existing.dedupHash = DedupHasher.hash(
                            accountNumber: account.accountNumber,
                            bookingDate: existing.bookingDate,
                            valueDate: existing.valueDate,
                            text: existing.text,
                            amount: existing.amount,
                            runningBalance: existing.runningBalance
                        )
                    }
                case .xlsx:
                    // Keep whatever text is already there (likely from a
                    // prior PDF import) — don't downgrade, don't duplicate.
                    break
                }
                skippedCount += 1
                seenInThisFile.insert(hash)
                continue
            }

            // 3. Fresh insert.
            seenInThisFile.insert(hash)

            let tx = Transaction(
                dedupHash: hash,
                bookingDate: parsedTx.bookingDate,
                valueDate: parsedTx.valueDate,
                verificationNumber: parsedTx.verificationNumber,
                text: parsedTx.text,
                amount: parsedTx.amount,
                runningBalance: parsedTx.runningBalance
            )
            tx.account = account
            tx.importBatch = batch
            context.insert(tx)
            insertedCount += 1
        }

        batch.rowCountInserted = insertedCount
        batch.rowCountSkipped = skippedCount

        // Apply rules to the new rows.
        do {
            try CategoryRuleEngine.applyToBatch(batch, in: context)
        } catch {
            // non-fatal; transactions are still imported.
        }
        do {
            try RenameRuleEngine.applyToBatch(batch, in: context)
        } catch {
            // non-fatal; transactions are still imported.
        }

        // Commit
        do {
            try context.save()
        } catch {
            // Roll back: delete what we inserted for this file.
            context.delete(batch)
            try? context.save()
            return ImportFileResult(
                filename: filename, success: false, accountName: parsed.displayName,
                inserted: 0, skipped: 0, total: parsed.transactions.count,
                errorMessage: "Failed to save: \(error.localizedDescription)"
            )
        }

        return ImportFileResult(
            filename: filename,
            success: true,
            accountName: account.displayName,
            inserted: insertedCount,
            skipped: skippedCount,
            total: parsed.transactions.count,
            errorMessage: nil
        )
    }

    // MARK: Helpers

    private nonisolated static func upsertAccount(number: String, name: String, in context: ModelContext) throws -> Account {
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { $0.accountNumber == number }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        // Choose a palette index based on current account count.
        let allAccounts = try context.fetch(FetchDescriptor<Account>())
        let account = Account(
            accountNumber: number,
            displayName: name,
            colorIndex: allAccounts.count
        )
        context.insert(account)
        return account
    }

    private nonisolated static func loadExistingHashes(context: ModelContext) throws -> Set<String> {
        let descriptor = FetchDescriptor<Transaction>(
            sortBy: [SortDescriptor(\.bookingDate, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return Set(all.map(\.dedupHash))
    }

    /// Loose key excludes `text` so that transactions which differ ONLY in
    /// their description (e.g. abbreviated XLSX text vs. full PDF text) can
    /// be matched and upgraded in place.
    private nonisolated static func makeLooseKey(
        accountNumber: String,
        bookingDate: Date,
        valueDate: Date,
        amount: Decimal,
        balance: Decimal
    ) -> String {
        let f = DateFormatters.isoDay
        return "\(accountNumber)|\(f.string(from: bookingDate))|\(f.string(from: valueDate))|\(amount)|\(balance)"
    }

    /// Builds a map from loose key → existing `Transaction` for the given
    /// account. Only includes rows that already belong to this account
    /// number so cross-account collisions can't happen.
    private nonisolated static func loadLooseKeyMap(
        for account: Account,
        context: ModelContext
    ) throws -> [String: Transaction] {
        let all = try context.fetch(FetchDescriptor<Transaction>())
        var map: [String: Transaction] = [:]
        for tx in all where tx.account?.accountNumber == account.accountNumber {
            let key = makeLooseKey(
                accountNumber: account.accountNumber,
                bookingDate: tx.bookingDate,
                valueDate: tx.valueDate,
                amount: tx.amount,
                balance: tx.runningBalance
            )
            map[key] = tx
        }
        return map
    }
}
