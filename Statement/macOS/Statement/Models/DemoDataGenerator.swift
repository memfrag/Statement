//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation

/// Which of the demo profile's two accounts an event posts to.
enum DemoAccountKind {
    case checking
    case savings
}

/// A single planned transaction. Balances are applied by the caller so
/// the generator itself is stateless and easy to reason about.
struct DemoEvent {
    var date: Date
    var account: DemoAccountKind
    var text: String
    var amount: Decimal
}

/// Deterministic 24-month transaction stream for the Demo profile.
/// All amounts are SEK. Texts are mixed-case so the XLSX-text-cleanup
/// migration in `SeedData` leaves them untouched.
enum DemoDataGenerator {

    // Normalized forms (no whitespace) of the account numbers used by
    // `DemoData`. These must appear as substrings of transfer-row texts
    // so `TransferPairingService` pairs them automatically.
    static let checkingNumberNormalized = "5123-12345678901"
    static let savingsNumberNormalized = "5123-12987654321"

    static func generate(monthsBack: Int, seed: UInt64) -> [DemoEvent] {
        var rng = SeededRandom(seed: seed)
        var events: [DemoEvent] = []

        let calendar = Calendar(identifier: .gregorian)
        guard let thisMonthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: Date())
        ) else {
            return []
        }

        let startMonth = calendar.date(
            byAdding: .month, value: -(monthsBack - 1), to: thisMonthStart
        ) ?? thisMonthStart

        for monthOffset in 0..<monthsBack {
            guard let monthStart = calendar.date(
                byAdding: .month, value: monthOffset, to: startMonth
            ) else {
                continue
            }

            emitSalary(on: monthStart, cal: calendar, into: &events)
            emitRent(on: monthStart, cal: calendar, into: &events)
            emitSubscriptions(on: monthStart, cal: calendar, into: &events)
            emitGroceries(on: monthStart, cal: calendar, rng: &rng, into: &events)
            emitDining(on: monthStart, cal: calendar, rng: &rng, into: &events)
            emitTransfers(on: monthStart, cal: calendar, rng: &rng, into: &events)
            emitOneOffs(on: monthStart, cal: calendar, rng: &rng, into: &events)
        }

        events.sort { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date < rhs.date
            }
            return lhs.amount < rhs.amount
        }
        return events
    }

    // MARK: - Category emitters

    private static func emitSalary(
        on monthStart: Date,
        cal: Calendar,
        into events: inout [DemoEvent]
    ) {
        guard let date = cal.date(byAdding: .day, value: 24, to: monthStart) else {
            return
        }
        events.append(DemoEvent(
            date: date,
            account: .checking,
            text: "Lön Acme AB",
            amount: 35_000
        ))
    }

    private static func emitRent(
        on monthStart: Date,
        cal: Calendar,
        into events: inout [DemoEvent]
    ) {
        guard let date = cal.date(byAdding: .day, value: 27, to: monthStart) else {
            return
        }
        events.append(DemoEvent(
            date: date,
            account: .checking,
            text: "Hyra Lägenhet Stockholmshem",
            amount: -12_500
        ))
    }

    private static func emitSubscriptions(
        on monthStart: Date,
        cal: Calendar,
        into events: inout [DemoEvent]
    ) {
        let specs: [(day: Int, text: String, amount: Decimal)] = [
            (0, "SL Access Månadsbiljett", -970),
            (2, "Spotify AB", -119),
            (9, "Netflix Stockholm", -139)
        ]
        for spec in specs {
            if let date = cal.date(byAdding: .day, value: spec.day, to: monthStart) {
                events.append(DemoEvent(
                    date: date,
                    account: .checking,
                    text: spec.text,
                    amount: spec.amount
                ))
            }
        }
    }

    private static func emitGroceries(
        on monthStart: Date,
        cal: Calendar,
        rng: inout SeededRandom,
        into events: inout [DemoEvent]
    ) {
        let vendors = [
            "ICA Supermarket Södermalm",
            "ICA Kvantum Kungsholmen",
            "Coop Konsum Vasastan",
            "Willys Hornstull",
            "Hemköp Östermalm"
        ]
        let count = 8 + Int(rng.next() % 5) // 8...12
        for _ in 0..<count {
            let day = Int(rng.next() % 28)
            guard let date = cal.date(byAdding: .day, value: day, to: monthStart) else {
                continue
            }
            let vendor = vendors[Int(rng.next() % UInt64(vendors.count))]
            let amount = -Decimal(150 + Int(rng.next() % 751)) // -150..-900
            events.append(DemoEvent(
                date: date,
                account: .checking,
                text: vendor,
                amount: amount
            ))
        }
    }

    private static func emitDining(
        on monthStart: Date,
        cal: Calendar,
        rng: inout SeededRandom,
        into events: inout [DemoEvent]
    ) {
        let vendors = [
            "Restaurang Pelikan",
            "Restaurang Pizza Hatt",
            "Café Pascal",
            "Café Saturnus",
            "Urban Deli Restaurang"
        ]
        let count = 3 + Int(rng.next() % 4) // 3...6
        for _ in 0..<count {
            let day = Int(rng.next() % 28)
            guard let date = cal.date(byAdding: .day, value: day, to: monthStart) else {
                continue
            }
            let vendor = vendors[Int(rng.next() % UInt64(vendors.count))]
            let amount = -Decimal(80 + Int(rng.next() % 371)) // -80..-450
            events.append(DemoEvent(
                date: date,
                account: .checking,
                text: vendor,
                amount: amount
            ))
        }
    }

    private static func emitTransfers(
        on monthStart: Date,
        cal: Calendar,
        rng: inout SeededRandom,
        into events: inout [DemoEvent]
    ) {
        let count = 2 + Int(rng.next() % 2) // 2 or 3
        for _ in 0..<count {
            let day = Int(rng.next() % 28)
            guard let date = cal.date(byAdding: .day, value: day, to: monthStart) else {
                continue
            }
            // Model real saving behaviour: ~85% of transfers move money
            // into Savings, ~15% go the other way for occasional
            // withdrawals. 50/50 drains Savings over time because there's
            // no other income channel into that account.
            let direction = (rng.next() % 100) < 85 ? 0 : 1
            let amount = Decimal(1_000 + Int(rng.next() % 9_001)) // 1000..10000
            if direction == 0 {
                events.append(DemoEvent(
                    date: date,
                    account: .checking,
                    text: "Överföring till \(savingsNumberNormalized) Sparkonto",
                    amount: -amount
                ))
                events.append(DemoEvent(
                    date: date,
                    account: .savings,
                    text: "Överföring från \(checkingNumberNormalized) Lönekonto",
                    amount: amount
                ))
            } else {
                events.append(DemoEvent(
                    date: date,
                    account: .savings,
                    text: "Överföring till \(checkingNumberNormalized) Lönekonto",
                    amount: -amount
                ))
                events.append(DemoEvent(
                    date: date,
                    account: .checking,
                    text: "Överföring från \(savingsNumberNormalized) Sparkonto",
                    amount: amount
                ))
            }
        }
    }

    private static func emitOneOffs(
        on monthStart: Date,
        cal: Calendar,
        rng: inout SeededRandom,
        into events: inout [DemoEvent]
    ) {
        let specs: [(text: String, minAmount: Int, maxAmount: Int)] = [
            ("Apotek Hjärtat", 80, 800),
            ("SATS Sverige", 399, 599),
            ("Systembolaget Götgatan", 150, 900),
            ("Elgiganten Kungens Kurva", 800, 5_000),
            ("SJ Biljett Stockholm-Göteborg", 500, 1_200)
        ]
        let count = Int(rng.next() % 3) // 0...2
        for _ in 0..<count {
            let day = Int(rng.next() % 28)
            guard let date = cal.date(byAdding: .day, value: day, to: monthStart) else {
                continue
            }
            let spec = specs[Int(rng.next() % UInt64(specs.count))]
            let range = spec.maxAmount - spec.minAmount
            let amount = -Decimal(spec.minAmount + Int(rng.next() % UInt64(range)))
            events.append(DemoEvent(
                date: date,
                account: .checking,
                text: spec.text,
                amount: amount
            ))
        }
    }
}

// MARK: - Deterministic RNG

/// Tiny xorshift64 generator. Seeded from a fixed constant so the demo
/// dataset is bit-for-bit identical every time.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEADBEEF : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
