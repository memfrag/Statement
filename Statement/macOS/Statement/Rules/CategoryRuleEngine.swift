//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData

/// Evaluates `CategoryRule`s against transactions and assigns categories.
enum CategoryRuleEngine {

    // MARK: - Matching

    /// Returns the first rule (by ascending `priority`) that matches the given transaction.
    nonisolated static func firstMatch(for transaction: Transaction, rules: [CategoryRule]) -> CategoryRule? {
        for rule in rules {
            if matches(rule: rule, transaction: transaction) {
                return rule
            }
        }
        return nil
    }

    nonisolated static func matches(rule: CategoryRule, transaction: Transaction) -> Bool {
        // Sign gate — cheap short-circuit before any text/regex work.
        switch rule.signConstraint {
        case .any:
            break
        case .positive:
            if transaction.amount < 0 {
                return false
            }
        case .negative:
            if transaction.amount >= 0 {
                return false
            }
        }

        switch rule.matchField {
        case .text:
            return matchString(transaction.text, rule: rule)
        case .accountNumber:
            return matchString(transaction.account?.accountNumber ?? "", rule: rule)
        case .amount:
            return matchAmount(transaction.amount, rule: rule)
        }
    }

    private nonisolated static func matchString(_ value: String, rule: CategoryRule) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = rule.pattern
        switch rule.matchKind {
        case .contains: return v.range(of: p, options: .caseInsensitive) != nil
        case .equals:   return v.caseInsensitiveCompare(p) == .orderedSame
        case .startsWith: return v.range(of: p, options: [.caseInsensitive, .anchored]) != nil
        case .endsWith:   return v.range(of: p, options: [.caseInsensitive, .anchored, .backwards]) != nil
        case .regex:
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(v.startIndex..., in: v)
            return re.firstMatch(in: v, range: range) != nil
        case .greaterThan, .lessThan:
            return false // not meaningful on strings
        }
    }

    private nonisolated static func matchAmount(_ amount: Decimal, rule: CategoryRule) -> Bool {
        guard let threshold = Decimal(string: rule.pattern, locale: Locale(identifier: "en_US_POSIX")) else {
            return false
        }
        switch rule.matchKind {
        case .greaterThan: return amount > threshold
        case .lessThan:    return amount < threshold
        case .equals:      return amount == threshold
        default:           return false
        }
    }

    // MARK: - Application

    /// Apply rules to a single transaction. Sets `categorySource = .rule` when matched.
    nonisolated static func apply(rules: [CategoryRule], to transaction: Transaction) {
        if let rule = firstMatch(for: transaction, rules: rules) {
            transaction.category = rule.category
            transaction.subcategory = rule.subcategory
            transaction.categorySource = .rule
        }
    }

    /// Apply rules to every transaction in the given context.
    /// - Parameter preserveManual: when true, transactions with `categorySource == .manual`
    ///   are left alone. This is the default when automatic re-runs happen after a rule edit.
    ///
    /// Transfer-flagged rows (`transferStatus.isTransfer`) are skipped entirely
    /// so that their auto-assigned "Internal Transfer" category is never
    /// overwritten by the normal rule engine.
    nonisolated static func applyToAll(in context: ModelContext, preserveManual: Bool) throws {
        let rules = try loadRules(context: context)
        let descriptor = FetchDescriptor<Transaction>()
        let all = try context.fetch(descriptor)
        for tx in all {
            if tx.transferStatus.isTransfer { continue }
            if preserveManual && tx.categorySource == .manual { continue }
            if let rule = firstMatch(for: tx, rules: rules) {
                tx.category = rule.category
                tx.subcategory = rule.subcategory
                tx.categorySource = .rule
            } else {
                // No match — clear any previously rule-assigned category.
                if tx.categorySource == .rule {
                    tx.category = nil
                    tx.subcategory = nil
                    tx.categorySource = .none
                }
            }
        }
    }

    /// Apply rules to only the newly inserted transactions of an import batch.
    /// Transfer-flagged rows are skipped for the same reason as `applyToAll`.
    nonisolated static func applyToBatch(_ batch: ImportBatch, in context: ModelContext) throws {
        let rules = try loadRules(context: context)
        for tx in batch.transactions {
            if tx.transferStatus.isTransfer { continue }
            if tx.categorySource == .manual { continue }
            if let rule = firstMatch(for: tx, rules: rules) {
                tx.category = rule.category
                tx.subcategory = rule.subcategory
                tx.categorySource = .rule
            }
        }
    }

    // MARK: - Helpers

    nonisolated static func loadRules(context: ModelContext) throws -> [CategoryRule] {
        var descriptor = FetchDescriptor<CategoryRule>(
            sortBy: [SortDescriptor(\.priority, order: .forward)]
        )
        descriptor.fetchLimit = 10_000
        return try context.fetch(descriptor)
    }
}
