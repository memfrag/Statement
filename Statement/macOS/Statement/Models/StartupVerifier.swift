//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

#if DEBUG
import Foundation
import SwiftData
import OSLog

/// Debug-only harness that exercises the SEB parser end-to-end against
/// the example files in the repo. Opt-in via the environment variable
/// `STATEMENT_VERIFY_EXAMPLES=1`. Logs results and exits the process.
@MainActor
enum StartupVerifier {

    private static let logger = Logger(subsystem: "io.apparata.Statement", category: "Verifier")

    static func runIfRequested(context: ModelContext) {
        guard ProcessInfo.processInfo.environment["STATEMENT_VERIFY_EXAMPLES"] == "1" else {
            return
        }
        Task { @MainActor in
            run(context: context)
            exit(0)
        }
    }

    static func run(context: ModelContext) {
        print("=== Statement parser verification ===")
        let repoRoot = findRepoRoot()
        let exampleDir = repoRoot.appendingPathComponent("Example Files", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: exampleDir, includingPropertiesForKeys: nil) else {
            print("[FAIL] Could not enumerate \(exampleDir.path)")
            return
        }
        let xlsx = files.filter { $0.pathExtension.lowercased() == "xlsx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        print("Found \(xlsx.count) .xlsx files in Example Files/")

        // Parse each
        var totalRows = 0
        for url in xlsx {
            do {
                let parsed = try SEBStatementParser.parse(fileURL: url)
                print("[OK]   \(url.lastPathComponent)")
                print("       account = \(parsed.displayName) (\(parsed.accountNumber))")
                print("       rows    = \(parsed.transactions.count)")
                if let first = parsed.transactions.first, let last = parsed.transactions.last {
                    print("       first   = \(first.bookingDate) \(first.text) \(first.amount)")
                    print("       last    = \(last.bookingDate) \(last.text) \(last.amount)")
                }
                totalRows += parsed.transactions.count
            } catch {
                print("[FAIL] \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        print("Total parsed rows across files: \(totalRows)")

        // Import dedup test: clear store, then import each in order and print counts.
        // Delete individual rows (batch delete trips on the mandatory Transaction.account inverse).
        do {
            for tx in try context.fetch(FetchDescriptor<Transaction>()) {
                context.delete(tx)
            }
            for batch in try context.fetch(FetchDescriptor<ImportBatch>()) {
                context.delete(batch)
            }
            for account in try context.fetch(FetchDescriptor<Account>()) {
                context.delete(account)
            }
            try context.save()
        } catch {
            print("[WARN] store reset failed: \(error)")
        }

        for url in xlsx {
            let result = StatementImportService.importFile(url, context: context)
            print("[IMPORT] \(url.lastPathComponent) → inserted=\(result.inserted) skipped=\(result.skipped) success=\(result.success)")
            if let err = result.errorMessage {
                print("         error: \(err)")
            }
        }

        // Run the transfer pairing rescan explicitly (the single-file import
        // path doesn't trigger it; only `importFiles` does).
        let counts = TransferPairingService.rescanAll(in: context)
        try? context.save()
        print("[PAIRING] paired=\(counts.paired) ambiguous=\(counts.ambiguous) unmatched=\(counts.unmatched) cleared=\(counts.cleared)")

        let accountCount = (try? context.fetchCount(FetchDescriptor<Account>())) ?? -1
        let txCount = (try? context.fetchCount(FetchDescriptor<Transaction>())) ?? -1
        let batchCount = (try? context.fetchCount(FetchDescriptor<ImportBatch>())) ?? -1
        let pairedCount = (try? context.fetchCount(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.transferStatusRaw == 1 || $0.transferStatusRaw == 2 }
        ))) ?? -1
        let ambiguousCount = (try? context.fetchCount(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.transferStatusRaw == 3 }
        ))) ?? -1
        let unmatchedCount = (try? context.fetchCount(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.transferStatusRaw == 4 }
        ))) ?? -1
        print("Final store: accounts=\(accountCount) transactions=\(txCount) batches=\(batchCount)")
        print("  transfers: paired=\(pairedCount) ambiguous=\(ambiguousCount) unmatched=\(unmatchedCount)")
        print("=== end ===")
    }

    private static func findRepoRoot() -> URL {
        // When launched from derived data, look for the project sibling with Example Files.
        // `#filePath` resolves to the full absolute path to this source file at compile time.
        let thisFile = URL(fileURLWithPath: #filePath)
        var candidate = thisFile
        for _ in 0..<10 {
            candidate = candidate.deletingLastPathComponent()
            let marker = candidate.appendingPathComponent("Example Files", isDirectory: true)
            if FileManager.default.fileExists(atPath: marker.path) {
                return candidate
            }
        }
        // Fallback: current working directory.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
#endif
