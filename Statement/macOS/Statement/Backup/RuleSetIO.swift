//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData

// MARK: - Envelope

/// JSON envelope for a portable rule-set export. Holds both kinds of rules
/// (category rules and rename rules) plus the categories/subcategories the
/// category rules reference, so importing into an empty profile reconstructs
/// the full rule set on its own.
private struct RuleSetEnvelope: Codable {
    let version: Int
    let exportedAt: Date
    let categories: [RuleSetCategory]
    let subcategories: [RuleSetSubcategory]
    let categoryRules: [RuleSetCategoryRule]
    let renameRules: [RuleSetRenameRule]
}

private struct RuleSetCategory: Codable {
    let name: String
    let colorIndex: Int
    let sortIndex: Int
}

private struct RuleSetSubcategory: Codable {
    let name: String
    let sortIndex: Int
    let parentCategoryName: String
}

private struct RuleSetCategoryRule: Codable {
    let name: String
    let priority: Int
    let matchField: Int
    let matchKind: Int
    let pattern: String
    let categoryName: String?
    let subcategoryName: String?
    let createdAt: Date
    let signConstraint: Int?
}

private struct RuleSetRenameRule: Codable {
    let name: String
    let priority: Int
    let matchKind: Int
    let pattern: String
    let replacement: String
    let createdAt: Date
}

// MARK: - Errors

enum RuleSetIOError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "Unsupported rule-set file version \(v). This build expects version 1."
        }
    }
}

// MARK: - Exporter

@MainActor
enum RuleSetExporter {

