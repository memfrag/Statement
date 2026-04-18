//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation

enum MoneyFormatter {
    private nonisolated static let base: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{00A0}" // non-breaking space for Swedish style (1 234,56)
        f.decimalSeparator = ","
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    static func string(_ amount: Decimal) -> String {
        base.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }

    static func signedString(_ amount: Decimal) -> String {
        let abs = abs(amount)
        let prefix = amount < 0 ? "−" : (amount > 0 ? "+" : "")
        return prefix + (base.string(from: abs as NSDecimalNumber) ?? "")
    }

    static func shortKr(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{00A0}"
        f.decimalSeparator = ","
        f.maximumFractionDigits = 0
        let s = f.string(from: amount as NSDecimalNumber) ?? "\(amount)"
        return "\(s) kr"
    }
}

extension Calendar {
    /// Returns the first instant of the month containing `date`.
    func startOfMonth(_ date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? date
    }
}

enum DateFormatters {
    nonisolated static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "sv_SE")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    nonisolated static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "sv_SE")
        f.dateFormat = "LLL yyyy"
        return f
    }()

    nonisolated static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Europe/Stockholm")
        return f
    }()

    nonisolated static let exportStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Europe/Stockholm")
        return f
    }()
}
