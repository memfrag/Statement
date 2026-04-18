//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData

struct PairingCounts: Sendable {
    var paired: Int = 0
    var ambiguous: Int = 0
    var unmatched: Int = 0
    var cleared: Int = 0
    var unresolvedTransactionIDs: [PersistentIdentifier] = []
}

/// Detects and flags internal transfers between the user's own accounts.
///
/// All static helpers are `nonisolated` because they only touch a
/// `ModelContext` which carries its own executor; they can run on the main
/// actor, a `@ModelActor` worker, or any other isolation domain.
enum TransferPairingService {

    // MARK: - Category helpers

    /// Returns the seeded "Internal Transfer" `Category` if it exists.
    /// Every transfer-flagged transaction gets this category (unless the
    /// user manually overrode it) so the transaction table shows a clear
    /// chip and so analytics queries that slice by category can identify
    /// transfer rows.
    nonisolated static func fetchInternalTransferCategory(in context: ModelContext) -> Category? {
        var descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.name == "Internal Transfer" }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Assigns the Internal Transfer category to `tx` unless the user
    /// manually picked a different category (`categorySource == .manual`).
    /// Called whenever a transaction transitions INTO any transfer state.
    nonisolated static func applyTransferCategory(to tx: Transaction, category: Category?) {
        guard tx.categorySource != .manual, let category else {
            return
        }
        tx.category = category
        tx.subcategory = nil
        tx.categorySource = .rule
    }

    /// Clears the Internal Transfer category from `tx` when transitioning OUT
    /// of a transfer state, but only if the current category IS the Internal
    /// Transfer category (so we don't clobber an unrelated manual choice) and
    /// `categorySource` isn't `.manual`.
    nonisolated static func clearTransferCategoryIfAuto(from tx: Transaction, category: Category?) {
        guard tx.categorySource != .manual, let category else {
            return
        }
        if tx.category?.persistentModelID == category.persistentModelID {
            tx.category = nil
            tx.subcategory = nil
            tx.categorySource = .none
        }
    }

    // MARK: - Rescan

