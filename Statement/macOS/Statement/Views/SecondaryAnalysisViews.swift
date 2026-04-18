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

// MARK: - Monthly spend by category

struct MonthlyCategoryView: View {
    @Environment(AnalyticsCache.self) private var cache
    @Environment(AppSignals.self) private var signals
    @Environment(AnalysisFilter.self) private var filter
    @Environment(\.modelContext) private var modelContext

    @State private var rows: [MonthlyCategoryRow] = []
    @State private var colors: [CategoryColor] = []
    @State private var isComputing: Bool = false
    @State private var hoveredDate: Date?
    @State private var selectedMonth: Date?
    @State private var selectedTransactions: [Transaction] = []
    /// Category names the user has unticked from the picker. Stored as the
    /// negative set so categories that only appear later in the date range
    /// still default to visible without any extra bookkeeping.
    @State private var hiddenCategoryNames: Set<String> = []

    /// `rows` minus any row whose category is currently hidden.
    private var visibleRows: [MonthlyCategoryRow] {
        guard !hiddenCategoryNames.isEmpty else {
            return rows
        }
        return rows.filter { !hiddenCategoryNames.contains($0.categoryName) }
    }

    /// Every category that has at least one bar-producing row in the
    /// current range. Drives the picker. Sourced from `rows` (rather than
    /// the full `colors` list) so `Income` / `Internal Transfer` — which
    /// the actor filters out before building rows — never appear.
    private var allCategoryNames: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for row in rows where !seen.contains(row.categoryName) {
            seen.insert(row.categoryName)
            ordered.append(row.categoryName)
        }
        return ordered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var currentKey: AnalysisKey {
        AnalysisKey(revision: signals.storeRevision, signature: filter.signature)
    }

    private var hoveredMonthStart: Date? {
        guard let target = hoveredDate else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
        let components = calendar.dateComponents([.year, .month], from: target)
        return calendar.date(from: components)
    }

