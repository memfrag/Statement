//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData

/// Applies `RenameRule`s against transactions, populating `userText`.
///
/// First-match-wins by ascending `priority`. Rules match against the
/// raw bank `text` (never `displayText`) so renames don't chain into
/// each other across re-runs. Rows whose `userTextSource == .manual`
/// are never touched.
enum RenameRuleEngine {

    /// Returns the rewritten string for the given raw bank text, or
    /// `nil` if no rule matched. Pure function — touches no model state.
    nonisolated static func rewrite(text rawText: String, rules: [RenameRule]) -> String? {
        let v = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        for rule in rules {
            switch rule.matchKind {
            case .contains:
                if v.range(of: rule.pattern, options: .caseInsensitive) != nil {
                    return rule.replacement
                }
            case .equals:
                if v.caseInsensitiveCompare(rule.pattern) == .orderedSame {
                    return rule.replacement
                }
            case .startsWith:
                if v.range(of: rule.pattern, options: [.caseInsensitive, .anchored]) != nil {
                    return rule.replacement
                }
            case .endsWith:
                if v.range(of: rule.pattern, options: [.caseInsensitive, .anchored, .backwards]) != nil {
                    return rule.replacement
                }
            case .regex:
                guard let re = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else {
                    continue
                }
                let range = NSRange(v.startIndex..., in: v)
                guard re.firstMatch(in: v, range: range) != nil else {
                    continue
                }
                return re.stringByReplacingMatches(in: v, options: [], range: range, withTemplate: rule.replacement)
            case .greaterThan, .lessThan:
                continue
            }
        }
        return nil
    }

    /// Apply rules to a single transaction. Skips manual overrides.
    /// Sets `userTextSource = .rule` on a hit; clears a previous rule
    /// override on a miss so that deleting/editing a rule doesn't leave
    /// stale text behind.
    nonisolated static func apply(rules: [RenameRule], to tx: Transaction) {
        if tx.userTextSource == .manual {
            return
        }
        if let rewritten = rewrite(text: tx.text, rules: rules) {
            if rewritten != tx.userText {
                tx.userText = rewritten
                tx.userTextSource = .rule
            }
        } else if tx.userTextSource == .rule {
            tx.userText = nil
            tx.userTextSource = .none
        }
    }

    /// Apply rules to every transaction in the given context.
    /// - Parameter preserveManual: when true, manual overrides are kept.
    ///   When false, all rows are rewritten from scratch — destructive.
    nonisolated static func applyToAll(in context: ModelContext, preserveManual: Bool) throws {
        let rules = try loadRules(context: context)
        let all = try context.fetch(FetchDescriptor<Transaction>())
        for tx in all {
            if preserveManual && tx.userTextSource == .manual {
                continue
            }
            if let rewritten = rewrite(text: tx.text, rules: rules) {
                if rewritten != tx.userText {
                    tx.userText = rewritten
                    tx.userTextSource = .rule
                }
            } else if tx.userTextSource != .manual {
                tx.userText = nil
                tx.userTextSource = .none
            }
        }
    }

    /// Apply rules to only the newly inserted transactions of an import batch.
    nonisolated static func applyToBatch(_ batch: ImportBatch, in context: ModelContext) throws {
        let rules = try loadRules(context: context)
        for tx in batch.transactions {
            apply(rules: rules, to: tx)
        }
    }

    nonisolated static func loadRules(context: ModelContext) throws -> [RenameRule] {
        var descriptor = FetchDescriptor<RenameRule>(
            sortBy: [SortDescriptor(\.priority, order: .forward)]
        )
        descriptor.fetchLimit = 10_000
        return try context.fetch(descriptor)
    }
}
