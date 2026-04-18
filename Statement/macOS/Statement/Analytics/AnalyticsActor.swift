//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData

// MARK: - Plain-value result types (Sendable, cross actor boundaries safely)

struct NetWorthMonth: Identifiable, Sendable, Hashable {
    let id: UUID
    let monthDate: Date
    let totalBalance: Decimal
    let perAccount: [AccountSlice]
}

struct AccountSlice: Sendable, Hashable {
    let accountName: String
    let colorIndex: Int
    let balance: Decimal
    let hasData: Bool
}

struct MonthlyCategoryRow: Identifiable, Sendable, Hashable {
    let id: UUID
    let month: Date
    let categoryName: String
    let colorIndex: Int
    let amount: Double
}

struct IncomeExpensePoint: Identifiable, Sendable, Hashable {
    let id: UUID
    let month: Date
    let income: Double
    let expenses: Double
}

struct MerchantRow: Identifiable, Sendable, Hashable {
    let id: UUID
    let merchant: String
    let count: Int
    let totalSpent: Decimal
}

struct CategoryColor: Sendable, Hashable {
    let name: String
    let colorIndex: Int
}

// MARK: - Spending velocity

struct VelocityPoint: Sendable, Hashable {
    let dayOfMonth: Int
    let cumulativeSpend: Double
}

struct VelocityMonth: Identifiable, Sendable, Hashable {
    let id: UUID
    let label: String        // e.g. "Apr 2026"
    let monthDate: Date
    let isCurrent: Bool
    let points: [VelocityPoint]
}

// MARK: - Daily spend (heatmap)

struct DailySpend: Identifiable, Sendable, Hashable {
    let id: UUID
    let date: Date
    let amount: Double  // absolute spend
}

// MARK: - Recurring transactions

struct RecurringItem: Identifiable, Sendable, Hashable {
    let id: UUID
    let merchant: String
    let occurrences: Int
    let avgAmount: Decimal
    let avgIntervalDays: Int
    let estimatedAnnualCost: Decimal
    let lastPaymentDate: Date
    /// True if the last payment was more than 2× the average interval ago.
    let isLikelyInactive: Bool
}

// MARK: - Largest transactions

struct LargeTransaction: Identifiable, Sendable, Hashable {
    let id: UUID
    let date: Date
    let text: String
    let displayText: String
    let categoryName: String?
    let accountName: String?
    let amount: Decimal
}

// MARK: - AnalyticsActor

