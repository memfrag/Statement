//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData
import Charts

private struct AnalysisKey: Hashable {
    let revision: Int
    let signature: String
}

// MARK: - 1. Spending Velocity

struct SpendingVelocityView: View {
    @Environment(AnalyticsCache.self) private var cache
    @Environment(AppSignals.self) private var signals

    @State private var months: [VelocityMonth] = []
    @State private var isComputing: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Spending velocity")
                    .font(.headline)
                Text("Cumulative daily spend. Current month vs. previous months.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isComputing && months.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Calculating…").foregroundStyle(.secondary)
                    }
                } else if months.isEmpty {
                    Text("Not enough data.")
                        .foregroundStyle(.secondary)
                } else {
                    Chart {
                        ForEach(months) { month in
                            ForEach(month.points, id: \.dayOfMonth) { point in
                                LineMark(
                                    x: .value("Day", point.dayOfMonth),
                                    y: .value("Spend", point.cumulativeSpend),
                                    series: .value("Month", month.label)
                                )
                                .foregroundStyle(by: .value("Month", month.label))
                                .interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: month.isCurrent ? 3 : 1.5))
                                .opacity(month.isCurrent ? 1.0 : 0.5)
                            }
                        }
                    }
                    .chartXAxisLabel("Day of month")
                    .chartYAxisLabel("Cumulative spend (kr)")
                    .frame(height: 400)

                    // Summary
                    let current = months.last(where: \.isCurrent)
                    let previous = months.filter { !$0.isCurrent }
                    if let c = current, let lastPoint = c.points.last {
                        let previousAvg = previous.compactMap { m -> Double? in
                            m.points.first { $0.dayOfMonth == lastPoint.dayOfMonth }?.cumulativeSpend
                        }
                        let avg = previousAvg.isEmpty ? 0 : previousAvg.reduce(0, +) / Double(previousAvg.count)
                        let diff = lastPoint.cumulativeSpend - avg
                        HStack(spacing: 14) {
                            KpiCard(
                                label: "This month so far",
                                value: MoneyFormatter.shortKr(Decimal(lastPoint.cumulativeSpend)),
                                subtitle: "day \(lastPoint.dayOfMonth)"
                            )
                            if avg > 0 {
                                KpiCard(
                                    label: "vs. average",
                                    value: "\(diff >= 0 ? "+" : "")\(MoneyFormatter.shortKr(Decimal(diff)))",
                                    subtitle: "same day in prev months",
                                    color: diff <= 0 ? .green : .red
                                )
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .task(id: signals.storeRevision) {
            if months.isEmpty { isComputing = true }
            months = await cache.spendingVelocity()
            isComputing = false
        }
    }
}

// MARK: - 2. Category Share Over Time

struct CategoryShareView: View {
    @Environment(AnalyticsCache.self) private var cache
    @Environment(AppSignals.self) private var signals
    @Environment(AnalysisFilter.self) private var filter

    @State private var rows: [MonthlyCategoryRow] = []
    @State private var colors: [CategoryColor] = []
    @State private var isComputing: Bool = false

    private var currentKey: AnalysisKey {
        AnalysisKey(revision: signals.storeRevision, signature: filter.signature)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Category share over time")
                    .font(.headline)
                Text("Each bar is 100% of that month's spend, split by category.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isComputing && rows.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Calculating…").foregroundStyle(.secondary)
                    }
                } else if rows.isEmpty {
                    Text("No transactions in range.")
                        .foregroundStyle(.secondary)
                } else {
                    shareChart
                }
            }
            .padding(24)
        }
        .task(id: currentKey) {
            if rows.isEmpty { isComputing = true }
            let result = await cache.monthlyCategoryBreakdown(in: filter.range)
            rows = result.rows
            colors = result.colors
            isComputing = false
        }
        .onAppear {
            if let cached = cache.peekMonthlyCategory(for: filter.range) {
                rows = cached.rows
                colors = cached.colors
            }
        }
    }

    @ViewBuilder
    private var shareChart: some View {
        let percentRows = percentageRows()
        let (domain, range) = colorScale()
        Chart {
            ForEach(percentRows, id: \.id) { row in
                BarMark(
                    x: .value("Month", row.month, unit: .month),
                    y: .value("Share", row.amount)
                )
                .foregroundStyle(by: .value("Category", row.categoryName))
            }
        }
        .chartYAxis {
            AxisMarks(format: FloatingPointFormatStyle<Double>.Percent())
        }
        .chartForegroundStyleScale(domain: domain, range: range)
        .frame(height: 360)
    }

    /// Convert absolute amounts to 0–1 fractions per month.
    private func percentageRows() -> [MonthlyCategoryRow] {
        let calendar = Calendar(identifier: .gregorian)
        var monthlyTotals: [Date: Double] = [:]
        for row in rows {
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: row.month)) ?? row.month
            monthlyTotals[month, default: 0] += row.amount
        }
        return rows.map { row in
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: row.month)) ?? row.month
            let total = monthlyTotals[month] ?? 1
            let fraction = total > 0 ? row.amount / total : 0
            return MonthlyCategoryRow(
                id: UUID(),
                month: row.month,
                categoryName: row.categoryName,
                colorIndex: row.colorIndex,
                amount: fraction
            )
        }
    }

    private func colorScale() -> (domain: [String], range: [Color]) {
        var domain: [String] = []
        var range: [Color] = []
        for color in colors {
            domain.append(color.name)
            range.append(color.colorIndex < 0 ? .secondary : AccountPalette.color(for: color.colorIndex))
        }
        return (domain, range)
    }
}