    /// Re-scan every transaction in the store. Used by:
    ///   - the one-off migration (backfill),
    ///   - the post-import re-scan (catches pairs that depend on newly
    ///     imported data, and resolves previously-`.unmatched` outgoings),
    ///   - the post-delete re-scan (clears stale auto flags).
    ///
    /// Skips every transaction whose `transferStatusSource == .manual`.
    /// Returns aggregate counts and the persistent IDs of any outgoing
    /// transfers that ended up in an unresolved state (`.ambiguous` or
    /// `.unmatched`) so the caller can drive the Review sheet.
    @discardableResult
    nonisolated static func rescanAll(in context: ModelContext) -> PairingCounts {
        let known = InternalTransferDetector.knownAccounts(in: context)
        let transferCategory = fetchInternalTransferCategory(in: context)
        var counts = PairingCounts()

        // Phase 1 — clear stale auto flags.
        // A transaction that was previously flagged by auto-detection may no
        // longer match (e.g. the referenced account was deleted). Reset it
        // and also clear the auto-assigned Internal Transfer category.
        let allForClearing = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        for tx in allForClearing where tx.transferStatusSource == .auto && tx.transferStatus != .none {
            tx.transferStatus = .none
            clearTransferCategoryIfAuto(from: tx, category: transferCategory)
            counts.cleared += 1
        }

        // Phase 2 — walk outgoing candidates (amount < 0, text matches a known
        // account). Sort by (bookingDate, verificationNumber) for deterministic
        // "first unpaired candidate wins" in ambiguity-resolution passes.
        let sortedAll = allForClearing.sorted { lhs, rhs in
            if lhs.bookingDate != rhs.bookingDate {
                return lhs.bookingDate < rhs.bookingDate
            }
            return (lhs.verificationNumber ?? "") < (rhs.verificationNumber ?? "")
        }

        // Track which positive rows have already been paired in this pass so
        // we don't double-use them for two different outgoing transactions.
        var pairedPositiveIDs = Set<PersistentIdentifier>()

        for tx in sortedAll {
            guard tx.transferStatusSource != .manual else {
                continue
            }
            guard tx.amount < 0 else {
                continue
            }
            guard let destination = InternalTransferDetector.matchedDestination(
                for: tx.text, known: known
            ) else {
                continue
            }

            let candidates = findCandidates(
                for: tx,
                destination: destination,
                in: context,
                excluding: pairedPositiveIDs
            )

            switch candidates.count {
            case 1:
                let match = candidates[0]
                tx.transferStatus = .pairedOutgoing
                tx.transferStatusSource = .auto
                applyTransferCategory(to: tx, category: transferCategory)
                match.transferStatus = .pairedIncoming
                match.transferStatusSource = .auto
                applyTransferCategory(to: match, category: transferCategory)
                pairedPositiveIDs.insert(match.persistentModelID)
                counts.paired += 1
            case 0:
                tx.transferStatus = .unmatched
                tx.transferStatusSource = .auto
                applyTransferCategory(to: tx, category: transferCategory)
                counts.unmatched += 1
                counts.unresolvedTransactionIDs.append(tx.persistentModelID)
            default:
                tx.transferStatus = .ambiguous
                tx.transferStatusSource = .auto
                applyTransferCategory(to: tx, category: transferCategory)
                counts.ambiguous += 1
                counts.unresolvedTransactionIDs.append(tx.persistentModelID)
            }
        }

        // Phase 3 — text + date + amount pairing across accounts.
        //
        // Catches transfers where NEITHER leg contains the destination account
        // number in its Text field, but both legs share the same description
        // (e.g. SEB internal moves where both sides just say "MARTIN JOHAN"
        // or "EGEN ÖVERFÖRING"). Only considers transactions still in
        // `.none` after Phase 2 — Phase 2's `.unmatched` rows are left alone
        // because they already have a known destination account.
        //
        // Conservative rule: auto-pair ONLY when exactly one negative and one
        // positive share the same (normalized text, booking day, |amount|)
        // key AND they belong to different accounts. Larger groups are
        // ambiguous and left unflagged so the user can resolve them manually.
        struct TextPairKey: Hashable {
            let text: String
            let dayStart: Date
            let absAmount: Decimal
        }

        let phase3Candidates = allForClearing.filter {
            $0.transferStatus == .none && $0.transferStatusSource != .manual
        }

        let calendar = Calendar.current
        var textGroups: [TextPairKey: [Transaction]] = [:]
        for tx in phase3Candidates where tx.amount != 0 {
            let normalized = tx.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else {
                continue
            }
            let key = TextPairKey(
                text: normalized,
                dayStart: calendar.startOfDay(for: tx.bookingDate),
                absAmount: abs(tx.amount)
            )
            textGroups[key, default: []].append(tx)
        }

        for (_, group) in textGroups {
            guard group.count == 2 else {
                continue
            }
            guard let neg = group.first(where: { $0.amount < 0 }),
                  let pos = group.first(where: { $0.amount > 0 }) else {
                continue
            }
            guard let negAcc = neg.account?.persistentModelID,
                  let posAcc = pos.account?.persistentModelID,
                  negAcc != posAcc else {
                continue
            }

            neg.transferStatus = .pairedOutgoing
            neg.transferStatusSource = .auto
            applyTransferCategory(to: neg, category: transferCategory)
            pos.transferStatus = .pairedIncoming
            pos.transferStatusSource = .auto
            applyTransferCategory(to: pos, category: transferCategory)
            counts.paired += 1
        }

        return counts
    }

    /// Compute the candidate positive transactions for an outgoing transfer
    /// on demand. Used by the Review sheet.
    nonisolated static func candidates(for outgoing: Transaction, in context: ModelContext) -> [Transaction] {
        let known = InternalTransferDetector.knownAccounts(in: context)
        guard let destination = InternalTransferDetector.matchedDestination(
            for: outgoing.text, known: known
        ) else {
            return []
        }
        return findCandidates(
            for: outgoing,
            destination: destination,
            in: context,
            excluding: []
        )
    }