/// Background model actor for analysis computations.
///
/// All heavy iteration (net worth, monthly category aggregation, top merchants,
/// rule hit counts) happens on this actor's isolated context, off the main thread.
/// Results are plain value types so they cross the actor boundary safely.
@ModelActor
actor AnalyticsActor {

    // MARK: Net worth on the 25th

    func netWorthSeries(in range: ClosedRange<Date>? = nil) -> [NetWorthMonth] {
        let accounts = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
        guard !accounts.isEmpty else {
            return []
        }

        // Pre-fetch each account's transactions once, sorted descending.
        // Avoids relationship faulting inside the inner loop and eliminates
        // the O(months × accounts × N log N) sort cost of the previous impl.
        var sortedPerAccount: [(account: Account, sorted: [Transaction])] = []
        var allBookingDates: [Date] = []
        for account in accounts {
            let accountID = account.persistentModelID
            let predicate = #Predicate<Transaction> { $0.account?.persistentModelID == accountID }
            var descriptor = FetchDescriptor<Transaction>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.bookingDate, order: .reverse)]
            )
            descriptor.propertiesToFetch = [\.bookingDate, \.runningBalance]
            let txs = (try? modelContext.fetch(descriptor)) ?? []
            sortedPerAccount.append((account, txs))
            if let newest = txs.first?.bookingDate { allBookingDates.append(newest) }
            if let oldest = txs.last?.bookingDate { allBookingDates.append(oldest) }
        }

        guard let firstDate = allBookingDates.min(),
              let lastDate = allBookingDates.max() else {
            return []
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current

        var months: [Date] = []
        var cursor = startOfMonth(firstDate, calendar: calendar)
        let end = startOfMonth(lastDate, calendar: calendar)
        while cursor <= end {
            if let twentyFifth = calendar.date(bySetting: .day, value: 25, of: cursor) {
                months.append(twentyFifth)
            }
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }

        // Filter output months to the caller's range (balances themselves
        // are still computed from all underlying data up to each anchor).
        if let range {
            months = months.filter { range.contains($0) }
        }

        return months.map { anchor in
            var total = Decimal(0)
            var slices: [AccountSlice] = []
            for (account, sorted) in sortedPerAccount {
                // `sorted` is descending, so the first tx with bookingDate <= anchor
                // is the latest. Linear scan with early-exit.
                let latestBefore = sorted.first { $0.bookingDate <= anchor }
                let bal = latestBefore?.runningBalance ?? 0
                total += bal
                slices.append(AccountSlice(
                    accountName: account.displayName,
                    colorIndex: account.colorIndex,
                    balance: bal,
                    hasData: latestBefore != nil
                ))
            }
            return NetWorthMonth(
                id: UUID(),
                monthDate: anchor,
                totalBalance: total,
                perAccount: slices
            )
        }
    }

    // MARK: Account latest balances (for sidebar)

    /// Fast, O(accounts) lookup of each account's latest running balance.
    /// Uses a per-account `fetchLimit = 1` query so we never touch the relationship.
    func accountLatestBalances() -> [String: Decimal] {
        let accounts = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
        var result: [String: Decimal] = [:]
        for account in accounts {
            let accountID = account.persistentModelID
            let predicate = #Predicate<Transaction> { $0.account?.persistentModelID == accountID }
            var descriptor = FetchDescriptor<Transaction>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.bookingDate, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.runningBalance]
            let latest = (try? modelContext.fetch(descriptor))?.first
            result[account.accountNumber] = latest?.runningBalance ?? 0
        }
        return result
    }

    private func startOfMonth(_ date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    // MARK: Monthly spend by category

    func monthlyCategoryBreakdown(in range: ClosedRange<Date>? = nil) -> (rows: [MonthlyCategoryRow], colors: [CategoryColor]) {
        var descriptor = FetchDescriptor<Transaction>(
            sortBy: [SortDescriptor(\.bookingDate)]
        )
        if let range {
            let lower = range.lowerBound
            let upper = range.upperBound
            descriptor.predicate = #Predicate<Transaction> {
                $0.transferStatusRaw == 0
                    && $0.bookingDate >= lower
                    && $0.bookingDate <= upper
            }
        } else {
            descriptor.predicate = #Predicate<Transaction> {
                $0.transferStatusRaw == 0
            }
        }
        let transactions = (try? modelContext.fetch(descriptor)) ?? []
        let categories = (try? modelContext.fetch(
            FetchDescriptor<Category>(sortBy: [SortDescriptor(\.sortIndex)])
        )) ?? []

        let calendar = Calendar(identifier: .gregorian)
        var grouped: [String: [Date: Decimal]] = [:]
        var colorFor: [String: Int] = [:]
        for category in categories {
            colorFor[category.name] = category.colorIndex
        }

        for tx in transactions where tx.amount < 0 {
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: tx.bookingDate)) ?? tx.bookingDate
            let name = tx.category?.name ?? "Uncategorized"
            grouped[name, default: [:]][month, default: 0] += abs(tx.amount)
        }

        var rows: [MonthlyCategoryRow] = []
        for (name, byMonth) in grouped {
            for (month, amount) in byMonth {
                rows.append(MonthlyCategoryRow(
                    id: UUID(),
                    month: month,
                    categoryName: name,
                    colorIndex: colorFor[name] ?? -1,
                    amount: NSDecimalNumber(decimal: amount).doubleValue
                ))
            }
        }
        rows.sort { $0.month < $1.month }

        var colors = categories.map { CategoryColor(name: $0.name, colorIndex: $0.colorIndex) }
        colors.append(CategoryColor(name: "Uncategorized", colorIndex: -1))
        return (rows, colors)
    }

    // MARK: Income vs. expenses

    func incomeVsExpenses(in range: ClosedRange<Date>? = nil) -> [IncomeExpensePoint] {
        var descriptor = FetchDescriptor<Transaction>(
            sortBy: [SortDescriptor(\.bookingDate)]
        )
        if let range {
            let lower = range.lowerBound
            let upper = range.upperBound
            descriptor.predicate = #Predicate<Transaction> {
                $0.transferStatusRaw == 0
                    && $0.bookingDate >= lower
                    && $0.bookingDate <= upper
            }
        } else {
            descriptor.predicate = #Predicate<Transaction> {
                $0.transferStatusRaw == 0
            }
        }
        let transactions = (try? modelContext.fetch(descriptor)) ?? []

        let calendar = Calendar(identifier: .gregorian)
        var byMonth: [Date: (income: Decimal, expenses: Decimal)] = [:]
        for tx in transactions {
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: tx.bookingDate)) ?? tx.bookingDate
            var current = byMonth[month, default: (0, 0)]
            if tx.amount >= 0 {
                current.income += tx.amount
            } else {
                current.expenses += abs(tx.amount)
            }
            byMonth[month] = current
        }
        return byMonth
            .map { IncomeExpensePoint(
                id: UUID(),
                month: $0.key,
                income: NSDecimalNumber(decimal: $0.value.income).doubleValue,
                expenses: NSDecimalNumber(decimal: $0.value.expenses).doubleValue
            ) }
            .sorted { $0.month < $1.month }
    }

    // MARK: Top merchants

    func topMerchants(limit: Int = 25, in range: ClosedRange<Date>? = nil) -> [MerchantRow] {
        var descriptor = FetchDescriptor<Transaction>()
        if let range {
            let lower = range.lowerBound
            let upper = range.upperBound
            descriptor.predicate = #Predicate<Transaction> {
                $0.transferStatusRaw == 0
                    && $0.bookingDate >= lower
                    && $0.bookingDate <= upper
            }
        } else {
            descriptor.predicate = #Predicate<Transaction> {
                $0.transferStatusRaw == 0
            }
        }
        let transactions = (try? modelContext.fetch(descriptor)) ?? []

        var totals: [String: (count: Int, amount: Decimal)] = [:]
        for tx in transactions where tx.amount < 0 {
            let key = tx.text.split(separator: "/").first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? tx.text
            var cur = totals[key, default: (0, 0)]
            cur.count += 1
            cur.amount += abs(tx.amount)
            totals[key] = cur
        }
        let rows = totals
            .map { MerchantRow(id: UUID(), merchant: $0.key, count: $0.value.count, totalSpent: $0.value.amount) }
            .sorted { $0.totalSpent > $1.totalSpent }
        return Array(rows.prefix(limit))
    }

    // MARK: Spending velocity

    /// Cumulative daily spend for the current month and several preceding
    /// months. Each month starts at day 1 with cumulative=0 and grows.
    func spendingVelocity(referenceDate: Date = .now, monthsBack: Int = 3) -> [VelocityMonth] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current

        let refMonth = startOfMonth(referenceDate, calendar: calendar)
        var months: [(start: Date, end: Date, label: String, isCurrent: Bool)] = []
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM yyyy"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        for i in (0...monthsBack).reversed() {
            guard let start = calendar.date(byAdding: .month, value: -i, to: refMonth),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else {
                continue
            }
            months.append((start, end, fmt.string(from: start), i == 0))
        }

        guard let globalStart = months.first?.start,
              let globalEnd = months.last?.end else {
            return []
        }

        let lower = globalStart
        let upper = globalEnd
        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> {
                $0.transferStatusRaw == 0
                    && $0.amount < 0
                    && $0.bookingDate >= lower
                    && $0.bookingDate < upper
            },
            sortBy: [SortDescriptor(\.bookingDate)]
        )
        descriptor.propertiesToFetch = [\.bookingDate, \.amount]
        let txs = (try? modelContext.fetch(descriptor)) ?? []

        return months.map { m in
            var daily: [Int: Decimal] = [:]
            for tx in txs {
                if tx.bookingDate >= m.start && tx.bookingDate < m.end {
                    let day = calendar.component(.day, from: tx.bookingDate)
                    daily[day, default: 0] += abs(tx.amount)
                }
            }
            let maxDay = m.isCurrent
                ? calendar.component(.day, from: referenceDate)
                : (calendar.range(of: .day, in: .month, for: m.start)?.count ?? 30)
            var cumulative: Decimal = 0
            var points: [VelocityPoint] = []
            for day in 1...maxDay {
                cumulative += daily[day] ?? 0
                points.append(VelocityPoint(
                    dayOfMonth: day,
                    cumulativeSpend: NSDecimalNumber(decimal: cumulative).doubleValue
                ))
            }
            return VelocityMonth(
                id: UUID(),
                label: m.label,
                monthDate: m.start,
                isCurrent: m.isCurrent,
                points: points
            )
        }
    }

    // MARK: Daily spend heatmap

    func dailySpendHeatmap(in range: ClosedRange<Date>? = nil) -> [DailySpend] {
        var descriptor = FetchDescriptor<Transaction>()
        if let range {
            let lower = range.lowerBound
            let upper = range.upperBound
            descriptor.predicate = #Predicate<Transaction> {
                $0.transferStatusRaw == 0
                    && $0.amount < 0
                    && $0.bookingDate >= lower
                    && $0.bookingDate <= upper
            }
        } else {
            descriptor.predicate = #Predicate<Transaction> {
                $0.transferStatusRaw == 0
                    && $0.amount < 0
            }
        }
        let txs = (try? modelContext.fetch(descriptor)) ?? []

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current

        var daily: [Date: Decimal] = [:]
        for tx in txs {
            let day = calendar.startOfDay(for: tx.bookingDate)
            daily[day, default: 0] += abs(tx.amount)
        }
        return daily
            .map { DailySpend(id: UUID(), date: $0.key, amount: NSDecimalNumber(decimal: $0.value).doubleValue) }
            .sorted { $0.date < $1.date }
    }

    // MARK: Recurring transactions

    func recurringTransactions(in range: ClosedRange<Date>? = nil) -> [RecurringItem] {
        var descriptor = FetchDescriptor<Transaction>(
            sortBy: [SortDescriptor(\.bookingDate)]
        )
        if let range {
            let lower = range.lowerBound
            let upper = range.upperBound
            descriptor.predicate = #Predicate<Transaction> {
                $0.transferStatusRaw == 0
                    && $0.amount < 0
                    && $0.bookingDate >= lower
                    && $0.bookingDate <= upper
            }
        } else {
            descriptor.predicate = #Predicate<Transaction> {
                $0.transferStatusRaw == 0
                    && $0.amount < 0
            }
        }
        let txs = (try? modelContext.fetch(descriptor)) ?? []

        // Group by display text (userText ?? text)
        var groups: [String: [(date: Date, amount: Decimal)]] = [:]
        for tx in txs {
            let key = tx.userText ?? tx.text
            groups[key, default: []].append((tx.bookingDate, abs(tx.amount)))
        }

        var results: [RecurringItem] = []
        for (merchant, entries) in groups {
            guard entries.count >= 3 else {
                continue
            }
            let sorted = entries.sorted { $0.date < $1.date }
            var intervals: [Int] = []
            for i in 1..<sorted.count {
                let days = Calendar.current.dateComponents([.day], from: sorted[i - 1].date, to: sorted[i].date).day ?? 0
                intervals.append(days)
            }
            let avgInterval = intervals.reduce(0, +) / max(intervals.count, 1)
            // Consider it recurring if average interval is 20–40 days
            // (roughly monthly) and stddev isn't too wild.
            guard avgInterval >= 20 && avgInterval <= 40 else {
                continue
            }
            let mean = Double(avgInterval)
            let variance = intervals.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(max(intervals.count, 1))
            let stddev = variance.squareRoot()
            guard stddev < 10 else {
                continue
            }
            let totalAmount = sorted.reduce(into: Decimal(0)) { $0 += $1.amount }
            let avgAmount = totalAmount / Decimal(sorted.count)
            let annualCost = avgAmount * 12
            let lastDate = sorted.last?.date ?? Date()
            let daysSinceLastPayment = Calendar.current.dateComponents(
                [.day], from: lastDate, to: Date()
            ).day ?? 0
            let isInactive = daysSinceLastPayment > avgInterval * 2
            results.append(RecurringItem(
                id: UUID(),
                merchant: merchant,
                occurrences: sorted.count,
                avgAmount: avgAmount,
                avgIntervalDays: avgInterval,
                estimatedAnnualCost: annualCost,
                lastPaymentDate: lastDate,
                isLikelyInactive: isInactive
            ))
        }
        return results.sorted { $0.estimatedAnnualCost > $1.estimatedAnnualCost }
    }

    // MARK: Largest transactions

    func largestTransactions(limit: Int = 50, in range: ClosedRange<Date>? = nil) -> [LargeTransaction] {
        var descriptor = FetchDescriptor<Transaction>()
        if let range {
            let lower = range.lowerBound
            let upper = range.upperBound
            descriptor.predicate = #Predicate<Transaction> {
                $0.transferStatusRaw == 0
                    && $0.bookingDate >= lower
                    && $0.bookingDate <= upper
            }
        } else {
            descriptor.predicate = #Predicate<Transaction> {
                $0.transferStatusRaw == 0
            }
        }
        let txs = (try? modelContext.fetch(descriptor)) ?? []
        let sorted = txs.sorted { abs($0.amount) > abs($1.amount) }
        return Array(sorted.prefix(limit)).map { tx in
            LargeTransaction(
                id: UUID(),
                date: tx.bookingDate,
                text: tx.text,
                displayText: tx.displayText,
                categoryName: tx.category?.name,
                accountName: tx.account?.displayName,
                amount: tx.amount
            )
        }
    }
}
