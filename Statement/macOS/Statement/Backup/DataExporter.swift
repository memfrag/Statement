//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData

// MARK: - Backup envelope

private struct BackupEnvelope: Codable {
    let version: Int
    let exportedAt: Date
    let accounts: [BackupAccount]
    let categories: [BackupCategory]
    let subcategories: [BackupSubcategory]
    let rules: [BackupRule]
    let batches: [BackupBatch]
    let transactions: [BackupTransaction]
}

private struct BackupAccount: Codable {
    let accountNumber: String
    let displayName: String
    let colorIndex: Int
    let createdAt: Date
}

private struct BackupCategory: Codable {
    let name: String
    let colorIndex: Int
    let sortIndex: Int
}

private struct BackupSubcategory: Codable {
    let name: String
    let sortIndex: Int
    let parentCategoryName: String
}

private struct BackupRule: Codable {
    let name: String
    let priority: Int
    let matchField: Int
    let matchKind: Int
    let pattern: String
    let categoryName: String?
    let subcategoryName: String?
    let createdAt: Date
    /// Optional + default-0 on missing so old backups restore cleanly.
    let signConstraint: Int?
}

private struct BackupBatch: Codable {
    let importedAt: Date
    let sourceFilename: String
    let exportTimestamp: Date?
    let rowCountTotal: Int
    let rowCountInserted: Int
    let rowCountSkipped: Int
    let accountNumber: String?
}

private struct BackupTransaction: Codable {
    let dedupHash: String
    let accountNumber: String?
    let bookingDate: Date
    let valueDate: Date
    let verificationNumber: String?
    let text: String
    let amount: String       // Decimal via string for exactness
    let runningBalance: String
    let categoryName: String?
    let subcategoryName: String?
    let categorySource: Int
    let notes: String?
    let sourceFilename: String?
    // Optional + default-on-missing so old backups restore cleanly.
    let transferStatus: Int?
    let transferStatusSource: Int?
}

// MARK: - Exporter

@MainActor
enum DataExporter {