// MARK: - 3. Spending Heatmap

struct SpendingHeatmapView: View {
    @Environment(AnalyticsCache.self) private var cache
    @Environment(AppSignals.self) private var signals
    @Environment(AnalysisFilter.self) private var filter

    @State private var data: [DailySpend] = []
    @State private var isComputing: Bool = false

    private var currentKey: AnalysisKey {
        AnalysisKey(revision: signals.storeRevision, signature: filter.signature)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Spending heatmap")
                    .font(.headline)
                Text("Daily spend intensity. More intense color = more spent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isComputing && data.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Calculating…").foregroundStyle(.secondary)
                    }
                } else if data.isEmpty {
                    Text("No transactions in range.")
                        .foregroundStyle(.secondary)
                } else {
                    heatmapGrid
                }
            }
            .padding(24)
        }
        .task(id: currentKey) {
            if data.isEmpty { isComputing = true }
            data = await cache.dailySpendHeatmap(in: filter.range)
            isComputing = false
        }
    }

    private var heatmapGrid: some View {
        let calendar = Calendar(identifier: .gregorian)
        let maxAmount = data.map(\.amount).max() ?? 1
        let lookup = Dictionary(data.map { (calendar.startOfDay(for: $0.date), $0.amount) },
                                uniquingKeysWith: +)

        // Build weeks: each week is Mon–Sun, 7 slots
        let allDates = data.map(\.date).sorted()
        let firstDay = allDates.first ?? .now
        let lastDay = allDates.last ?? .now

        struct WeekData: Identifiable {
            let id: Int
            let weekOfYear: Int
            let year: Int
            let days: [(weekday: Int, date: Date, amount: Double)]
        }

        var weeks: [WeekData] = []
        var cursor = calendar.startOfDay(for: firstDay)
        // Rewind to Monday
        let weekday = calendar.component(.weekday, from: cursor)
        let daysToMonday = (weekday + 5) % 7
        cursor = calendar.date(byAdding: .day, value: -daysToMonday, to: cursor) ?? cursor

        var weekIndex = 0
        let endDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDay)) ?? lastDay
        while cursor < endDate {
            var days: [(weekday: Int, date: Date, amount: Double)] = []
            for d in 0..<7 {
                let day = calendar.date(byAdding: .day, value: d, to: cursor) ?? cursor
                let wd = (d + 1) // Mon=1..Sun=7
                let amount = lookup[calendar.startOfDay(for: day)] ?? 0
                days.append((wd, day, amount))
            }
            let wy = calendar.component(.weekOfYear, from: cursor)
            let yr = calendar.component(.yearForWeekOfYear, from: cursor)
            weeks.append(WeekData(id: weekIndex, weekOfYear: wy, year: yr, days: days))
            cursor = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor) ?? cursor
            weekIndex += 1
        }

        return VStack(alignment: .leading, spacing: 8) {
            // Day labels
            let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]

            HStack(alignment: .top, spacing: 2) {
                VStack(spacing: 2) {
                    ForEach(Array(dayLabels.enumerated()), id: \.offset) { _, label in
                        Text(label)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(weeks) { week in
                            VStack(spacing: 2) {
                                ForEach(week.days, id: \.weekday) { day in
                                    let intensity = maxAmount > 0 ? day.amount / maxAmount : 0
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(heatmapColor(intensity: intensity, hasData: day.amount > 0))
                                        .frame(width: 14, height: 14)
                                        .help(day.amount > 0
                                              ? "\(DateFormatters.shortDay.string(from: day.date)): \(MoneyFormatter.shortKr(Decimal(day.amount)))"
                                              : DateFormatters.shortDay.string(from: day.date))
                                }
                            }
                        }
                    }
                }
            }

            // Legend
            HStack(spacing: 4) {
                Text("Less")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(heatmapColor(intensity: level, hasData: level > 0))
                        .frame(width: 14, height: 14)
                }
                Text("More")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func heatmapColor(intensity: Double, hasData: Bool) -> Color {
        if !hasData {
            return Color(nsColor: .controlBackgroundColor)
        }
        return Color.green.opacity(0.15 + intensity * 0.85)
    }
}

