//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData
import AppKit

// MARK: - Filter

enum TransactionFilterScope: Equatable {
    case all
    case account(Account)
}

struct TransactionsView: View {
    let filter: TransactionFilterScope

    @Environment(\.modelContext) private var context
    @Environment(AppSignals.self) private var signals
    @Query(sort: [SortDescriptor(\Transaction.bookingDate, order: .reverse)])
    private var transactions: [Transaction]
    @Query(sort: [SortDescriptor(\Category.sortIndex)])
    private var categories: [Category]

    @State private var searchText: String = ""
    /// Debounced version of `searchText`. The filter uses this so that
    /// rapid typing / erasing doesn't re-run the full-table filter on
    /// every keystroke.
    @State private var appliedSearchText: String = ""
    @State private var showUncategorizedOnly: Bool = false
    @State private var selectedCategoryID: PersistentIdentifier?
    @State private var selection: Set<PersistentIdentifier> = []
    @State private var editingRequest: CategoryEditingRequest?
    @State private var renamingTransactions: [Transaction] = []
    @State private var renameDraft: String = ""
    @State private var dateFilterEnabled: Bool = false
    @State private var dateFrom: Date = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var dateTo: Date = .now

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            table
        }
        .task(id: searchText) {
            // Debounce: wait 250ms after the last keystroke before applying
            // the filter. If another keystroke arrives first, SwiftUI
            // cancels this task and starts a new one. The `Task.sleep`
            // call throws CancellationError on cancel so we silently fall
            // through without touching `appliedSearchText`.
            do {
                try await Task.sleep(for: .milliseconds(250))
                appliedSearchText = searchText
            } catch {
                // cancelled — new keystroke arrived, nothing to do
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        switch filter {
        case .all: "All Transactions"
        case .account(let a): a.displayName
        }
    }

    /// Hard cap on the number of rows handed to the SwiftUI `Table`. Above
    /// this, the main-thread diff when transitioning between filter states
    /// becomes noticeable (~several hundred ms on ~7k rows). The full history
    /// still lives in the store and is searched in full — only the display
    /// array is capped.
    private static let rowCap = 2000

    private var filteredUnderlying: [Transaction] {
        transactions.filter { tx in
            switch filter {
            case .all: break
            case .account(let a):
                if tx.account?.persistentModelID != a.persistentModelID {
                    return false
                }
            }
            if showUncategorizedOnly && tx.category != nil {
                return false
            }
            if let cid = selectedCategoryID, tx.category?.persistentModelID != cid {
                return false
            }
            if dateFilterEnabled {
                let startOfDay = Calendar.current.startOfDay(for: dateFrom)
                let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: dateTo)) ?? dateTo
                if tx.bookingDate < startOfDay || tx.bookingDate >= endOfDay {
                    return false
                }
            }
            if !appliedSearchText.isEmpty {
                let inText = tx.text.range(of: appliedSearchText, options: .caseInsensitive) != nil
                let inUser = tx.userText?.range(of: appliedSearchText, options: .caseInsensitive) != nil
                if !inText && !inUser {
                    return false
                }
            }
            return true
        }
    }

    private var filtered: [Transaction] {
        let matching = filteredUnderlying
        if matching.count > Self.rowCap {
            return Array(matching.prefix(Self.rowCap))
        }
        return matching
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                if case .account(let account) = filter {
                    Text(account.accountNumber)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var subtitle: String {
        let matching = filteredUnderlying.count
        let total = transactions.count
        let capped = matching > Self.rowCap
        if capped {
            return "Showing newest \(Self.rowCap) of \(matching) matching · \(total) total"
        }
        if matching == total {
            return "\(total) transactions"
        }
        return "\(matching) of \(total) transactions"
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search text", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    // Turn off every macOS text-input service that's hosted
                    // out-of-process via a remote view. Those services
                    // (autocorrect, completion, text replacement, spell
                    // check, grammar check, smart quotes) are what trigger
                    // the `ViewBridge to RemoteViewService Terminated`
                    // disconnect + main-thread hang when the field value
                    // churns rapidly.
                    .autocorrectionDisabled(true)
                    .disableAutocorrection(true)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 260)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )

            Toggle(isOn: $showUncategorizedOnly) {
                Label("Uncategorized", systemImage: "questionmark.circle")
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.button)
            .controlSize(.small)

            Menu {
                Button("All categories") { selectedCategoryID = nil }
                Divider()
                ForEach(categories) { category in
                    Button(category.name) { selectedCategoryID = category.persistentModelID }
                }
            } label: {
                Label(
                    selectedCategoryID.flatMap { id in categories.first(where: { $0.persistentModelID == id })?.name } ?? "Category",
                    systemImage: "tag"
                )
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .frame(maxWidth: 160)

            Toggle(isOn: $dateFilterEnabled) {
                Label("Date range", systemImage: "calendar")
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.button)
            .controlSize(.small)

            if dateFilterEnabled {
                DatePicker("From", selection: $dateFrom, displayedComponents: .date)
                    .labelsHidden()
                    .controlSize(.small)
                Text("–").foregroundStyle(.secondary)
                DatePicker("To", selection: $dateTo, displayedComponents: .date)
                    .labelsHidden()
                    .controlSize(.small)
            }

            Spacer()

            Text("\(filtered.count) rows")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var table: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Date") { tx in
                Text(DateFormatters.shortDay.string(from: tx.bookingDate))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 110)

            TableColumn("Text") { tx in
                HStack(spacing: 6) {
                    transferBadge(for: tx)
                    Text(tx.displayText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(rowTextColor(for: tx))
                        .italic(tx.userText != nil)
                }
                .contextMenu {
                    Button("Copy") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(tx.displayText, forType: .string)
                    }
                    Divider()
                    Button(renameMenuLabel(for: tx)) {
                        let targets = renameTargets(for: tx)
                        renameDraft = targets.count == 1 ? targets[0].displayText : ""
                        renamingTransactions = targets
                    }
                    if tx.userText != nil {
                        Button("Reset to original") {
                            tx.userText = nil
                            tx.userTextSource = .none
                            try? context.save()
                            signals.bump()
                        }
                    }
                    Divider()
                    transferContextMenu(for: tx)
                }
            }

            TableColumn("Category") { tx in
                Button {
                    editingRequest = makeEditingRequest(for: tx)
                } label: {
                    CategoryChip(category: tx.category, subcategory: tx.subcategory)
                }
                .buttonStyle(.plain)
            }
            .width(min: 160, ideal: 200)

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
                    .fontWeight(tx.amount >= 0 ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Balance") { tx in
                Text(MoneyFormatter.string(tx.runningBalance))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 120)
        }
        .popover(item: $editingRequest, arrowEdge: .top) { request in
            CategoryEditorPopover(transactions: request.transactions) {
                editingRequest = nil
            }
            .environment(signals)
        }
        .alert(
            renamingTransactions.count > 1
                ? "Rename \(renamingTransactions.count) transactions"
                : "Rename transaction",
            isPresented: Binding(
                get: { !renamingTransactions.isEmpty },
                set: { if !$0 { renamingTransactions = [] } }
            )
        ) {
            TextField("Text", text: $renameDraft)
            Button("Save") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                for tx in renamingTransactions {
                    if trimmed.isEmpty {
                        tx.userText = nil
                        tx.userTextSource = .none
                    } else {
                        tx.userText = trimmed
                        tx.userTextSource = .manual
                    }
                }
                try? context.save()
                signals.bump()
                renamingTransactions = []
            }
            Button("Cancel", role: .cancel) {
                renamingTransactions = []
            }
        } message: {
            Text("Override the bank-supplied text. Leave empty to reset.")
        }
    }

    // MARK: - Transfer badge + context menu

    @ViewBuilder
    private func transferBadge(for tx: Transaction) -> some View {
        switch tx.transferStatus {
        case .none:
            EmptyView()
        case .pairedOutgoing, .pairedIncoming:
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .foregroundStyle(.secondary)
                .help("Internal transfer — excluded from analytics")
        case .ambiguous:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("Ambiguous transfer — needs review")
        case .unmatched:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help("Unmatched transfer — no positive match in destination")
        }
    }

    private func rowTextColor(for tx: Transaction) -> Color {
        switch tx.transferStatus {
        case .none, .unmatched:
            return .primary
        case .pairedOutgoing, .pairedIncoming, .ambiguous:
            return .secondary
        }
    }

    /// If the clicked row is part of a multi-selection, build an editing
    /// request that covers every selected row. Otherwise edit just the
    /// clicked row, even if there's a selection that doesn't include it.
    private func makeEditingRequest(for tx: Transaction) -> CategoryEditingRequest {
        if selection.contains(tx.persistentModelID) && selection.count > 1 {
            let rows = filtered.filter { selection.contains($0.persistentModelID) }
            if !rows.isEmpty {
                return CategoryEditingRequest(transactions: rows)
            }
        }
        return CategoryEditingRequest(transactions: [tx])
    }

    /// Same multi-selection semantics as `makeEditingRequest` but for the
    /// rename alert. When the clicked row is part of the current selection
    /// and there's more than one row selected, rename covers all of them.
    private func renameTargets(for tx: Transaction) -> [Transaction] {
        if selection.contains(tx.persistentModelID) && selection.count > 1 {
            let rows = filtered.filter { selection.contains($0.persistentModelID) }
            if !rows.isEmpty {
                return rows
            }
        }
        return [tx]
    }

    private func renameMenuLabel(for tx: Transaction) -> String {
        let targets = renameTargets(for: tx)
        return targets.count > 1 ? "Rename \(targets.count) transactions…" : "Rename…"
    }

    @ViewBuilder
    private func transferContextMenu(for tx: Transaction) -> some View {
        if tx.transferStatus.isTransfer {
            Button("Unmark as internal transfer") {
                TransferPairingService.setManualTransferFlag(tx, isTransfer: false, in: context)
                try? context.save()
                signals.bump()
            }
        } else {
            Button("Mark as internal transfer") {
                TransferPairingService.setManualTransferFlag(tx, isTransfer: true, in: context)
                try? context.save()
                signals.bump()
            }
        }
    }
}

