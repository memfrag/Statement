//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData

/// Main-actor cache that sits between the views and `AnalyticsActor`.
///
/// Each analysis kind keeps the last computed result along with the
/// `(storeRevision, dateRangeSignature)` it was computed for. If a
/// view asks for results and both match, the cache returns the stored
/// value immediately without touching the background actor. When the
/// store mutates or the filter changes, the next call falls through
/// to the actor and re-caches.
@MainActor
@Observable
final class AnalyticsCache {

    // MARK: Dependencies

    private let actor: AnalyticsActor
    private let signals: AppSignals

    // MARK: Cached slots

    private struct Slot<Value> {
        var revision: Int = .min
        var signature: String = ""
        var value: Value
    }

    private var netWorth: Slot<[NetWorthMonth]> = .init(value: [])
    private var monthlyCategory: Slot<(rows: [MonthlyCategoryRow], colors: [CategoryColor])>
        = .init(value: ([], []))
    private var incomeExpense: Slot<[IncomeExpensePoint]> = .init(value: [])
    private var topMerchantsSlot: Slot<[MerchantRow]> = .init(value: [])
    private var velocitySlot: Slot<[VelocityMonth]> = .init(value: [])
    private var heatmapSlot: Slot<[DailySpend]> = .init(value: [])
    private var recurringSlot: Slot<[RecurringItem]> = .init(value: [])
    private var largestSlot: Slot<[LargeTransaction]> = .init(value: [])
    // Account balances are filter-agnostic so they use only revision.
    private var accountBalances: Slot<[String: Decimal]> = .init(value: [:])

    // MARK: Init

    init(actor: AnalyticsActor, signals: AppSignals) {
        self.actor = actor
        self.signals = signals
    }

    // MARK: Helpers

    private static func signature(for range: ClosedRange<Date>?) -> String {
        guard let range else {
            return "all"
        }
        let lo = Int(range.lowerBound.timeIntervalSince1970)
        let hi = Int(range.upperBound.timeIntervalSince1970)
        return "\(lo)-\(hi)"
    }

    // MARK: Accessors

    func netWorthSeries(in range: ClosedRange<Date>? = nil) async -> [NetWorthMonth] {
        let sig = Self.signature(for: range)
        let current = signals.storeRevision
        if current == netWorth.revision && sig == netWorth.signature {
            return netWorth.value
        }
        let fresh = await actor.netWorthSeries(in: range)
        netWorth = .init(revision: current, signature: sig, value: fresh)
        return fresh
    }

    func monthlyCategoryBreakdown(in range: ClosedRange<Date>? = nil) async -> (rows: [MonthlyCategoryRow], colors: [CategoryColor]) {
        let sig = Self.signature(for: range)
        let current = signals.storeRevision
        if current == monthlyCategory.revision && sig == monthlyCategory.signature {
            return monthlyCategory.value
        }
        let fresh = await actor.monthlyCategoryBreakdown(in: range)
        monthlyCategory = .init(revision: current, signature: sig, value: fresh)
        return fresh
    }

    func incomeVsExpenses(in range: ClosedRange<Date>? = nil) async -> [IncomeExpensePoint] {
        let sig = Self.signature(for: range)
        let current = signals.storeRevision
        if current == incomeExpense.revision && sig == incomeExpense.signature {
            return incomeExpense.value
        }
        let fresh = await actor.incomeVsExpenses(in: range)
        incomeExpense = .init(revision: current, signature: sig, value: fresh)
        return fresh
    }

    func topMerchants(limit: Int = 25, in range: ClosedRange<Date>? = nil) async -> [MerchantRow] {
        let sig = Self.signature(for: range) + "::\(limit)"
        let current = signals.storeRevision
        if current == topMerchantsSlot.revision && sig == topMerchantsSlot.signature {
            return topMerchantsSlot.value
        }
        let fresh = await actor.topMerchants(limit: limit, in: range)
        topMerchantsSlot = .init(revision: current, signature: sig, value: fresh)
        return fresh
    }