    /// Find positive transactions in `destination` on the same booking date as
    /// `outgoing` whose amount equals `|outgoing.amount|`, excluding IDs already
    /// consumed by an earlier pair in the current pass.
    private nonisolated static func findCandidates(
        for outgoing: Transaction,
        destination: Account,
        in context: ModelContext,
        excluding: Set<PersistentIdentifier>
    ) -> [Transaction] {
        let destID = destination.persistentModelID
        let bookingDate = outgoing.bookingDate
        let absAmount = abs(outgoing.amount)
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: bookingDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return []
        }

        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { tx in
                tx.account?.persistentModelID == destID
                    && tx.bookingDate >= dayStart
                    && tx.bookingDate < dayEnd
                    && tx.amount == absAmount
                    && tx.transferStatusSourceRaw != 1
            }
        )
        descriptor.fetchLimit = 10
        let results = (try? context.fetch(descriptor)) ?? []
        return results.filter { !excluding.contains($0.persistentModelID) }
    }

    // MARK: - Single-transaction mutators

    /// Flag or unflag a single transaction manually. Sets
    /// `transferStatusSource = .manual` so subsequent rescans don't overwrite.
    /// Also sets/clears the Internal Transfer category alongside.
    nonisolated static func setManualTransferFlag(
        _ tx: Transaction,
        isTransfer: Bool,
        in context: ModelContext
    ) {
        let transferCategory = fetchInternalTransferCategory(in: context)
        if isTransfer {
            tx.transferStatus = tx.amount < 0 ? .pairedOutgoing : .pairedIncoming
            applyTransferCategory(to: tx, category: transferCategory)
        } else {
            tx.transferStatus = .none
            clearTransferCategoryIfAuto(from: tx, category: transferCategory)
        }
        tx.transferStatusSource = .manual
    }

    /// Apply a user-picked pair inside the Review sheet: outgoing becomes
    /// pairedOutgoing, picked positive becomes pairedIncoming, both auto,
    /// and both get the Internal Transfer category.
    nonisolated static func applyUserPair(
        outgoing: Transaction,
        picked: Transaction,
        in context: ModelContext
    ) {
        let transferCategory = fetchInternalTransferCategory(in: context)
        outgoing.transferStatus = .pairedOutgoing
        outgoing.transferStatusSource = .auto
        applyTransferCategory(to: outgoing, category: transferCategory)
        picked.transferStatus = .pairedIncoming
        picked.transferStatusSource = .auto
        applyTransferCategory(to: picked, category: transferCategory)
    }

    /// The user picked "none of these" in the Review sheet for an ambiguous
    /// outgoing. Demote to unmatched so it stays visible as a problem. The
    /// Internal Transfer category stays — it's still a transfer, just
    /// unresolved.
    nonisolated static func demoteToUnmatched(_ outgoing: Transaction) {
        outgoing.transferStatus = .unmatched
        outgoing.transferStatusSource = .auto
    }

    /// The user picked "mark as external" in the Review sheet for an unmatched
    /// outgoing. Clear the flag permanently AND clear the auto-assigned
    /// Internal Transfer category so the row becomes an ordinary spending row
    /// that normal rules can re-categorize.
    nonisolated static func markAsExternal(_ outgoing: Transaction, in context: ModelContext) {
        let transferCategory = fetchInternalTransferCategory(in: context)
        outgoing.transferStatus = .none
        clearTransferCategoryIfAuto(from: outgoing, category: transferCategory)
        outgoing.transferStatusSource = .manual
    }

    /// Fetch all transactions currently in `.ambiguous` or `.unmatched` state.
    /// Used by the menu-driven "Review Transfers…" command.
    nonisolated static func fetchUnresolved(in context: ModelContext) -> [Transaction] {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.transferStatusRaw == 3 || $0.transferStatusRaw == 4 },
            sortBy: [SortDescriptor(\Transaction.bookingDate)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
