//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI

enum AnalysisTab: String, CaseIterable, Identifiable {
    case netWorth = "Net worth · 25th"
    case monthlyCategory = "Monthly by category"
    case categoryTotals = "Category totals"
    case categoryShare = "Category share"
    case incomeExpense = "Income vs. expenses"
    case spendingVelocity = "Spending velocity"
    case yearOverYear = "Year over year"
    case spendingHeatmap = "Spending heatmap"
    case recurring = "Recurring"
    case topMerchants = "Top merchants"
    case largestTransactions = "Largest transactions"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .netWorth: "chart.line.uptrend.xyaxis"
        case .monthlyCategory: "chart.bar"
        case .categoryTotals: "chart.bar.doc.horizontal"
        case .categoryShare: "chart.bar.fill"
        case .incomeExpense: "arrow.up.arrow.down"
        case .spendingVelocity: "speedometer"
        case .yearOverYear: "calendar.badge.clock"
        case .spendingHeatmap: "square.grid.3x3.fill"
        case .recurring: "repeat"
        case .topMerchants: "list.number"
        case .largestTransactions: "arrow.up.right"
        }
    }
}

struct AnalysisRootView: View {
    @Environment(AnalysisFilter.self) private var filter
    @State private var tab: AnalysisTab = .netWorth

    var body: some View {
        @Bindable var filter = filter
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("View", selection: $tab) {
                    ForEach(AnalysisTab.allCases) { t in
                        Label(t.rawValue, systemImage: t.systemImage).tag(t)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()

                Spacer()

                Menu {
                    ForEach(AnalysisFilter.Preset.allCases) { preset in
                        Button {
                            filter.preset = preset
                        } label: {
                            Label(preset.rawValue, systemImage: preset.systemImage)
                        }
                    }
                } label: {
                    Label(filter.preset.rawValue, systemImage: filter.preset.systemImage)
                        .frame(minWidth: 140, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if filter.preset == .custom {
                    DatePicker("From", selection: $filter.customFrom, displayedComponents: .date)
                        .labelsHidden()
                    Text("–").foregroundStyle(.secondary)
                    DatePicker("To", selection: $filter.customTo, displayedComponents: .date)
                        .labelsHidden()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()

            switch tab {
            case .netWorth:            NetWorthView()
            case .monthlyCategory:     MonthlyCategoryView()
            case .categoryTotals:      CategoryTotalsView()
            case .categoryShare:       CategoryShareView()
            case .incomeExpense:       IncomeExpenseView()
            case .spendingVelocity:    SpendingVelocityView()
            case .yearOverYear:        YearOverYearView()
            case .spendingHeatmap:     SpendingHeatmapView()
            case .recurring:           RecurringTransactionsView()
            case .topMerchants:        TopMerchantsView()
            case .largestTransactions: LargestTransactionsView()
            }
        }
        .navigationTitle("Analysis")
    }
}