    func spendingVelocity() async -> [VelocityMonth] {
        let sig = "velocity"
        let current = signals.storeRevision
        if current == velocitySlot.revision && sig == velocitySlot.signature {
            return velocitySlot.value
        }
        let fresh = await actor.spendingVelocity()
        velocitySlot = .init(revision: current, signature: sig, value: fresh)
        return fresh
    }

    func dailySpendHeatmap(in range: ClosedRange<Date>? = nil) async -> [DailySpend] {
        let sig = Self.signature(for: range)
        let current = signals.storeRevision
        if current == heatmapSlot.revision && sig == heatmapSlot.signature {
            return heatmapSlot.value
        }
        let fresh = await actor.dailySpendHeatmap(in: range)
        heatmapSlot = .init(revision: current, signature: sig, value: fresh)
        return fresh
    }

    func recurringTransactions(in range: ClosedRange<Date>? = nil) async -> [RecurringItem] {
        let sig = Self.signature(for: range)
        let current = signals.storeRevision
        if current == recurringSlot.revision && sig == recurringSlot.signature {
            return recurringSlot.value
        }
        let fresh = await actor.recurringTransactions(in: range)
        recurringSlot = .init(revision: current, signature: sig, value: fresh)
        return fresh
    }

    func largestTransactions(limit: Int = 50, in range: ClosedRange<Date>? = nil) async -> [LargeTransaction] {
        let sig = Self.signature(for: range) + "::\(limit)"
        let current = signals.storeRevision
        if current == largestSlot.revision && sig == largestSlot.signature {
            return largestSlot.value
        }
        let fresh = await actor.largestTransactions(limit: limit, in: range)
        largestSlot = .init(revision: current, signature: sig, value: fresh)
        return fresh
    }

    func accountLatestBalances() async -> [String: Decimal] {
        let current = signals.storeRevision
        if current == accountBalances.revision {
            return accountBalances.value
        }
        let fresh = await actor.accountLatestBalances()
        accountBalances = .init(revision: current, signature: "", value: fresh)
        return fresh
    }

    /// Force every slot to be dirty — next call will always re-fetch.
    func invalidateAll() {
        netWorth.revision = .min
        monthlyCategory.revision = .min
        incomeExpense.revision = .min
        topMerchantsSlot.revision = .min
        velocitySlot.revision = .min
        heatmapSlot.revision = .min
        recurringSlot.revision = .min
        largestSlot.revision = .min
        accountBalances.revision = .min
    }

    // MARK: Synchronous peeks (for onAppear pre-populate)

    /// Returns the cached value only if both the revision and signature match.
    func peekNetWorth(for range: ClosedRange<Date>?) -> [NetWorthMonth]? {
        let sig = Self.signature(for: range)
        if signals.storeRevision == netWorth.revision && sig == netWorth.signature {
            return netWorth.value
        }
        return nil
    }

    func peekMonthlyCategory(for range: ClosedRange<Date>?) -> (rows: [MonthlyCategoryRow], colors: [CategoryColor])? {
        let sig = Self.signature(for: range)
        if signals.storeRevision == monthlyCategory.revision && sig == monthlyCategory.signature {
            return monthlyCategory.value
        }
        return nil
    }

    func peekIncomeExpense(for range: ClosedRange<Date>?) -> [IncomeExpensePoint]? {
        let sig = Self.signature(for: range)
        if signals.storeRevision == incomeExpense.revision && sig == incomeExpense.signature {
            return incomeExpense.value
        }
        return nil
    }

    func peekTopMerchants(limit: Int = 25, for range: ClosedRange<Date>?) -> [MerchantRow]? {
        let sig = Self.signature(for: range) + "::\(limit)"
        if signals.storeRevision == topMerchantsSlot.revision && sig == topMerchantsSlot.signature {
            return topMerchantsSlot.value
        }
        return nil
    }

    func peekAccountLatestBalances() -> [String: Decimal]? {
        if signals.storeRevision == accountBalances.revision {
            return accountBalances.value
        }
        return nil
    }
}