    static func export(to url: URL, context: ModelContext) throws {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(FetchDescriptor<Category>())
        let subs = try context.fetch(FetchDescriptor<Subcategory>())
        let rules = try context.fetch(FetchDescriptor<CategoryRule>())
        let batches = try context.fetch(FetchDescriptor<ImportBatch>())
        let transactions = try context.fetch(FetchDescriptor<Transaction>())

        let envelope = BackupEnvelope(
            version: 1,
            exportedAt: Date(),
            accounts: accounts.map {
                BackupAccount(
                    accountNumber: $0.accountNumber,
                    displayName: $0.displayName,
                    colorIndex: $0.colorIndex,
                    createdAt: $0.createdAt
                )
            },
            categories: categories.map {
                BackupCategory(name: $0.name, colorIndex: $0.colorIndex, sortIndex: $0.sortIndex)
            },
            subcategories: subs.compactMap { sub in
                guard let parent = sub.parent else {
                    return nil
                }
                return BackupSubcategory(name: sub.name, sortIndex: sub.sortIndex, parentCategoryName: parent.name)
            },
            rules: rules.map { r in
                BackupRule(
                    name: r.name,
                    priority: r.priority,
                    matchField: r.matchFieldRaw,
                    matchKind: r.matchKindRaw,
                    pattern: r.pattern,
                    categoryName: r.category?.name,
                    subcategoryName: r.subcategory?.name,
                    createdAt: r.createdAt,
                    signConstraint: r.signConstraintRaw
                )
            },
            batches: batches.map {
                BackupBatch(
                    importedAt: $0.importedAt,
                    sourceFilename: $0.sourceFilename,
                    exportTimestamp: $0.exportTimestamp,
                    rowCountTotal: $0.rowCountTotal,
                    rowCountInserted: $0.rowCountInserted,
                    rowCountSkipped: $0.rowCountSkipped,
                    accountNumber: $0.account?.accountNumber
                )
            },
            transactions: transactions.map {
                BackupTransaction(
                    dedupHash: $0.dedupHash,
                    accountNumber: $0.account?.accountNumber,
                    bookingDate: $0.bookingDate,
                    valueDate: $0.valueDate,
                    verificationNumber: $0.verificationNumber,
                    text: $0.text,
                    amount: "\($0.amount)",
                    runningBalance: "\($0.runningBalance)",
                    categoryName: $0.category?.name,
                    subcategoryName: $0.subcategory?.name,
                    categorySource: $0.categorySourceRaw,
                    notes: $0.notes,
                    sourceFilename: $0.importBatch?.sourceFilename,
                    transferStatus: $0.transferStatusRaw,
                    transferStatusSource: $0.transferStatusSourceRaw
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Importer

struct DataImportSummary {
    let accountsInserted: Int
    let categoriesInserted: Int
    let rulesInserted: Int
    let transactionsInserted: Int
    let transactionsSkipped: Int
}

@MainActor
enum DataImporter {

    static func importBackup(from url: URL, context: ModelContext) throws -> DataImportSummary {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(BackupEnvelope.self, from: data)

        // Upsert accounts
        var accountsByNumber: [String: Account] = [:]
        var accountsInserted = 0
        for existing in try context.fetch(FetchDescriptor<Account>()) {
            accountsByNumber[existing.accountNumber] = existing
        }
        for backup in envelope.accounts {
            if accountsByNumber[backup.accountNumber] == nil {
                let a = Account(
                    accountNumber: backup.accountNumber,
                    displayName: backup.displayName,
                    colorIndex: backup.colorIndex,
                    createdAt: backup.createdAt
                )
                context.insert(a)
                accountsByNumber[a.accountNumber] = a
                accountsInserted += 1
            }
        }

        // Upsert categories
        var categoriesByName: [String: Category] = [:]
        var categoriesInserted = 0
        for existing in try context.fetch(FetchDescriptor<Category>()) {
            categoriesByName[existing.name] = existing
        }
        for backup in envelope.categories {
            if categoriesByName[backup.name] == nil {
                let c = Category(name: backup.name, colorIndex: backup.colorIndex, sortIndex: backup.sortIndex)
                context.insert(c)
                categoriesByName[backup.name] = c
                categoriesInserted += 1
            }
        }

        // Upsert subcategories (keyed by parent name + own name)
        var subcatsByKey: [String: Subcategory] = [:]
        for existing in try context.fetch(FetchDescriptor<Subcategory>()) {
            let parent = existing.parent?.name ?? ""
            subcatsByKey["\(parent)::\(existing.name)"] = existing
        }
        for backup in envelope.subcategories {
            let key = "\(backup.parentCategoryName)::\(backup.name)"
            if subcatsByKey[key] == nil, let parent = categoriesByName[backup.parentCategoryName] {
                let sub = Subcategory(name: backup.name, sortIndex: backup.sortIndex, parent: parent)
                context.insert(sub)
                subcatsByKey[key] = sub
            }
        }

        // Upsert rules (match by name + pattern)
        var existingRuleKeys: Set<String> = []
        for r in try context.fetch(FetchDescriptor<CategoryRule>()) {
            existingRuleKeys.insert("\(r.name)::\(r.pattern)")
        }
        var rulesInserted = 0
        for backup in envelope.rules {
            let key = "\(backup.name)::\(backup.pattern)"
            if existingRuleKeys.contains(key) {
                continue
            }
            let rule = CategoryRule(
                name: backup.name,
                priority: backup.priority,
                matchField: RuleField(rawValue: backup.matchField) ?? .text,
                matchKind: RuleMatchKind(rawValue: backup.matchKind) ?? .contains,
                pattern: backup.pattern,
                category: backup.categoryName.flatMap { categoriesByName[$0] },
                subcategory: backup.subcategoryName.flatMap { subName in
                    subcatsByKey.first { $0.key.hasSuffix("::\(subName)") }?.value
                },
                signConstraint: RuleSignConstraint(rawValue: backup.signConstraint ?? 0) ?? .any,
                createdAt: backup.createdAt
            )
            context.insert(rule)
            existingRuleKeys.insert(key)
            rulesInserted += 1
        }

        // Upsert batches (match by sourceFilename + importedAt)
        var batchesByKey: [String: ImportBatch] = [:]
        for existing in try context.fetch(FetchDescriptor<ImportBatch>()) {
            batchesByKey["\(existing.sourceFilename)::\(existing.importedAt.timeIntervalSince1970)"] = existing
        }
        for backup in envelope.batches {
            let key = "\(backup.sourceFilename)::\(backup.importedAt.timeIntervalSince1970)"
            if batchesByKey[key] == nil {
                let b = ImportBatch(
                    importedAt: backup.importedAt,
                    sourceFilename: backup.sourceFilename,
                    exportTimestamp: backup.exportTimestamp,
                    rowCountTotal: backup.rowCountTotal,
                    rowCountInserted: backup.rowCountInserted,
                    rowCountSkipped: backup.rowCountSkipped,
                    account: backup.accountNumber.flatMap { accountsByNumber[$0] }
                )
                context.insert(b)
                batchesByKey[key] = b
            }
        }

        // Upsert transactions by dedupHash
        var existingHashes: Set<String> = []
        for tx in try context.fetch(FetchDescriptor<Transaction>()) {
            existingHashes.insert(tx.dedupHash)
        }
        var transactionsInserted = 0
        var transactionsSkipped = 0
        for backup in envelope.transactions {
            if existingHashes.contains(backup.dedupHash) {
                transactionsSkipped += 1
                continue
            }
            let amount = Decimal(string: backup.amount, locale: Locale(identifier: "en_US_POSIX")) ?? 0
            let balance = Decimal(string: backup.runningBalance, locale: Locale(identifier: "en_US_POSIX")) ?? 0
            let tx = Transaction(
                dedupHash: backup.dedupHash,
                bookingDate: backup.bookingDate,
                valueDate: backup.valueDate,
                verificationNumber: backup.verificationNumber,
                text: backup.text,
                amount: amount,
                runningBalance: balance,
                categorySource: CategorySource(rawValue: backup.categorySource) ?? .none,
                transferStatus: TransferStatus(rawValue: backup.transferStatus ?? 0) ?? .none,
                transferStatusSource: TransferStatusSource(rawValue: backup.transferStatusSource ?? 0) ?? .auto
            )
            tx.notes = backup.notes
            tx.account = backup.accountNumber.flatMap { accountsByNumber[$0] }
            tx.category = backup.categoryName.flatMap { categoriesByName[$0] }
            tx.subcategory = backup.subcategoryName.flatMap { subName in
                subcatsByKey.first { $0.key.hasSuffix("::\(subName)") }?.value
            }
            if let sourceFile = backup.sourceFilename {
                tx.importBatch = batchesByKey.first { $0.key.hasPrefix("\(sourceFile)::") }?.value
            }
            context.insert(tx)
            existingHashes.insert(backup.dedupHash)
            transactionsInserted += 1
        }

        try context.save()

        return DataImportSummary(
            accountsInserted: accountsInserted,
            categoriesInserted: categoriesInserted,
            rulesInserted: rulesInserted,
            transactionsInserted: transactionsInserted,
            transactionsSkipped: transactionsSkipped
        )
    }
}
