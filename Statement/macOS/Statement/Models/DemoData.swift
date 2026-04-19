//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData

/// Populates a fresh profile with fabricated SEK data so a first-run user
/// can explore the app without importing real bank statements. Generates
/// two accounts (Checking, Savings), ~24 months of transactions, a small
/// starter set of category/rename rules, and a synthetic `ImportBatch`
/// per account so Import History isn't empty. All data is deterministic
/// from a fixed seed so repeated runs look identical.
@MainActor
enum DemoData {

    static let profileName = "Demo"

    // Two Swedish-style clearing + account numbers. Normalized forms are
    // substrings of the transfer-row text so `TransferPairingService`
    // pairs internal transfers automatically.
    private static let checkingNumber = "5123-12 345 678 901"
    private static let savingsNumber = "5123-12 987 654 321"

    private static let startingCheckingBalance: Decimal = 10_000
    private static let startingSavingsBalance: Decimal = 50_000

    static func populate(context: ModelContext) {
        SeedData.seedIfEmpty(context: context)

        let categoriesByName = fetchCategoriesByName(in: context)

        let checking = Account(
            accountNumber: checkingNumber,
            displayName: "Checking",
            colorIndex: 0,
            createdAt: Date().addingTimeInterval(-60 * 60 * 24 * 365 * 2)
        )
        let savings = Account(
            accountNumber: savingsNumber,
            displayName: "Savings",
            colorIndex: 4,
            createdAt: Date().addingTimeInterval(-60 * 60 * 24 * 365 * 2)
        )
        context.insert(checking)
        context.insert(savings)

        insertCategoryRules(context: context, categoriesByName: categoriesByName)
        insertRenameRules(context: context)

        let checkingBatch = ImportBatch(
            importedAt: .now,
            sourceFilename: "Demo data",
            exportTimestamp: nil,
            account: checking
        )
        let savingsBatch = ImportBatch(
            importedAt: .now,
            sourceFilename: "Demo data",
            exportTimestamp: nil,
            account: savings
        )
        context.insert(checkingBatch)
        context.insert(savingsBatch)

        let events = DemoDataGenerator.generate(
            monthsBack: 24,
            seed: 0xA11CE_5EB_BADF00D
        )

        var checkingBalance = startingCheckingBalance
        var savingsBalance = startingSavingsBalance
        var checkingInserted = 0
        var savingsInserted = 0

        for event in events {
            switch event.account {
            case .checking:
                checkingBalance += event.amount
                let tx = makeTransaction(
                    account: checking,
                    batch: checkingBatch,
                    event: event,
                    runningBalance: checkingBalance
                )
                context.insert(tx)
                checkingInserted += 1
            case .savings:
                savingsBalance += event.amount
                let tx = makeTransaction(
                    account: savings,
                    batch: savingsBatch,
                    event: event,
                    runningBalance: savingsBalance
                )
                context.insert(tx)
                savingsInserted += 1
            }
        }

        checkingBatch.rowCountTotal = checkingInserted
        checkingBatch.rowCountInserted = checkingInserted
        savingsBatch.rowCountTotal = savingsInserted
        savingsBatch.rowCountInserted = savingsInserted

        try? context.save()

        try? CategoryRuleEngine.applyToAll(in: context, preserveManual: true)
        try? RenameRuleEngine.applyToAll(in: context, preserveManual: true)
        _ = TransferPairingService.rescanAll(in: context)

        try? context.save()
    }

    // MARK: - Transaction construction

    private static func makeTransaction(
        account: Account,
        batch: ImportBatch,
        event: DemoEvent,
        runningBalance: Decimal
    ) -> Transaction {
        let hash = DedupHasher.hash(
            accountNumber: account.accountNumber,
            bookingDate: event.date,
            valueDate: event.date,
            text: event.text,
            amount: event.amount,
            runningBalance: runningBalance
        )
        let tx = Transaction(
            dedupHash: hash,
            bookingDate: event.date,
            valueDate: event.date,
            verificationNumber: nil,
            text: event.text,
            amount: event.amount,
            runningBalance: runningBalance
        )
        tx.account = account
        tx.importBatch = batch
        return tx
    }

    // MARK: - Categories lookup

    private static func fetchCategoriesByName(in context: ModelContext) -> [String: Category] {
        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        return Dictionary(uniqueKeysWithValues: existing.map { ($0.name, $0) })
    }

    // MARK: - Starter rules

    private static func insertCategoryRules(
        context: ModelContext,
        categoriesByName: [String: Category]
    ) {
        let rules: [(name: String, pattern: String, category: String, sign: RuleSignConstraint)] = [
            ("Salary", "Lön", "Income", .positive),
            ("Rent", "Hyra", "Housing", .negative),
            ("ICA Groceries", "ICA", "Groceries", .negative),
            ("COOP Groceries", "Coop", "Groceries", .negative),
            ("Willys Groceries", "Willys", "Groceries", .negative),
            ("Spotify", "Spotify", "Subscriptions", .negative),
            ("Netflix", "Netflix", "Subscriptions", .negative),
            ("SL Transport", "SL Access", "Transport", .negative),
            ("SJ Train", "SJ Biljett", "Travel", .negative),
            ("Apotek", "Apotek", "Health", .negative),
            ("Systembolaget", "Systembolaget", "Dining", .negative),
            ("Restaurant", "Restaurang", "Dining", .negative),
            ("Café Fika", "Café", "Dining", .negative),
            ("Elgiganten", "Elgiganten", "Electronics", .negative),
            ("SATS Gym", "SATS", "Health", .negative),
            ("Internal Transfer", "Överföring", "Internal Transfer", .any)
        ]

        for (priority, spec) in rules.enumerated() {
            let rule = CategoryRule(
                name: spec.name,
                priority: priority + 1,
                matchField: .text,
                matchKind: .contains,
                pattern: spec.pattern,
                category: categoriesByName[spec.category],
                signConstraint: spec.sign
            )
            context.insert(rule)
        }
    }

    private static func insertRenameRules(context: ModelContext) {
        let rules: [(name: String, pattern: String, replacement: String)] = [
            ("Spotify", "Spotify", "Spotify"),
            ("Netflix", "Netflix", "Netflix"),
            ("ICA", "ICA Supermarket", "ICA"),
            ("COOP", "Coop Konsum", "COOP"),
            ("SATS", "SATS Sverige", "SATS Gym")
        ]
        for (priority, spec) in rules.enumerated() {
            let rule = RenameRule(
                name: spec.name,
                priority: priority + 1,
                matchKind: .contains,
                pattern: spec.pattern,
                replacement: spec.replacement
            )
            context.insert(rule)
        }
    }
}
