//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftUI

/// Date-range filter applied across all views in the Analysis pane.
///
/// Held as a long-lived `@Observable` in `RootView` so the selection
/// survives tab switches inside the Analysis section. Each analysis
/// sub-view reads `range` and passes it to the `AnalyticsCache`.
@MainActor
@Observable
final class AnalysisFilter {

    enum Preset: String, CaseIterable, Identifiable {
        case allTime = "All time"
        case thisYear = "This year"
        case last12Months = "Last 12 months"
        case last3Months = "Last 3 months"
        case thisMonth = "This month"
        case custom = "Custom"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .allTime: "infinity"
            case .thisYear: "calendar"
            case .last12Months: "12.circle"
            case .last3Months: "3.circle"
            case .thisMonth: "calendar.circle"
            case .custom: "slider.horizontal.3"
            }
        }
    }

    var preset: Preset = .allTime
    var customFrom: Date
    var customTo: Date

    init() {
        let now = Date()
        let cal = Calendar.current
        self.customFrom = cal.date(byAdding: .month, value: -1, to: now) ?? now
        self.customTo = now
    }

    /// The effective date range, or `nil` to mean "all time".
    var range: ClosedRange<Date>? {
        let calendar = Calendar.current
        let now = Date()
        switch preset {
        case .allTime:
            return nil
        case .thisYear:
            let startOfYear = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? now
            return startOfYear...now
        case .last12Months:
            let from = calendar.date(byAdding: .month, value: -12, to: now) ?? now
            return from...now
        case .last3Months:
            let from = calendar.date(byAdding: .month, value: -3, to: now) ?? now
            return from...now
        case .thisMonth:
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            return startOfMonth...now
        case .custom:
            let lower = min(customFrom, customTo)
            let upper = max(customFrom, customTo)
            return lower...upper
        }
    }

    /// Stable string signature used by `AnalyticsCache` to key cached results.
    /// Rounds to whole seconds so minor drift doesn't invalidate the cache.
    var signature: String {
        guard let range else {
            return "all"
        }
        let lo = Int(range.lowerBound.timeIntervalSince1970)
        let hi = Int(range.upperBound.timeIntervalSince1970)
        return "\(lo)-\(hi)"
    }
}
