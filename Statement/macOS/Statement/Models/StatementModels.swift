//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData
import SwiftUI
import CryptoKit

// MARK: - Category source

enum CategorySource: Int, Codable, Sendable {
    case none = 0
    case rule = 1
    case manual = 2
}

// MARK: - User-text source

/// Provenance of a `Transaction.userText` override. Lets the rename engine
/// re-run safely without clobbering names the user typed by hand.
enum UserTextSource: Int, Codable, Sendable {
    case none = 0
    case rule = 1
    case manual = 2
}

// MARK: - Transfer status

enum TransferStatus: Int, Codable, Sendable {
    case none = 0
    case pairedOutgoing = 1
    case pairedIncoming = 2
    case ambiguous = 3
    case unmatched = 4

    nonisolated var isTransfer: Bool {
        self != .none
    }

    nonisolated var isUnresolved: Bool {
        self == .ambiguous || self == .unmatched
    }
}

enum TransferStatusSource: Int, Codable, Sendable {
    case auto = 0
    case manual = 1
}

// MARK: - Account

@Model
final class Account {
    @Attribute(.unique) var accountNumber: String
    var displayName: String
    var colorIndex: Int
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Transaction.account)
    var transactions: [Transaction] = []

    @Relationship(deleteRule: .cascade, inverse: \ImportBatch.account)
    var importBatches: [ImportBatch] = []

    init(accountNumber: String,
         displayName: String,
         colorIndex: Int = 0,
         createdAt: Date = .now) {
        self.accountNumber = accountNumber
        self.displayName = displayName
        self.colorIndex = colorIndex
        self.createdAt = createdAt
    }
}

// MARK: - Transaction

@Model
final class Transaction {
    @Attribute(.unique) var dedupHash: String

    var bookingDate: Date
    var valueDate: Date
    var verificationNumber: String?
    var text: String
    /// User-provided override for `text`. When non-nil, UI surfaces this
    /// instead of the bank-supplied `text`. The original `text` is left
    /// intact so rule matching, dedup hashing, and the PDF-wins loose-key
    /// upsert keep working unchanged.
    var userText: String?
    /// Provenance of `userText`. When `.manual`, the rename rule engine
    /// leaves the row alone so re-applying rules never overwrites a name
    /// the user typed by hand.
    var userTextSourceRaw: Int = 0
    var amount: Decimal
    var runningBalance: Decimal

    /// What to show in the UI: the user override if set, otherwise the
    /// raw bank text.
    var displayText: String {
        if let userText, !userText.isEmpty {
            return userText
        }
        return text
    }

    var categorySourceRaw: Int
    var notes: String?
    var transferStatusRaw: Int = 0
    var transferStatusSourceRaw: Int = 0

    var account: Account?
    var category: Category?
    var subcategory: Subcategory?
    var importBatch: ImportBatch?

    var categorySource: CategorySource {
        get { CategorySource(rawValue: categorySourceRaw) ?? .none }
        set { categorySourceRaw = newValue.rawValue }
    }

    var transferStatus: TransferStatus {
        get { TransferStatus(rawValue: transferStatusRaw) ?? .none }
        set { transferStatusRaw = newValue.rawValue }
    }

    var transferStatusSource: TransferStatusSource {
        get { TransferStatusSource(rawValue: transferStatusSourceRaw) ?? .auto }
        set { transferStatusSourceRaw = newValue.rawValue }
    }

    var userTextSource: UserTextSource {
        get { UserTextSource(rawValue: userTextSourceRaw) ?? .none }
        set { userTextSourceRaw = newValue.rawValue }
    }

    init(dedupHash: String,
         bookingDate: Date,
         valueDate: Date,
         verificationNumber: String?,
         text: String,
         amount: Decimal,
         runningBalance: Decimal,
         categorySource: CategorySource = .none,
         transferStatus: TransferStatus = .none,
         transferStatusSource: TransferStatusSource = .auto) {
        self.dedupHash = dedupHash
        self.bookingDate = bookingDate
        self.valueDate = valueDate
        self.verificationNumber = verificationNumber
        self.text = text
        self.amount = amount
        self.runningBalance = runningBalance
        self.categorySourceRaw = categorySource.rawValue
        self.transferStatusRaw = transferStatus.rawValue
        self.transferStatusSourceRaw = transferStatusSource.rawValue
    }
}

// MARK: - Category / Subcategory

@Model
final class Category {
    @Attribute(.unique) var name: String
    var colorIndex: Int
    var sortIndex: Int

    @Relationship(deleteRule: .cascade, inverse: \Subcategory.parent)
    var subcategories: [Subcategory] = []

    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    var transactions: [Transaction] = []

    init(name: String, colorIndex: Int = 0, sortIndex: Int = 0) {
        self.name = name
        self.colorIndex = colorIndex
        self.sortIndex = sortIndex
    }
}

@Model
final class Subcategory {
    var name: String
    var sortIndex: Int
    var parent: Category?

    @Relationship(deleteRule: .nullify, inverse: \Transaction.subcategory)
    var transactions: [Transaction] = []

    init(name: String, sortIndex: Int = 0, parent: Category? = nil) {
        self.name = name
        self.sortIndex = sortIndex
        self.parent = parent
    }
}

// MARK: - Category rule

enum RuleField: Int, Codable, CaseIterable, Sendable {
    case text = 0
    case amount = 1
    case accountNumber = 2

