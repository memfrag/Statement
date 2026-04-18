//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData

/// Seeds a first-run set of categories and rules so imported transactions land
/// in something meaningful out of the box.
@MainActor
enum SeedData {

    static func seedIfEmpty(context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<Category>())) ?? 0
        guard existing == 0 else {
            return
        }

        let specs: [(name: String, color: Int)] = [
            ("Groceries", 0),
            ("Dining", 2),
            ("Transport", 5),
            ("Utilities", 1),
            ("Housing", 9),
            ("Income", 4),
            ("Expense", 8),
            ("Subscriptions", 3),
            ("Software", 1),
            ("Tax", 8),
            ("Home", 6),
            ("Cash & Transfers", 7),
            ("Health", 10),
            ("Internal Transfer", 11),
            ("Travel", 5),
            ("Entertainment", 3),
            ("Culture", 6),
            ("Education", 11),
            ("Exercise & Sports", 10),
            ("Savings", 4),
            ("Hardware", 9),
            ("Electronics", 0),
            ("Appliances", 7),
            ("Clothes", 3)
        ]
        for (i, spec) in specs.enumerated() {
            let c = Category(name: spec.name, colorIndex: spec.color, sortIndex: i)
            context.insert(c)
        }

        try? context.save()
    }

    // MARK: - One-shot migrations for existing stores

    /// UserDefaults key roots. The active profile's UUID is appended per-call
    /// so that each profile gets its own migration status and doesn't skip
    /// seeding just because the previous profile already ran it.
    private static let healthV1KeyRoot = "statement.seed.healthV1Applied"
    private static let transferFlagsV1KeyRoot = "statement.migration.transferFlagsV1"
    private static let internalTransferCategoryV1KeyRoot = "statement.seed.internalTransferCategoryV1Applied"
    private static let expenseCategoryV1KeyRoot = "statement.seed.expenseCategoryV1Applied"
    private static let softwareCategoryV1KeyRoot = "statement.seed.softwareCategoryV1Applied"
    private static let xlsxTextCleanupV1KeyRoot = "statement.migration.xlsxTextCleanupV1"
    private static let lifestyleCategoriesV1KeyRoot = "statement.seed.lifestyleCategoriesV1Applied"
    private static let savingsCategoryV1KeyRoot = "statement.seed.savingsCategoryV1Applied"
    private static let hardwareCategoriesV1KeyRoot = "statement.seed.hardwareCategoriesV1Applied"
    private static let clothesCategoryV1KeyRoot = "statement.seed.clothesCategoryV1Applied"

    private static func key(_ root: String, profileID: UUID) -> String {
        "\(root).\(profileID.uuidString)"
    }

    /// Clears every migration flag for the given profile. Called when a
    /// profile is deleted so its UserDefaults footprint disappears with it.
    static func clearMigrationFlags(for profileID: UUID) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key(healthV1KeyRoot, profileID: profileID))
        defaults.removeObject(forKey: key(transferFlagsV1KeyRoot, profileID: profileID))
        defaults.removeObject(forKey: key(internalTransferCategoryV1KeyRoot, profileID: profileID))
        defaults.removeObject(forKey: key(expenseCategoryV1KeyRoot, profileID: profileID))
        defaults.removeObject(forKey: key(softwareCategoryV1KeyRoot, profileID: profileID))
        defaults.removeObject(forKey: key(xlsxTextCleanupV1KeyRoot, profileID: profileID))
        defaults.removeObject(forKey: key(lifestyleCategoriesV1KeyRoot, profileID: profileID))
        defaults.removeObject(forKey: key(savingsCategoryV1KeyRoot, profileID: profileID))
        defaults.removeObject(forKey: key(hardwareCategoriesV1KeyRoot, profileID: profileID))
        defaults.removeObject(forKey: key(clothesCategoryV1KeyRoot, profileID: profileID))
    }

    /// Adds the "Clothes" category to existing profiles. Idempotent via a
    /// UserDefaults flag; once applied, never re-runs even if Clothes is
    /// later deleted.
    static func migrateAddClothesCategoryIfNeeded(context: ModelContext, profileID: UUID) {
        let defaults = UserDefaults.standard
        let flagKey = key(clothesCategoryV1KeyRoot, profileID: profileID)
        guard !defaults.bool(forKey: flagKey) else {
            return
        }
        defer {
            defaults.set(true, forKey: flagKey)
        }

        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        if existing.contains(where: { $0.name == "Clothes" }) {
            return
        }
        let nextSortIndex = (existing.map(\.sortIndex).max() ?? 0) + 1
        let category = Category(
            name: "Clothes",
            colorIndex: 3,
            sortIndex: nextSortIndex
        )
        context.insert(category)
        try? context.save()
    }

    /// Adds Hardware / Electronics / Appliances to existing profiles.
    /// Each missing category is created once; if the user already created
    /// or later deletes one, the UserDefaults flag prevents this migration
    /// from re-introducing it.
    static func migrateAddHardwareCategoriesIfNeeded(context: ModelContext, profileID: UUID) {
        let defaults = UserDefaults.standard
        let flagKey = key(hardwareCategoriesV1KeyRoot, profileID: profileID)
        guard !defaults.bool(forKey: flagKey) else {
            return
        }
        defer {
            defaults.set(true, forKey: flagKey)
        }

        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let existingNames = Set(existing.map(\.name))
        var nextSortIndex = (existing.map(\.sortIndex).max() ?? 0) + 1

        let specs: [(name: String, color: Int)] = [
            ("Hardware", 9),
            ("Electronics", 0),
            ("Appliances", 7)
        ]
        for spec in specs {
            if existingNames.contains(spec.name) {
                continue
            }
            let category = Category(
                name: spec.name,
                colorIndex: spec.color,
                sortIndex: nextSortIndex
            )
            context.insert(category)
            nextSortIndex += 1
        }
        try? context.save()
    }

    /// Adds the "Savings" category to existing profiles. Intended for
    /// transactions like recurring index fund / stock investment buys —
    /// money that's leaving the checking account but going into a long-
    /// term holding rather than being spent.
    static func migrateAddSavingsCategoryIfNeeded(context: ModelContext, profileID: UUID) {
        let defaults = UserDefaults.standard
        let flagKey = key(savingsCategoryV1KeyRoot, profileID: profileID)
        guard !defaults.bool(forKey: flagKey) else {
            return
        }
        defer {
            defaults.set(true, forKey: flagKey)
        }

        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        if existing.contains(where: { $0.name == "Savings" }) {
            return
        }
        let nextSortIndex = (existing.map(\.sortIndex).max() ?? 0) + 1
        let category = Category(
            name: "Savings",
            colorIndex: 4,
            sortIndex: nextSortIndex
        )
        context.insert(category)
        try? context.save()
    }

    /// Adds Travel / Entertainment / Culture / Education / Exercise & Sports
    /// to existing profiles. Each missing category is created once; if the
    /// user already created or later deletes one, the UserDefaults flag
    /// prevents this migration from re-introducing it.
    static func migrateAddLifestyleCategoriesIfNeeded(context: ModelContext, profileID: UUID) {
        let defaults = UserDefaults.standard
        let flagKey = key(lifestyleCategoriesV1KeyRoot, profileID: profileID)
        guard !defaults.bool(forKey: flagKey) else {
            return
        }
        defer {
            defaults.set(true, forKey: flagKey)
        }

        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let existingNames = Set(existing.map(\.name))
        var nextSortIndex = (existing.map(\.sortIndex).max() ?? 0) + 1

        let specs: [(name: String, color: Int)] = [
            ("Travel", 5),
            ("Entertainment", 3),
            ("Culture", 6),
            ("Education", 11),
            ("Exercise & Sports", 10)
        ]
        for spec in specs {
            if existingNames.contains(spec.name) {
                continue
            }
            let category = Category(
                name: spec.name,
                colorIndex: spec.color,
                sortIndex: nextSortIndex
            )
            context.insert(category)
            nextSortIndex += 1
        }
        try? context.save()
    }

    /// One-shot migration that rewrites existing `Transaction.text` values
    /// that look like raw SEB XLSX output (`ALL CAPS` and/or ending in a
    /// `/YY-MM-DD` suffix) to the same title-cased form the XLSX parser
    /// now produces at import time. PDF-sourced rich text is guarded and
    /// left untouched via `shouldCleanTransactionText`.
    ///
    /// The migration recomputes `dedupHash` for every updated row so that
    /// subsequent re-imports of the same XLSX short-circuit on the
    /// exact-hash fast path in `StatementImportService`.
    static func migrateCleanupXLSXTextIfNeeded(context: ModelContext, profileID: UUID) {
        let defaults = UserDefaults.standard
        let flagKey = key(xlsxTextCleanupV1KeyRoot, profileID: profileID)
        guard !defaults.bool(forKey: flagKey) else {
            return
        }
        defer {
            defaults.set(true, forKey: flagKey)
        }

        let all = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        for tx in all {
            guard shouldCleanTransactionText(tx.text) else {
                continue
            }
            let cleaned = TextCleanup.cleanXLSXText(tx.text)
            guard cleaned != tx.text else {
                continue
            }
            tx.text = cleaned
            tx.dedupHash = DedupHasher.hash(
                accountNumber: tx.account?.accountNumber ?? "",
                bookingDate: tx.bookingDate,
                valueDate: tx.valueDate,
                text: cleaned,
                amount: tx.amount,
                runningBalance: tx.runningBalance
            )
        }
        try? context.save()
    }

    /// Heuristic for "this text looks like a raw SEB XLSX cell":
    ///   - contains a trailing `/YY-MM-DD` suffix, OR
    ///   - is entirely uppercase (contains no lowercase letter).
    ///
    /// Mixed-case strings (including rich PDF descriptions promoted by
    /// the loose-key upsert path) are intentionally left alone so the
    /// migration never downgrades already-clean text.
    private static func shouldCleanTransactionText(_ text: String) -> Bool {
        if text.range(of: #"/\d{2}-\d{2}-\d{2}\s*$"#, options: .regularExpression) != nil {
            return true
        }
        let hasLower = text.contains { $0.isLetter && $0.isLowercase }
        return !hasLower
    }

    /// Ensures the "Software" category exists. Intended for non-subscription
    /// software purchases (one-off licenses, app store buys, etc.). Runs
    /// once per profile. Respects user deletions after first application.
    static func migrateAddSoftwareCategoryIfNeeded(context: ModelContext, profileID: UUID) {
        let defaults = UserDefaults.standard
        let flagKey = key(softwareCategoryV1KeyRoot, profileID: profileID)
        guard !defaults.bool(forKey: flagKey) else {
            return
        }
        defer {
            defaults.set(true, forKey: flagKey)
        }

        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        if existing.contains(where: { $0.name == "Software" }) {
            return
        }
        let nextSortIndex = (existing.map(\.sortIndex).max() ?? 0) + 1
        let category = Category(
            name: "Software",
            colorIndex: 1,
            sortIndex: nextSortIndex
        )
        context.insert(category)
        try? context.save()
    }

    /// Ensures the generic "Expense" category exists in existing profiles.
    /// Seeded for fresh installs; this migration is for stores created
    /// before the category was added. Idempotent — a UserDefaults flag
    /// prevents it from re-creating the category if the user later deletes it.
    static func migrateAddExpenseCategoryIfNeeded(context: ModelContext, profileID: UUID) {
        let defaults = UserDefaults.standard
        let flagKey = key(expenseCategoryV1KeyRoot, profileID: profileID)
        guard !defaults.bool(forKey: flagKey) else {
            return
        }
        defer {
            defaults.set(true, forKey: flagKey)
        }

        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        if existing.contains(where: { $0.name == "Expense" }) {
            return
        }
        let nextSortIndex = (existing.map(\.sortIndex).max() ?? 0) + 1
        let category = Category(
            name: "Expense",
            colorIndex: 8,
            sortIndex: nextSortIndex
        )
        context.insert(category)
        try? context.save()
    }

    /// Ensures the "Internal Transfer" category exists. Runs once per profile
    /// so that pre-existing profiles (seeded before this category was added)
    /// pick it up. Skips silently if the user already created or deleted
    /// a category by that name — the UserDefaults flag is final.
    static func migrateAddInternalTransferCategoryIfNeeded(context: ModelContext, profileID: UUID) {
        let defaults = UserDefaults.standard
        let flagKey = key(internalTransferCategoryV1KeyRoot, profileID: profileID)
        guard !defaults.bool(forKey: flagKey) else {
            return
        }
        defer {
            defaults.set(true, forKey: flagKey)
        }

        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        if existing.contains(where: { $0.name == "Internal Transfer" }) {
            return
        }
        let nextSortIndex = (existing.map(\.sortIndex).max() ?? 0) + 1
        let category = Category(
            name: "Internal Transfer",
            colorIndex: 11,
            sortIndex: nextSortIndex
        )
        context.insert(category)
        try? context.save()
    }

    /// Ensures the "Health" category and its starter rules exist in stores that
    /// were seeded before Health was added. Idempotent and respects user deletions
    /// via a UserDefaults flag — once applied, never re-runs even if Health is
    /// later deleted.
    static func migrateAddHealthIfNeeded(context: ModelContext, profileID: UUID) {
        let defaults = UserDefaults.standard
        let flagKey = key(healthV1KeyRoot, profileID: profileID)
        guard !defaults.bool(forKey: flagKey) else {
            return
        }
        defer {
            defaults.set(true, forKey: flagKey)
        }

        // If Health already exists (user added it themselves), do nothing.
        let existingCategories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        if existingCategories.contains(where: { $0.name == "Health" }) {
            return
        }

        // Otherwise create it and wire up default gym rules.
        let nextSortIndex = (existingCategories.map(\.sortIndex).max() ?? 0) + 1
        let health = Category(name: "Health", colorIndex: 10, sortIndex: nextSortIndex)
        context.insert(health)

        let existingRules = (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? []
        var nextPriority = (existingRules.map(\.priority).max() ?? 0) + 1

        func addHealthRule(_ name: String, pattern: String, kind: RuleMatchKind = .contains) {
            // Don't clobber a rule the user may have already created.
            if existingRules.contains(where: { $0.pattern.caseInsensitiveCompare(pattern) == .orderedSame }) {
                return
            }
            let rule = CategoryRule(
                name: name,
                priority: nextPriority,
                matchField: .text,
                matchKind: kind,
                pattern: pattern,
                category: health
            )
            context.insert(rule)
            nextPriority += 1
        }

        addHealthRule("STC gym", pattern: "STC")
        addHealthRule("SATS gym", pattern: "SATS")
        addHealthRule("Nordic Wellness", pattern: "NORDIC WELLNESS")
        addHealthRule("Friskis & Svettis", pattern: "FRISKIS")
        addHealthRule("Actic gym", pattern: "ACTIC")
        addHealthRule("Apotek", pattern: "APOTEK")

        try? context.save()
    }

    /// One-shot migration that backfills `Transaction.transferStatus` for
    /// stores created before the internal-transfer detection feature landed.
    /// Runs exactly once per profile.
    static func migrateFlagInternalTransfersIfNeeded(context: ModelContext, profileID: UUID) {
        let defaults = UserDefaults.standard
        let flagKey = key(transferFlagsV1KeyRoot, profileID: profileID)
        guard !defaults.bool(forKey: flagKey) else {
            return
        }
        defer {
            defaults.set(true, forKey: flagKey)
        }
        _ = TransferPairingService.rescanAll(in: context)
        try? context.save()
    }
}
