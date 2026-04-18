//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData
import Charts

// MARK: - View

struct NetWorthView: View {
    @Environment(AnalyticsCache.self) private var cache
    @Environment(AppSignals.self) private var signals
    @Environment(AnalysisFilter.self) private var filter

    @State private var series: [NetWorthMonth] = []
    @State private var isComputing: Bool = false
    @State private var hoveredDate: Date?

    private struct TaskKey: Hashable {
        let revision: Int
        let signature: String
    }

    private var currentKey: TaskKey {
        TaskKey(revision: signals.storeRevision, signature: filter.signature)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if series.isEmpty && isComputing {
                    loadingState
                } else if series.isEmpty {
                    emptyState
                } else {
                    kpis(series)
                    chart(series)
                    table(series)
                }
            }
            .padding(24)
        }
        .task(id: currentKey) {
            if series.isEmpty {
                isComputing = true
            }
            series = await cache.netWorthSeries(in: filter.range)
            isComputing = false
        }
        .onAppear {
            if let cached = cache.peekNetWorth(for: filter.range) {
                series = cached
            }
        }
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Calculating net worth…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 80)
    }

    private var emptyState: some View {
        Text("No data.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 80)
    }

    // MARK: KPIs

    @ViewBuilder
    private func kpis(_ series: [NetWorthMonth]) -> some View {
        let latest = series.last
        let previous = series.dropLast().last
        let twelveBack = series.count >= 13 ? series[series.count - 13] : series.first

        let latestTotal = latest?.totalBalance ?? 0
        let monthlyDelta: Decimal = (latest?.totalBalance ?? 0) - (previous?.totalBalance ?? 0)
        let monthlyPct: Double = {
            guard let prev = previous?.totalBalance, prev != 0 else {
                return 0
            }
            return (NSDecimalNumber(decimal: monthlyDelta).doubleValue / NSDecimalNumber(decimal: prev).doubleValue) * 100
        }()
        let yearDelta: Decimal = (latest?.totalBalance ?? 0) - (twelveBack?.totalBalance ?? 0)
        let avgDelta: Decimal = {
            guard series.count > 1 else {
                return 0
            }
            var sum = Decimal(0)
            for i in 1..<series.count {
                sum += series[i].totalBalance - series[i - 1].totalBalance
            }
            return sum / Decimal(series.count - 1)
        }()

        HStack(spacing: 14) {
            KpiCard(
                label: "On the 25th · \(latest.map { DateFormatters.monthYear.string(from: $0.monthDate) } ?? "—")",
                value: MoneyFormatter.shortKr(latestTotal),
                subtitle: monthlyDelta == 0 ? "—" :
                    "\(monthlyDelta >= 0 ? "▲" : "▼") \(MoneyFormatter.shortKr(abs(monthlyDelta))) · \(String(format: "%+.2f%%", monthlyPct))",
                color: monthlyDelta >= 0 ? .green : .red
            )
            KpiCard(
                label: "12-month change",
                value: "\(yearDelta >= 0 ? "+" : "")\(MoneyFormatter.shortKr(yearDelta))",
                subtitle: "vs. one year ago",
                color: yearDelta >= 0 ? .green : .red
            )
            KpiCard(
                label: "Avg. monthly Δ",
                value: "\(avgDelta >= 0 ? "+" : "")\(MoneyFormatter.shortKr(avgDelta))",
                subtitle: "over \(max(series.count - 1, 0)) months"
            )
        }
    }

    // MARK: Chart

    @ViewBuilder
    private func chart(_ series: [NetWorthMonth]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Net worth on the 25th")
                .font(.headline)
            Text("Sum of running balance across all accounts, sampled at each account's latest booking on or before the 25th.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(series) { point in
                    AreaMark(
                        x: .value("Month", point.monthDate),
                        y: .value("Balance", NSDecimalNumber(decimal: point.totalBalance).doubleValue)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value("Month", point.monthDate),
                        y: .value("Balance", NSDecimalNumber(decimal: point.totalBalance).doubleValue)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(
                        x: .value("Month", point.monthDate),
                        y: .value("Balance", NSDecimalNumber(decimal: point.totalBalance).doubleValue)
                    )
                    .foregroundStyle(.white)
                    .symbolSize(32)
                    .symbol(Circle().strokeBorder(lineWidth: 2))
                }

                if let hovered = hoveredPoint {
                    RuleMark(x: .value("Selected", hovered.monthDate))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top,
                                    alignment: .center,
                                    spacing: 10,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            netWorthTooltip(for: hovered)
                        }

                    PointMark(
                        x: .value("Month", hovered.monthDate),
                        y: .value("Balance", NSDecimalNumber(decimal: hovered.totalBalance).doubleValue)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(140)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartXSelection(value: $hoveredDate)
            .frame(height: 260)
            .padding(.top, 6)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: Hover

    private var hoveredPoint: NetWorthMonth? {
        guard let target = hoveredDate else {
            return nil
        }
        return series.min {
            abs($0.monthDate.timeIntervalSince(target)) < abs($1.monthDate.timeIntervalSince(target))
        }
    }

    private func previousPoint(of point: NetWorthMonth) -> NetWorthMonth? {
        guard let index = series.firstIndex(where: { $0.id == point.id }), index > 0 else {
            return nil
        }
        return series[index - 1]
    }

    @ViewBuilder
    private func netWorthTooltip(for point: NetWorthMonth) -> some View {
        let prev = previousPoint(of: point)
        let delta: Decimal = point.totalBalance - (prev?.totalBalance ?? point.totalBalance)
        let pct: Double = {
            guard let p = prev?.totalBalance, p != 0 else {
                return 0
            }
            return (NSDecimalNumber(decimal: delta).doubleValue / NSDecimalNumber(decimal: p).doubleValue) * 100
        }()

        TooltipCard(title: DateFormatters.monthYear.string(from: point.monthDate)) {
            TooltipRow(label: "Total", value: MoneyFormatter.shortKr(point.totalBalance))
            if prev != nil {
                TooltipRow(
                    label: "Δ",
                    value: "\(delta >= 0 ? "+" : "")\(MoneyFormatter.shortKr(delta))",
                    color: delta >= 0 ? .green : .red
                )
                TooltipRow(
                    label: "Δ%",
                    value: String(format: "%+.2f%%", pct),
                    color: delta >= 0 ? .green : .red
                )
            }
        }
    }

    // MARK: Table

    @ViewBuilder
    private func table(_ series: [NetWorthMonth]) -> some View {
        let reversed = Array(series.reversed())
        VStack(alignment: .leading, spacing: 6) {
            Text("Month over month")
                .font(.headline)
            VStack(spacing: 0) {
                HStack {
                    Text("Month (25th)").frame(width: 110, alignment: .leading)
                    Spacer()
                    Text("Total").frame(width: 120, alignment: .trailing)
                    Text("Δ").frame(width: 110, alignment: .trailing)
                    Text("Δ %").frame(width: 80, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

                ForEach(Array(reversed.enumerated()), id: \.element.id) { index, point in
                    let prev: Decimal = {
                        let realIndex = series.count - 1 - index
                        return realIndex > 0 ? series[realIndex - 1].totalBalance : point.totalBalance
                    }()
                    let delta = point.totalBalance - prev
                    let pct: Double = prev == 0 ? 0 :
                        (NSDecimalNumber(decimal: delta).doubleValue / NSDecimalNumber(decimal: prev).doubleValue) * 100

                    HStack {
                        Text(DateFormatters.monthYear.string(from: point.monthDate))
                            .frame(width: 110, alignment: .leading)
                        Spacer()
                        Text(MoneyFormatter.shortKr(point.totalBalance))
                            .monospacedDigit()
                            .frame(width: 120, alignment: .trailing)
                        Text("\(delta >= 0 ? "+" : "")\(MoneyFormatter.shortKr(delta))")
                            .monospacedDigit()
                            .foregroundStyle(delta >= 0 ? Color.green : Color.red)
                            .frame(width: 110, alignment: .trailing)
                        Text(String(format: "%+.2f%%", pct))
                            .monospacedDigit()
                            .foregroundStyle(delta >= 0 ? Color.green : Color.red)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(index == 0 ? Color.accentColor.opacity(0.08) : Color.clear)
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

}