// MARK: - Category editing request

/// A click on a category chip becomes one of these. Wraps the set of
/// transactions the popover should apply its choice to — either a single
/// row or every selected row when the clicked row is part of a multi-
/// selection. Identifiable so it can drive `.popover(item:)`.
struct CategoryEditingRequest: Identifiable {
    let id = UUID()
    let transactions: [Transaction]
}

// MARK: - Category editor popover

struct CategoryEditorPopover: View {
    let transactions: [Transaction]
    @Environment(\.modelContext) private var context
    @Environment(AppSignals.self) private var signals
    @Query(sort: [SortDescriptor(\Category.sortIndex)]) private var categories: [Category]

    var onDone: () -> Void
    @State private var rememberAsRule: Bool = false

    /// Common category across all targets, or nil if they disagree.
    private var sharedCategoryID: PersistentIdentifier? {
        guard let first = transactions.first?.category?.persistentModelID else {
            return nil
        }
        return transactions.allSatisfy { $0.category?.persistentModelID == first } ? first : nil
    }

    private var isMulti: Bool { transactions.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isMulti
                 ? "Set category for \(transactions.count) transactions"
                 : "Set category")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if categories.isEmpty {
                Text("No categories yet. Create some in Categories & Rules.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                    ForEach(categories) { category in
                        Button {
                            assign(category)
                        } label: {
                            CategoryChip(category: category, subcategory: nil)
                                .padding(4)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(sharedCategoryID == category.persistentModelID
                                              ? Color.accentColor.opacity(0.15)
                                              : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        clear()
                    } label: {
                        CategoryChip(category: nil, subcategory: nil)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !isMulti {
                Divider()
                Toggle("Remember this (create a rule)", isOn: $rememberAsRule)
                    .font(.callout)
                Text("Rule: **Text contains** \(Text("“\(ruleHint)”").font(.system(.caption, design: .monospaced))) → selected category")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 320, maxWidth: 360)
    }

    private var ruleHint: String {
        guard let text = transactions.first?.text else {
            return ""
        }
        let token = text.split(separator: "/").first.map(String.init) ?? text
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assign(_ category: Category) {
        for tx in transactions {
            tx.category = category
            tx.subcategory = nil
            tx.categorySource = .manual
        }
        if !isMulti && rememberAsRule {
            createRule(for: category)
        }
        try? context.save()
        signals.bump()
    }

    private func clear() {
        for tx in transactions {
            tx.category = nil
            tx.subcategory = nil
            tx.categorySource = .none
        }
        try? context.save()
        signals.bump()
    }

    private func createRule(for category: Category) {
        let pattern = ruleHint
        guard !pattern.isEmpty else {
            return
        }
        let existingRules = (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? []
        // Skip if an equivalent rule already exists: same field, same kind,
        // same pattern (case-insensitive), same target category, same sign
        // gate. The popover always creates `.text contains`/`.any`, so an
        // existing rule with those traits and the same pattern + category
        // is a duplicate even if its name differs.
        let isDuplicate = existingRules.contains { rule in
            rule.matchField == .text
                && rule.matchKind == .contains
                && rule.signConstraint == .any
                && rule.pattern.caseInsensitiveCompare(pattern) == .orderedSame
                && rule.category?.persistentModelID == category.persistentModelID
        }
        if isDuplicate {
            return
        }
        let rule = CategoryRule(
            name: pattern.capitalized,
            priority: existingRules.count + 1,
            matchField: .text,
            matchKind: .contains,
            pattern: pattern,
            category: category
        )
        context.insert(rule)
    }
}