    private var hoveredRows: [MonthlyCategoryRow] {
        guard let anchor = hoveredMonthStart else {
            return []
        }
        return visibleRows.filter { Calendar.current.isDate($0.month, equalTo: anchor, toGranularity: .month) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isComputing && rows.isEmpty {
                loading
            } else if rows.isEmpty {
                Text("No transactions in range.")
                    .foregroundStyle(.secondary)
            } else {
                kpis
                HStack {
                    Text("Monthly spend by category")
                        .font(.headline)
                    Spacer()
                    categoriesMenu
                }
                let (domain, range) = colorScale()
                Chart {
                        ForEach(visibleRows) { row in
                            BarMark(
                                x: .value("Month", row.month, unit: .month),
                                y: .value("Amount", row.amount)
                            )
                            .foregroundStyle(by: .value("Category", row.categoryName))
                        }

                        if let anchor = hoveredMonthStart, !hoveredRows.isEmpty {
                            RuleMark(x: .value("Selected", anchor, unit: .month))
                                .foregroundStyle(Color.secondary.opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .annotation(position: .top,
                                            alignment: .center,
                                            spacing: 10,
                                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                    monthTooltip(rows: hoveredRows, anchor: anchor)
                                }
                        }

                        if let anchor = selectedMonth {
                            RuleMark(x: .value("Drilldown", anchor, unit: .month))
                                .foregroundStyle(Color.accentColor.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                    .chartForegroundStyleScale(domain: domain, range: range)
                    .frame(height: 320)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        guard let plotFrame = proxy.plotFrame else {
                                            return
                                        }
                                        let origin = geo[plotFrame].origin
                                        let xPosition = location.x - origin.x
                                        hoveredDate = proxy.value(atX: xPosition)
                                    case .ended:
                                        hoveredDate = nil
                                    }
                                }
                                .onTapGesture(coordinateSpace: .local) { location in
                                    guard let plotFrame = proxy.plotFrame else {
                                        return
                                    }
                                    let origin = geo[plotFrame].origin
                                    let xPosition = location.x - origin.x
                                    guard let date: Date = proxy.value(atX: xPosition) else {
                                        return
                                    }
                                    let month = startOfMonth(date)
                                    if selectedMonth == month {
                                        selectedMonth = nil
                                        selectedTransactions = []
                                    } else {
                                        selectedMonth = month
                                        loadTransactions(for: month)
                                    }
                                }
                        }
                    }

                if let anchor = selectedMonth {
                    drilldownSection(anchor: anchor)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: currentKey) {
            if rows.isEmpty {
                isComputing = true
            }
            let result = await cache.monthlyCategoryBreakdown(in: filter.range)
            rows = result.rows
            colors = result.colors
            isComputing = false
            if let month = selectedMonth {
                loadTransactions(for: month)
            }
        }
        .onAppear {
            if let cached = cache.peekMonthlyCategory(for: filter.range) {
                rows = cached.rows
                colors = cached.colors
            }
        }
        .onChange(of: hiddenCategoryNames) { _, _ in
            if let month = selectedMonth {
                loadTransactions(for: month)
            }
        }
    }

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Calculating…").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var categoriesMenu: some View {
        let all = allCategoryNames
        let visibleCount = all.filter { !hiddenCategoryNames.contains($0) }.count
        Menu {
            Button("Show all") {
                hiddenCategoryNames.removeAll()
            }
            Button("Hide all") {
                hiddenCategoryNames = Set(all)
            }
            Divider()
            ForEach(all, id: \.self) { name in
                Button {
                    if hiddenCategoryNames.contains(name) {
                        hiddenCategoryNames.remove(name)
                    } else {
                        hiddenCategoryNames.insert(name)
                    }
                } label: {
                    if hiddenCategoryNames.contains(name) {
                        Text(name)
                    } else {
                        Label(name, systemImage: "checkmark")
                    }
                }
            }
        } label: {
            Label(
                visibleCount == all.count
                    ? "All categories"
                    : "\(visibleCount) of \(all.count) categories",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func colorScale() -> (domain: [String], range: [Color]) {
        var domain: [String] = []
        var range: [Color] = []
        for color in colors where !hiddenCategoryNames.contains(color.name) {
            domain.append(color.name)
            if color.colorIndex < 0 {
                range.append(.secondary)
            } else {
                range.append(AccountPalette.color(for: color.colorIndex))
            }
        }
        return (domain, range)
    }

    // MARK: - KPIs

    @ViewBuilder
    private var kpis: some View {
        let source = visibleRows
        let totalDecimal = source.reduce(into: Decimal(0)) { $0 += Decimal($1.amount) }
        let monthCount = Set(source.map { Calendar.current.startOfMonth($0.month) }).count
        let avgPerMonth: Decimal = monthCount > 0 ? totalDecimal / Decimal(monthCount) : 0

        let byCategory: [String: Decimal] = source.reduce(into: [:]) { acc, row in
            acc[row.categoryName, default: 0] += Decimal(row.amount)
        }
        let topCategory = byCategory
            .filter { $0.key != "Uncategorized" }
            .max { $0.value < $1.value }
        let topShare: Double = {
            guard let top = topCategory, totalDecimal != 0 else {
                return 0
            }
            return NSDecimalNumber(decimal: top.value).doubleValue /
                NSDecimalNumber(decimal: totalDecimal).doubleValue * 100
        }()

        let uncategorized: Decimal = byCategory["Uncategorized"] ?? 0
        let uncategorizedShare: Double = {
            guard totalDecimal != 0 else {
                return 0
            }
            return NSDecimalNumber(decimal: uncategorized).doubleValue /
                NSDecimalNumber(decimal: totalDecimal).doubleValue * 100
        }()

        HStack(spacing: 14) {
            KpiCard(
                label: "Total spend",
                value: MoneyFormatter.shortKr(totalDecimal),
                subtitle: "\(monthCount) month\(monthCount == 1 ? "" : "s")"
            )
            KpiCard(
                label: "Avg / month",
                value: MoneyFormatter.shortKr(avgPerMonth),
                subtitle: monthCount > 0 ? "per calendar month" : nil
            )
            if let top = topCategory {
                KpiCard(
                    label: "Top category",
                    value: top.key,
                    subtitle: "\(MoneyFormatter.shortKr(top.value)) · \(String(format: "%.0f%%", topShare))"
                )
            }
            if uncategorized > 0 {
                KpiCard(
                    label: "Uncategorized",
                    value: String(format: "%.0f%%", uncategorizedShare),
                    subtitle: MoneyFormatter.shortKr(uncategorized),
                    color: .orange
                )
            }
        }
    }

    // MARK: - Drilldown

    private func startOfMonth(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func loadTransactions(for monthStart: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
        guard let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            selectedTransactions = []
            return
        }

        // Intersect with the active analysis range so the table mirrors
        // exactly what made up the bar.
        var lower = monthStart
        var upper = monthEnd
        if let range = filter.range {
            lower = max(lower, range.lowerBound)
            upper = min(upper, range.upperBound)
        }
        guard lower < upper else {
            selectedTransactions = []
            return
        }

        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> {
                $0.transferStatusRaw == 0
                    && $0.amount < 0
                    && $0.bookingDate >= lower
                    && $0.bookingDate < upper
            },
            sortBy: [SortDescriptor(\.amount, order: .forward)]
        )
        var fetched = (try? modelContext.fetch(descriptor)) ?? []
        if !hiddenCategoryNames.isEmpty {
            fetched = fetched.filter { tx in
                let name = tx.category?.name ?? "Uncategorized"
                return !hiddenCategoryNames.contains(name)
            }
        }
        selectedTransactions = fetched
    }

    @ViewBuilder
    private func drilldownSection(anchor: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Transactions in \(DateFormatters.monthYear.string(from: anchor))")
                    .font(.headline)
                Text("\(selectedTransactions.count) rows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    selectedMonth = nil
                    selectedTransactions = []
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if selectedTransactions.isEmpty {
                VStack {
                    Text("No transactions in this month.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                Table(selectedTransactions) {
                    TableColumn("Date") { tx in
                        Text(DateFormatters.shortDay.string(from: tx.bookingDate))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 100, ideal: 110)

                    TableColumn("Text") { tx in
                        Text(tx.displayText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    TableColumn("Category") { tx in
                        CategoryChip(category: tx.category, subcategory: tx.subcategory)
                    }
                    .width(min: 140, ideal: 180)

                    TableColumn("Account") { tx in
                        if let account = tx.account {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(AccountPalette.color(for: account.colorIndex))
                                    .frame(width: 8, height: 8)
                                Text(account.displayName)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .width(min: 100, ideal: 130)

                    TableColumn("Amount") { tx in
                        Text(MoneyFormatter.signedString(tx.amount))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 90, ideal: 110)
                }
                .frame(minHeight: 220, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func monthTooltip(rows monthRows: [MonthlyCategoryRow], anchor: Date) -> some View {
        let sorted = monthRows.sorted { $0.amount > $1.amount }
        let total = sorted.reduce(into: Decimal(0)) { $0 += Decimal($1.amount) }
        let top = Array(sorted.prefix(3))

        TooltipCard(title: DateFormatters.monthYear.string(from: anchor)) {
            TooltipRow(label: "Total", value: MoneyFormatter.shortKr(total))
            if !top.isEmpty {
                Divider().frame(maxWidth: 160)
                ForEach(top) { row in
                    TooltipRow(
                        label: row.categoryName,
                        value: MoneyFormatter.shortKr(Decimal(row.amount))
                    )
                }
            }
        }
    }
}

// MARK: - Income vs. expenses

struct IncomeExpenseView: View {
    enum ChartKind: String, CaseIterable, Identifiable {
        case bars = "Bars"
        case lines = "Lines"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .bars: "chart.bar"
            case .lines: "chart.xyaxis.line"
            }
        }
    }

    @Environment(AnalyticsCache.self) private var cache
    @Environment(AppSignals.self) private var signals
    @Environment(AnalysisFilter.self) private var filter
    @Environment(\.modelContext) private var modelContext

    @State private var series: [IncomeExpensePoint] = []
    @State private var isComputing: Bool = false
    @State private var chartKind: ChartKind = .bars
    @State private var hoveredDate: Date?
    @State private var selectedMonth: Date?
    @State private var selectedTransactions: [Transaction] = []

    private var currentKey: AnalysisKey {
        AnalysisKey(revision: signals.storeRevision, signature: filter.signature)
    }

    private var hoveredPoint: IncomeExpensePoint? {
        guard let target = hoveredDate else {
            return nil
        }
        return series.min {
            abs($0.month.timeIntervalSince(target)) < abs($1.month.timeIntervalSince(target))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isComputing && series.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Calculating…").foregroundStyle(.secondary)
                }
            } else if series.isEmpty {
                Text("No transactions in range.")
                    .foregroundStyle(.secondary)
            } else {
                kpis
                HStack {
                    Text("Income vs. expenses")
                        .font(.headline)
                    Spacer()
                    Picker("Chart", selection: $chartKind) {
                        ForEach(ChartKind.allCases) { kind in
                            Label(kind.rawValue, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
                chart
                    .frame(height: 320)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        guard let plotFrame = proxy.plotFrame else {
                                            return
                                        }
                                        let origin = geo[plotFrame].origin
                                        let xPosition = location.x - origin.x
                                        hoveredDate = proxy.value(atX: xPosition)
                                    case .ended:
                                        hoveredDate = nil
                                    }
                                }
                                .onTapGesture(coordinateSpace: .local) { location in
                                    guard let plotFrame = proxy.plotFrame else {
                                        return
                                    }
                                    let origin = geo[plotFrame].origin
                                    let xPosition = location.x - origin.x
                                    guard let date: Date = proxy.value(atX: xPosition) else {
                                        return
                                    }
                                    let month = startOfMonth(date)
                                    if selectedMonth == month {
                                        selectedMonth = nil
                                        selectedTransactions = []
                                    } else {
                                        selectedMonth = month
                                        loadTransactions(for: month)
                                    }
                                }
                        }
                    }

                if let anchor = selectedMonth {
                    drilldownSection(anchor: anchor)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: currentKey) {
            if series.isEmpty {
                isComputing = true
            }
            series = await cache.incomeVsExpenses(in: filter.range)
            isComputing = false
            if let month = selectedMonth {
                loadTransactions(for: month)
            }
        }
        .onAppear {
            if let cached = cache.peekIncomeExpense(for: filter.range) {
                series = cached
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch chartKind {
        case .bars:
            Chart {
                ForEach(series) { point in
                    BarMark(
                        x: .value("Month", point.month, unit: .month),
                        y: .value("Income", point.income)
                    )
                    .foregroundStyle(by: .value("Kind", "Income"))
                    .position(by: .value("Kind", "Income"))

                    BarMark(
                        x: .value("Month", point.month, unit: .month),
                        y: .value("Expenses", point.expenses)
                    )
                    .foregroundStyle(by: .value("Kind", "Expenses"))
                    .position(by: .value("Kind", "Expenses"))
                }

                hoverLayer
                selectionLayer
            }
            .chartForegroundStyleScale([
                "Income": Color.green,
                "Expenses": Color.red
            ])
        case .lines:
            Chart {
                ForEach(series) { point in
                    LineMark(
                        x: .value("Month", point.month, unit: .month),
                        y: .value("Amount", point.income),
                        series: .value("Kind", "Income")
                    )
                    .foregroundStyle(by: .value("Kind", "Income"))
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Month", point.month, unit: .month),
                        y: .value("Amount", point.expenses),
                        series: .value("Kind", "Expenses")
                    )
                    .foregroundStyle(by: .value("Kind", "Expenses"))
                    .interpolationMethod(.monotone)
                }

                hoverLayer
                selectionLayer
            }
            .chartForegroundStyleScale([
                "Income": Color.green,
                "Expenses": Color.red
            ])
        }
    }

    @ChartContentBuilder
    private var selectionLayer: some ChartContent {
        if let anchor = selectedMonth {
            RuleMark(x: .value("Drilldown", anchor, unit: .month))
                .foregroundStyle(Color.accentColor.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
    }

    @ChartContentBuilder
    private var hoverLayer: some ChartContent {
        if let point = hoveredPoint {
            RuleMark(x: .value("Selected", point.month))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top,
                            alignment: .center,
                            spacing: 10,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    incomeExpenseTooltip(for: point)
                }
        }
    }

    // MARK: KPIs

    @ViewBuilder
    private var kpis: some View {
        let totalIncome = series.reduce(0.0) { $0 + $1.income }
        let totalExpenses = series.reduce(0.0) { $0 + $1.expenses }
        let net = totalIncome - totalExpenses
        let savingsRate: Double = totalIncome > 0 ? (net / totalIncome) * 100 : 0

        HStack(spacing: 14) {
            KpiCard(
                label: "Income",
                value: MoneyFormatter.shortKr(Decimal(totalIncome)),
                subtitle: "\(series.count) month\(series.count == 1 ? "" : "s")",
                color: .green
            )
            KpiCard(
                label: "Expenses",
                value: MoneyFormatter.shortKr(Decimal(totalExpenses)),
                subtitle: "in range",
                color: .red
            )
            KpiCard(
                label: "Net",
                value: "\(net >= 0 ? "+" : "")\(MoneyFormatter.shortKr(Decimal(net)))",
                subtitle: net >= 0 ? "saved" : "overspent",
                color: net >= 0 ? .green : .red
            )
            KpiCard(
                label: "Savings rate",
                value: totalIncome > 0 ? String(format: "%.0f%%", savingsRate) : "—",
                subtitle: totalIncome > 0 ? "of income" : "no income",
                color: savingsRate >= 0 ? .green : .red
            )
        }
    }

    @ViewBuilder
    private func incomeExpenseTooltip(for point: IncomeExpensePoint) -> some View {
        let net = point.income - point.expenses
        TooltipCard(title: DateFormatters.monthYear.string(from: point.month)) {
            TooltipRow(label: "Income", value: MoneyFormatter.shortKr(Decimal(point.income)), color: .green)
            TooltipRow(label: "Expenses", value: MoneyFormatter.shortKr(Decimal(point.expenses)), color: .red)
            TooltipRow(
                label: "Net",
                value: "\(net >= 0 ? "+" : "")\(MoneyFormatter.shortKr(Decimal(net)))",
                color: net >= 0 ? .green : .red
            )
        }
    }

    // MARK: - Drilldown

    private func startOfMonth(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func loadTransactions(for monthStart: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
        guard let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            selectedTransactions = []
            return
        }

        // Intersect with the active analysis range so the table mirrors
        // exactly what made up the bars.
        var lower = monthStart
        var upper = monthEnd
        if let range = filter.range {
            lower = max(lower, range.lowerBound)
            upper = min(upper, range.upperBound)
        }
        guard lower < upper else {
            selectedTransactions = []
            return
        }

        // Both income (amount > 0) and expenses (amount < 0), but never
        // internal transfers — same predicate the actor uses.
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> {
                $0.transferStatusRaw == 0
                    && $0.bookingDate >= lower
                    && $0.bookingDate < upper
            },
            sortBy: [SortDescriptor(\.amount, order: .reverse)]
        )
        selectedTransactions = (try? modelContext.fetch(descriptor)) ?? []
    }

    @ViewBuilder
    private func drilldownSection(anchor: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Transactions in \(DateFormatters.monthYear.string(from: anchor))")
                    .font(.headline)
                Text("\(selectedTransactions.count) rows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    selectedMonth = nil
                    selectedTransactions = []
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if selectedTransactions.isEmpty {
                VStack {
                    Text("No transactions in this month.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                Table(selectedTransactions) {
                    TableColumn("Date") { tx in
                        Text(DateFormatters.shortDay.string(from: tx.bookingDate))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 100, ideal: 110)

                    TableColumn("Text") { tx in
                        Text(tx.displayText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    TableColumn("Category") { tx in
                        CategoryChip(category: tx.category, subcategory: tx.subcategory)
                    }
                    .width(min: 140, ideal: 180)

                    TableColumn("Account") { tx in
                        if let account = tx.account {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(AccountPalette.color(for: account.colorIndex))
                                    .frame(width: 8, height: 8)
                                Text(account.displayName)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .width(min: 100, ideal: 130)

                    TableColumn("Amount") { tx in
                        Text(MoneyFormatter.signedString(tx.amount))
                            .monospacedDigit()
                            .foregroundStyle(tx.amount >= 0 ? Color.green : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 90, ideal: 110)
                }
                .frame(minHeight: 220, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Top merchants

struct TopMerchantsView: View {
    @Environment(AnalyticsCache.self) private var cache
    @Environment(AppSignals.self) private var signals
    @Environment(AnalysisFilter.self) private var filter

    @State private var rows: [MerchantRow] = []
    @State private var isComputing: Bool = false

    private var currentKey: AnalysisKey {
        AnalysisKey(revision: signals.storeRevision, signature: filter.signature)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Top merchants")
                    .font(.headline)
                if isComputing && rows.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Calculating…").foregroundStyle(.secondary)
                    }
                } else if rows.isEmpty {
                    Text("No transactions in range.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            HStack {
                                Text("\(index + 1).")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .trailing)
                                    .monospacedDigit()
                                Text(row.merchant)
                                Spacer()
                                Text("\(row.count) tx")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                Text(MoneyFormatter.shortKr(row.totalSpent))
                                    .monospacedDigit()
                                    .frame(width: 140, alignment: .trailing)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            Divider()
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                    )
                }
            }
            .padding(24)
        }
        .task(id: currentKey) {
            if rows.isEmpty {
                isComputing = true
            }
            rows = await cache.topMerchants(limit: 25, in: filter.range)
            isComputing = false
        }
        .onAppear {
            if let cached = cache.peekTopMerchants(for: filter.range) {
                rows = cached
            }
        }
    }
}

// MARK: - Category totals

/// Aggregates `MonthlyCategoryRow`s across all months into a flat per-category
/// total. Reuses the existing `monthlyCategoryBreakdown` cache — no new actor
/// fetch needed.
private struct CategoryTotal: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let colorIndex: Int
    let amount: Double
}

struct CategoryTotalsView: View {
    enum SortMode: String, CaseIterable, Identifiable {
        case amountDescending = "Amount ↓"
        case amountAscending = "Amount ↑"
        case alphabetical = "A → Z"
        var id: String { rawValue }
    }

    @Environment(AnalyticsCache.self) private var cache
    @Environment(AppSignals.self) private var signals
    @Environment(AnalysisFilter.self) private var filter

    @State private var rawRows: [MonthlyCategoryRow] = []
    @State private var colors: [CategoryColor] = []
    @State private var isComputing: Bool = false
    @State private var sortMode: SortMode = .amountDescending
    /// Names of categories the user has hidden from the chart and table.
    /// Stored as the negative set so newly seeded categories show up by
    /// default without needing to touch this state.
    @State private var hiddenCategoryNames: Set<String> = []

    private var currentKey: AnalysisKey {
        AnalysisKey(revision: signals.storeRevision, signature: filter.signature)
    }

    /// Categories that are never spend, so they're hidden from this view
    /// entirely — not even shown in the picker. Income is positive amounts
    /// only; Internal Transfer rows are already excluded from the actor's
    /// fetch via the transfer-status filter, so the category itself only
    /// ever appears here as a zero-row artefact.
    private static let excludedCategoryNames: Set<String> = [
        "Income",
        "Internal Transfer"
    ]

    /// Every category known to the store — drives the picker and ensures
    /// categories with zero spend in the active date range still show up.
    /// Sourced from the cached `colors` list which the actor builds from a
    /// full `Category` fetch (plus a synthetic "Uncategorized" entry).
    private var allCategoryNames: [String] {
        colors
            .map(\.name)
            .filter { !Self.excludedCategoryNames.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var totals: [CategoryTotal] {
        var byName: [String: Double] = [:]
        for row in rawRows
        where !hiddenCategoryNames.contains(row.categoryName)
            && !Self.excludedCategoryNames.contains(row.categoryName) {
            byName[row.categoryName, default: 0] += row.amount
        }
        // Seed any visible categories that had no transactions in the
        // range so the chart/table still shows them at zero.
        for c in colors
        where !hiddenCategoryNames.contains(c.name)
            && !Self.excludedCategoryNames.contains(c.name) {
            if byName[c.name] == nil {
                byName[c.name] = 0
            }
        }
        var colorByName: [String: Int] = [:]
        for c in colors {
            colorByName[c.name] = c.colorIndex
        }
        let unsorted = byName.map { name, amount in
            CategoryTotal(
                name: name,
                colorIndex: colorByName[name] ?? -1,
                amount: amount
            )
        }
        switch sortMode {
        case .amountDescending:
            return unsorted.sorted { $0.amount > $1.amount }
        case .amountAscending:
            return unsorted.sorted { $0.amount < $1.amount }
        case .alphabetical:
            return unsorted.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private var grandTotal: Double {
        rawRows
            .filter {
                !hiddenCategoryNames.contains($0.categoryName)
                    && !Self.excludedCategoryNames.contains($0.categoryName)
            }
            .reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isComputing && rawRows.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Calculating…").foregroundStyle(.secondary)
                    }
                } else if rawRows.isEmpty {
                    Text("No transactions in range.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Spend by category")
                            .font(.headline)
                        Spacer()
                        categoriesMenu
                        Picker("Sort", selection: $sortMode) {
                            ForEach(SortMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 280)
                    }

                    chart
                        .frame(height: chartHeight)

                    Divider()

                    table
                        .frame(minHeight: CGFloat(max(totals.count, 1)) * 28 + 60)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: currentKey) {
            if rawRows.isEmpty {
                isComputing = true
            }
            let result = await cache.monthlyCategoryBreakdown(in: filter.range)
            rawRows = result.rows
            colors = result.colors
            isComputing = false
        }
        .onAppear {
            if let cached = cache.peekMonthlyCategory(for: filter.range) {
                rawRows = cached.rows
                colors = cached.colors
            }
        }
    }

    /// Target chart height: ~38pt per visible bar plus axis/padding,
    /// clamped so it stays usable for both small (1–2) and large (20+)
    /// category counts.
    private var chartHeight: CGFloat {
        let perBar: CGFloat = 38
        let padding: CGFloat = 60
        let count = max(totals.count, 1)
        return min(max(CGFloat(count) * perBar + padding, 260), 800)
    }

    @ViewBuilder
    private var chart: some View {
        let sorted = totals
        let domain = sorted.map(\.name)
        let range = sorted.map { ct -> Color in
            ct.colorIndex < 0 ? .secondary : AccountPalette.color(for: ct.colorIndex)
        }
        Chart {
            ForEach(sorted) { item in
                BarMark(
                    x: .value("Amount", item.amount),
                    y: .value("Category", item.name)
                )
                .foregroundStyle(by: .value("Category", item.name))
            }
        }
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartLegend(.hidden)
    }

    @ViewBuilder
    private var categoriesMenu: some View {
        let all = allCategoryNames
        let visibleCount = all.filter { !hiddenCategoryNames.contains($0) }.count
        Menu {
            Button("Show all") {
                hiddenCategoryNames.removeAll()
            }
            Button("Hide all") {
                hiddenCategoryNames = Set(all)
            }
            Divider()
            ForEach(all, id: \.self) { name in
                Button {
                    if hiddenCategoryNames.contains(name) {
                        hiddenCategoryNames.remove(name)
                    } else {
                        hiddenCategoryNames.insert(name)
                    }
                } label: {
                    if hiddenCategoryNames.contains(name) {
                        Text(name)
                    } else {
                        Label(name, systemImage: "checkmark")
                    }
                }
            }
        } label: {
            Label(
                visibleCount == all.count
                    ? "All categories"
                    : "\(visibleCount) of \(all.count) categories",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var table: some View {
        Table(totals) {
            TableColumn("Category") { item in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(item.colorIndex < 0 ? Color.secondary : AccountPalette.color(for: item.colorIndex))
                        .frame(width: 10, height: 10)
                    Text(item.name)
                }
            }

            TableColumn("Amount") { item in
                Text(MoneyFormatter.shortKr(Decimal(item.amount)))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 110, ideal: 140)

            TableColumn("Share") { item in
                let share = grandTotal > 0 ? item.amount / grandTotal * 100 : 0
                Text(String(format: "%.1f%%", share))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
        }
    }
}
