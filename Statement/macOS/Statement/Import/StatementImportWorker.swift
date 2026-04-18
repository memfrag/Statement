//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData

/// Background `@ModelActor` that runs an entire drop-to-import cycle on its
/// own isolated `ModelContext`, off the main thread.
///
/// Layout:
///   - `importFiles(urls:onFileStart:)` is the only async entry point.
///   - It parses + inserts each file via the existing `StatementImportService`
///     on this actor's context.
///   - After every file is committed it runs `TransferPairingService.rescanAll`
///     across the whole store.
///   - The caller (typically `ImportCoordinator`) awaits the result and then
///     surfaces it through `@Observable` state so SwiftUI can drive the
///     import summary / transfer review sheets.
///
/// The worker's context lives only for the duration of the import call. Once
/// it goes out of scope, SwiftData flushes and discards it; subsequent
/// `@Query`s on the main context read the newly-committed rows.
@ModelActor
actor StatementImportWorker {

    /// Run the full import-pipeline: per-file atomic insert, then a final
    /// `rescanAll` for transfer pairing. The `onStatus` closure is called
    /// on the main actor at each phase boundary so the UI can update the
    /// progress sheet.
    func importFiles(
        urls: [URL],
        onStatus: @MainActor @Sendable (String) -> Void = { _ in }
    ) async -> ImportRunResult {
        var fileResults: [ImportFileResult] = []

        for url in urls {
            let filename = url.lastPathComponent
            await onStatus("Importing \(filename)…")
            let result = StatementImportService.importFile(url, context: modelContext)
            fileResults.append(result)
        }

        // After every file in the batch has committed, run the store-wide
        // transfer pairing rescan so cross-file pairings get picked up and
        // previously-unmatched rows get a retry against the newly-imported
        // destination accounts.
        await onStatus("Detecting internal transfers…")
        let counts = TransferPairingService.rescanAll(in: modelContext)
        await onStatus("Saving…")
        try? modelContext.save()

        return ImportRunResult(
            files: fileResults,
            unresolvedTransferIDs: counts.unresolvedTransactionIDs
        )
    }
}
