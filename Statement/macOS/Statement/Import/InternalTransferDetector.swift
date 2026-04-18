//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData

/// Helpers for deciding whether a transaction's raw text references one of the
/// user's own bank accounts. The detector is deliberately narrow: it only
/// considers account numbers that belong to `Account` rows currently present in
/// the SwiftData store.
enum InternalTransferDetector {

    /// Strip all spaces from an account number, e.g. `"5694 04 473 42"` → `"56940447342"`.
    nonisolated static func normalize(accountNumber: String) -> String {
        accountNumber.replacingOccurrences(of: " ", with: "")
    }

    /// Strip all whitespace from a transaction text, e.g. `"56940447342 "` → `"56940447342"`.
    nonisolated static func normalize(text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// Fetch every `Account` and return a `[normalizedNumber: Account]` map
    /// suitable for fast destination lookup. Only numbers of length ≥ 6 are
    /// included to avoid degenerate matches.
    nonisolated static func knownAccounts(in context: ModelContext) -> [String: Account] {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        var result: [String: Account] = [:]
        for account in accounts {
            let normalized = normalize(accountNumber: account.accountNumber)
            if normalized.count >= 6 {
                result[normalized] = account
            }
        }
        return result
    }

    /// If the given transaction text references any known account number as a
    /// substring (both sides normalized), return that account. Otherwise `nil`.
    /// Does not check amount sign — the caller enforces `amount < 0` for the
    /// outgoing-side requirement.
    nonisolated static func matchedDestination(
        for text: String,
        known: [String: Account]
    ) -> Account? {
        let normalized = normalize(text: text)
        guard !normalized.isEmpty else {
            return nil
        }
        for (number, account) in known where normalized.contains(number) {
            return account
        }
        return nil
    }
}