// MARK: - 4. Recurring Transactions

struct RecurringTransactionsView: View {
    @Environment(AnalyticsCache.self) private var cache
    @Environment(AppSignals.self) private var signals
    @Environment(AnalysisFilter.self) private var filter

    @State private var items: [RecurringItem] = []
    @State private var isComputing: Bool = false
    @State private var hideInactive: Bool = false

    private var currentKey: AnalysisKey {
        AnalysisKey(revision: signals.storeRevision, signature: filter.signature)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Recurring transactions")
                    .font(.headline)
                Spacer()
                Toggle("Hide inactive", isOn: $hideInactive)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text("Auto-detected subscriptions and regular payments (~monthly, 3+ occurrences).")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isComputing && items.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Calculating…").foregroundStyle(.secondary)
                }
            } else if items.isEmpty {
                Text("No recurring patterns found.")
                    .foregroundStyle(.secondary)
            } else {
                let activeItems = items.filter { !$0.isLikelyInactive }
                let inactiveCount = items.count - activeItems.count
                let totalAnnual = activeItems.reduce(into: Decimal(0)) { $0 += $1.estimatedAnnualCost }
                let totalMonthly = totalAnnual / 12
                HStack(spacing: 14) {
                    KpiCard(
                        label: "Active subscriptions",
                        value: "\(activeItems.count)",
                        subtitle: inactiveCount > 0 ? "+\(inactiveCount) inactive" : nil
                    )
                    KpiCard(
                        label: "Est. monthly",
                        value: MoneyFormatter.shortKr(totalMonthly),
                        subtitle: "active only"
                    )
                    KpiCard(
                        label: "Est. annual",
                        value: MoneyFormatter.shortKr(totalAnnual),
                        subtitle: "active only",
                        color: .red
                    )
                }

                let displayedItems = hideInactive ? items.filter { !$0.isLikelyInactive } : items
                Table(displayedItems) {
                        TableColumn("Name") { item in
                            Text(item.merchant)
                                .fontWeight(.medium)
                        }

                        TableColumn("Occurrences") { item in
                            Text("\(item.occurrences)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .width(min: 80, ideal: 100)

                        TableColumn("Avg. amount") { item in
                            Text(MoneyFormatter.shortKr(item.avgAmount))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(min: 100, ideal: 130)

                        TableColumn("Interval") { item in
                            Text("~\(item.avgIntervalDays)d")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .width(min: 70, ideal: 80)

                        TableColumn("Est. annual") { item in
                            Text(MoneyFormatter.shortKr(item.estimatedAnnualCost))
                                .monospacedDigit()
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(min: 110, ideal: 140)

                        TableColumn("Last payment") { item in
                            HStack(spacing: 6) {
                                Text(DateFormatters.shortDay.string(from: item.lastPaymentDate))
                                    .foregroundStyle(item.isLikelyInactive ? .secondary : .primary)
                                if item.isLikelyInactive {
                                    Text("inactive")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            Capsule().fill(Color.orange)
                                        )
                                }
                            }
                        }
                        .width(min: 130, ideal: 170)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: currentKey) {
            if items.isEmpty { isComputing = true }
            items = await cache.recurringTransactions(in: filter.range)
            isComputing = false
        }
    }
}

// MARK: - Filler removed — brace was extra from ScrollView removal

// MARK: - 5. Year-over-Year Comparison

struct YearOverYearView: View {
    @Environment(AnalyticsCache.self) private var cache
    @Environment(AppSignals.self) private var signals
    @Environment(AnalysisFilter.self) private var filter

    @State private var series: [IncomeExpensePoint] = []
    @State private var isComputing: Bool = false

    private var currentKey: AnalysisKey {
        AnalysisKey(revision: signals.storeRevision, signature: filter.signature)
    }

    /// Group expense data by year, with months as 1–12 on the x-axis.
    private var yearSeries: [(year: Int, points: [(month: Int, expenses: Double)])] {
        let calendar = Calendar(identifier: .gregorian)
        var grouped: [Int: [Int: Double]] = [:]
        for point in series {
            let year = calendar.component(.year, from: point.month)
            let month = calendar.component(.month, from: point.month)
            grouped[year, default: [:]][month] = point.expenses
        }
        return grouped.keys.sorted().map { year in
            let byMonth = grouped[year] ?? [:]
            let points = (1...12).compactMap { m -> (month: Int, expenses: Double)? in
                guard let e = byMonth[m] else {
                    return nil
                }
                return (m, e)
            }
            return (year, points)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Year-over-year comparison")
                    .font(.headline)
                Text("Monthly expenses, one line per year.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isComputing && series.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Calculating…").foregroundStyle(.secondary)
                    }
                } else if series.isEmpty {
                    Text("No transactions in range.")
                        .foregroundStyle(.secondary)
                } else {
                    let ys = yearSeries
                    Chart {
                        ForEach(ys, id: \.year) { yearData in
                            ForEach(yearData.points, id: \.month) { point in
                                LineMark(
                                    x: .value("Month", point.month),
                                    y: .value("Expenses", point.expenses),
                                    series: .value("Year", "\(yearData.year)")
                                )
                                .foregroundStyle(by: .value("Year", "\(yearData.year)"))
                                .interpolationMethod(.monotone)

                                PointMark(
                                    x: .value("Month", point.month),
                                    y: .value("Expenses", point.expenses)
                                )
                                .foregroundStyle(by: .value("Year", "\(yearData.year)"))
                            }
                        }
                    }
                    .chartXScale(domain: 1...12)
                    .chartXAxis {
                        AxisMarks(values: Array(1...12)) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
                                if let idx = value.as(Int.self), idx >= 1, idx <= 12 {
                                    Text(monthNames[idx - 1])
                                }
                            }
                        }
                    }
                    .frame(height: 360)

                    // Annual totals table
                    let annualTotals = ys.map { (year: $0.year, total: $0.points.reduce(0) { $0 + $1.expenses }) }
                    if !annualTotals.isEmpty {
                        Text("Annual totals")
                            .font(.subheadline.weight(.semibold))
                        VStack(spacing: 0) {
                            ForEach(annualTotals, id: \.year) { item in
                                HStack {
                                    Text("\(item.year)")
                                        .monospacedDigit()
                                    Spacer()
                                    Text(MoneyFormatter.shortKr(Decimal(item.total)))
                                        .monospacedDigit()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                Divider()
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(24)
        }
        .task(id: currentKey) {
            if series.isEmpty { isComputing = true }
            // Use nil range to get all data for year comparison
            series = await cache.incomeVsExpenses(in: nil)
            isComputing = false
        }
    }
}

// MARK: - 6. Largest Transactions

struct LargestTransactionsView: View {
    enum AmountFilter: String, CaseIterable, Identifiable {
        case absolute = "By absolute"
        case positive = "Largest positive"
        case negative = "Largest negative"
        var id: String { rawValue }
    }

    @Environment(AnalyticsCache.self) private var cache
    @Environment(AppSignals.self) private var signals
    @Environment(AnalysisFilter.self) private var filter

    @State private var rows: [LargeTransaction] = []
    @State private var isComputing: Bool = false
    @State private var amountFilter: AmountFilter = .absolute

    private var currentKey: AnalysisKey {
        AnalysisKey(revision: signals.storeRevision, signature: filter.signature)
    }

    private var displayedRows: [LargeTransaction] {
        switch amountFilter {
        case .absolute:
            return Array(rows.sorted { abs($0.amount) > abs($1.amount) }.prefix(50))
        case .positive:
            return Array(rows.filter { $0.amount > 0 }.sorted { $0.amount > $1.amount }.prefix(50))
        case .negative:
            return Array(rows.filter { $0.amount < 0 }.sorted { $0.amount < $1.amount }.prefix(50))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Largest transactions")
                    .font(.headline)
                Spacer()
                Picker("Filter", selection: $amountFilter) {
                    ForEach(AmountFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 380)
            }
            Text("Top 50 excluding internal transfers.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isComputing && rows.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Calculating…").foregroundStyle(.secondary)
                }
            } else if rows.isEmpty {
                Text("No transactions in range.")
                    .foregroundStyle(.secondary)
            } else {
                transactionTable
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: currentKey) {
            if rows.isEmpty { isComputing = true }
            // Fetch more than 50 so we can split into positive/negative
            rows = await cache.largestTransactions(limit: 200, in: filter.range)
            isComputing = false
        }
    }

    private var transactionTable: some View {
        Table(displayedRows) {
            TableColumn("Date") { tx in
                Text(DateFormatters.shortDay.string(from: tx.date))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 110)

            TableColumn("Text") { tx in
                Text(tx.displayText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            TableColumn("Category") { tx in
                if let name = tx.categoryName {
                    Text(name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 120, ideal: 160)

            TableColumn("Account") { tx in
                if let name = tx.accountName {
                    Text(name)
                        .lineLimit(1)
                }
            }
            .width(min: 100, ideal: 130)

            TableColumn("Amount") { tx in
                Text(MoneyFormatter.signedString(tx.amount))
                    .monospacedDigit()
                    .foregroundStyle(tx.amount >= 0 ? Color.green : Color.primary)
                    .fontWeight(tx.amount >= 0 ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 100, ideal: 130)
        }
    }
}