    static func export(to url: URL, context: ModelContext) throws {
        let categories = try context.fetch(FetchDescriptor<Category>())
        let subs = try context.fetch(FetchDescriptor<Subcategory>())
        let categoryRules = try context.fetch(FetchDescriptor<CategoryRule>())
        let renameRules = try context.fetch(FetchDescriptor<RenameRule>())

        let envelope = RuleSetEnvelope(
            version: 1,
            exportedAt: Date(),
            categories: categories.map {
                RuleSetCategory(name: $0.name, colorIndex: $0.colorIndex, sortIndex: $0.sortIndex)
            },
            subcategories: subs.compactMap { sub in
                guard let parent = sub.parent else {
                    return nil
                }
                return RuleSetSubcategory(
                    name: sub.name,
                    sortIndex: sub.sortIndex,
                    parentCategoryName: parent.name
                )
            },
            categoryRules: categoryRules.map { r in
                RuleSetCategoryRule(
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
            renameRules: renameRules.map { r in
                RuleSetRenameRule(
                    name: r.name,
                    priority: r.priority,
                    matchKind: r.matchKindRaw,
                    pattern: r.pattern,
                    replacement: r.replacement,
                    createdAt: r.createdAt
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

struct RuleSetImportSummary {
    let categoriesInserted: Int
    let subcategoriesInserted: Int
    let categoryRulesInserted: Int
    let renameRulesInserted: Int
    let transactionsRelinked: Int
    let transactionsOrphaned: Int
}

@MainActor
enum RuleSetImporter {

    /// **Destructive replace.** Wipes every category, subcategory, category
    /// rule, and rename rule from the active store, then inserts the contents
    /// of the JSON envelope. Transaction → category / subcategory links are
    /// snapshotted by name before the wipe and re-bound after the recreated
    /// taxonomy is in place, so manually-categorized transactions whose
    /// category name still exists in the imported file keep their assignment.
    /// Transactions whose previous category is missing from the new file are
    /// left uncategorized and counted in `transactionsOrphaned`.
    static func importRules(from url: URL, context: ModelContext) throws -> RuleSetImportSummary {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(RuleSetEnvelope.self, from: data)

        guard envelope.version == 1 else {
            throw RuleSetIOError.unsupportedVersion(envelope.version)
        }

        // 1. Snapshot transaction → category/subcategory by name so we can
        //    re-link after the destructive replace.
        struct LinkSnapshot {
            let categoryName: String?
            let subcategoryName: String?
        }
        let allTransactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        var links: [PersistentIdentifier: LinkSnapshot] = [:]
        for tx in allTransactions {
            links[tx.persistentModelID] = LinkSnapshot(
                categoryName: tx.category?.name,
                subcategoryName: tx.subcategory?.name
            )
        }

        // 2. Wipe rules + taxonomy. Subcategories are explicitly deleted
        //    first so a stale parent reference can't survive.
        for r in try context.fetch(FetchDescriptor<CategoryRule>()) {
            context.delete(r)
        }
        for r in try context.fetch(FetchDescriptor<RenameRule>()) {
            context.delete(r)
        }
        for s in try context.fetch(FetchDescriptor<Subcategory>()) {
            context.delete(s)
        }
        for c in try context.fetch(FetchDescriptor<Category>()) {
            context.delete(c)
        }
        // Save the delete pass so SwiftData's `@Attribute(.unique)` constraint
        // on `Category.name` doesn't fire when we re-insert a same-named
        // category in the same transaction.
        try context.save()

        // 3. Insert categories
        var categoriesByName: [String: Category] = [:]
        for incoming in envelope.categories {
            let c = Category(
                name: incoming.name,
                colorIndex: incoming.colorIndex,
                sortIndex: incoming.sortIndex
            )
            context.insert(c)
            categoriesByName[incoming.name] = c
        }

        // 4. Insert subcategories
        var subcatsByKey: [String: Subcategory] = [:]
        for incoming in envelope.subcategories {
            guard let parent = categoriesByName[incoming.parentCategoryName] else {
                continue
            }
            let sub = Subcategory(
                name: incoming.name,
                sortIndex: incoming.sortIndex,
                parent: parent
            )
            context.insert(sub)
            subcatsByKey["\(parent.name)::\(sub.name)"] = sub
        }

        // 5. Insert category rules
        for incoming in envelope.categoryRules {
            let rule = CategoryRule(
                name: incoming.name,
                priority: incoming.priority,
                matchField: RuleField(rawValue: incoming.matchField) ?? .text,
                matchKind: RuleMatchKind(rawValue: incoming.matchKind) ?? .contains,
                pattern: incoming.pattern,
                category: incoming.categoryName.flatMap { categoriesByName[$0] },
                subcategory: incoming.subcategoryName.flatMap { subName in
                    subcatsByKey.first { $0.key.hasSuffix("::\(subName)") }?.value
                },
                signConstraint: RuleSignConstraint(rawValue: incoming.signConstraint ?? 0) ?? .any,
                createdAt: incoming.createdAt
            )
            context.insert(rule)
        }

        // 6. Insert rename rules
        for incoming in envelope.renameRules {
            let rule = RenameRule(
                name: incoming.name,
                priority: incoming.priority,
                matchKind: RuleMatchKind(rawValue: incoming.matchKind) ?? .contains,
                pattern: incoming.pattern,
                replacement: incoming.replacement,
                createdAt: incoming.createdAt
            )
            context.insert(rule)
        }

        // 7. Re-link transactions to recreated categories/subcategories by
        //    name. Missing categories leave the transaction uncategorized
        //    and increment the orphan counter.
        var transactionsRelinked = 0
        var transactionsOrphaned = 0
        for tx in allTransactions {
            guard let snap = links[tx.persistentModelID] else {
                continue
            }
            if let oldName = snap.categoryName {
                if let category = categoriesByName[oldName] {
                    tx.category = category
                    if let subName = snap.subcategoryName,
                       let sub = subcatsByKey["\(oldName)::\(subName)"] {
                        tx.subcategory = sub
                    } else {
                        tx.subcategory = nil
                    }
                    transactionsRelinked += 1
                } else {
                    tx.category = nil
                    tx.subcategory = nil
                    transactionsOrphaned += 1
                }
            }
        }

        try context.save()

        return RuleSetImportSummary(
            categoriesInserted: envelope.categories.count,
            subcategoriesInserted: subcatsByKey.count,
            categoryRulesInserted: envelope.categoryRules.count,
            renameRulesInserted: envelope.renameRules.count,
            transactionsRelinked: transactionsRelinked,
            transactionsOrphaned: transactionsOrphaned
        )
    }
}