    var label: String {
        switch self {
        case .text: "Text"
        case .amount: "Amount"
        case .accountNumber: "Account"
        }
    }
}

enum RuleMatchKind: Int, Codable, CaseIterable, Sendable {
    case contains = 0
    case equals = 1
    case regex = 2
    case greaterThan = 3
    case lessThan = 4
    case startsWith = 5
    case endsWith = 6

    var label: String {
        switch self {
        case .contains: "contains"
        case .equals: "equals"
        case .regex: "regex"
        case .greaterThan: "> "
        case .lessThan: "< "
        case .startsWith: "starts with"
        case .endsWith: "ends with"
        }
    }
}

/// Optional sign gate on a `CategoryRule`. Lets the user split ambiguous
/// patterns like `RÄNTA` (interest) into two rules — one categorized as
/// Income when positive, another as Tax / Subscriptions when negative.
enum RuleSignConstraint: Int, Codable, CaseIterable, Sendable {
    case any = 0
    case positive = 1    // amount >= 0
    case negative = 2    // amount < 0

    var label: String {
        switch self {
        case .any: "Any amount"
        case .positive: "Positive only"
        case .negative: "Negative only"
        }
    }

    var shortLabel: String {
        switch self {
        case .any: ""
        case .positive: "+"
        case .negative: "−"
        }
    }
}

@Model
final class CategoryRule {
    var name: String
    var priority: Int
    var matchFieldRaw: Int
    var matchKindRaw: Int
    var pattern: String
    var createdAt: Date
    var signConstraintRaw: Int = 0

    var category: Category?
    var subcategory: Subcategory?

    var matchField: RuleField {
        get { RuleField(rawValue: matchFieldRaw) ?? .text }
        set { matchFieldRaw = newValue.rawValue }
    }
    var matchKind: RuleMatchKind {
        get { RuleMatchKind(rawValue: matchKindRaw) ?? .contains }
        set { matchKindRaw = newValue.rawValue }
    }
    var signConstraint: RuleSignConstraint {
        get { RuleSignConstraint(rawValue: signConstraintRaw) ?? .any }
        set { signConstraintRaw = newValue.rawValue }
    }

    init(name: String,
         priority: Int,
         matchField: RuleField,
         matchKind: RuleMatchKind,
         pattern: String,
         category: Category?,
         subcategory: Subcategory? = nil,
         signConstraint: RuleSignConstraint = .any,
         createdAt: Date = .now) {
        self.name = name
        self.priority = priority
        self.matchFieldRaw = matchField.rawValue
        self.matchKindRaw = matchKind.rawValue
        self.pattern = pattern
        self.category = category
        self.subcategory = subcategory
        self.signConstraintRaw = signConstraint.rawValue
        self.createdAt = createdAt
    }
}

// MARK: - Rename rule

/// Rewrites `Transaction.text` (the raw bank text) to a nicer display
/// string stored in `Transaction.userText`. Applied at import time and
/// via the manual "Re-apply rename rules" action. Manual renames
/// (`userTextSource == .manual`) are never overwritten.
///
/// Match semantics mirror `CategoryRule`: first match by ascending
/// `priority` wins. Match kinds:
///   - `.contains` / `.equals` — replace the whole `userText` with
///     `replacement` (case-insensitive match against raw `text`).
///   - `.regex` — `NSRegularExpression` substitution against raw `text`,
///     so `$1`-style backrefs in `replacement` work.
@Model
final class RenameRule {
    var name: String
    var priority: Int
    var matchKindRaw: Int
    var pattern: String
    var replacement: String
    var createdAt: Date

    var matchKind: RuleMatchKind {
        get { RuleMatchKind(rawValue: matchKindRaw) ?? .contains }
        set { matchKindRaw = newValue.rawValue }
    }

    init(name: String,
         priority: Int,
         matchKind: RuleMatchKind,
         pattern: String,
         replacement: String,
         createdAt: Date = .now) {
        self.name = name
        self.priority = priority
        self.matchKindRaw = matchKind.rawValue
        self.pattern = pattern
        self.replacement = replacement
        self.createdAt = createdAt
    }
}

// MARK: - Import batch

@Model
final class ImportBatch {
    var importedAt: Date
    var sourceFilename: String
    var exportTimestamp: Date?
    var rowCountTotal: Int
    var rowCountInserted: Int
    var rowCountSkipped: Int

    var account: Account?

    @Relationship(deleteRule: .cascade, inverse: \Transaction.importBatch)
    var transactions: [Transaction] = []

    init(importedAt: Date = .now,
         sourceFilename: String,
         exportTimestamp: Date?,
         rowCountTotal: Int = 0,
         rowCountInserted: Int = 0,
         rowCountSkipped: Int = 0,
         account: Account? = nil) {
        self.importedAt = importedAt
        self.sourceFilename = sourceFilename
        self.exportTimestamp = exportTimestamp
        self.rowCountTotal = rowCountTotal
        self.rowCountInserted = rowCountInserted
        self.rowCountSkipped = rowCountSkipped
        self.account = account
    }
}

// MARK: - Dedup hash helper

enum DedupHasher {
    nonisolated static func hash(accountNumber: String,
                                 bookingDate: Date,
                                 valueDate: Date,
                                 text: String,
                                 amount: Decimal,
                                 runningBalance: Decimal) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        let canonical = [
            accountNumber,
            f.string(from: bookingDate),
            f.string(from: valueDate),
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            "\(amount)",
            "\(runningBalance)"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
