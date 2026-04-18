//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData

// MARK: - Destination

enum SidebarDestination: Hashable {
    case allTransactions
    case analysis
    case categoriesAndRules
    case importHistory
    case account(PersistentIdentifier)
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var selection: SidebarDestination?

    @Environment(\.modelContext) private var context
    @Environment(AppSignals.self) private var signals
    @Environment(AnalyticsCache.self) private var cache
    @Query(sort: [SortDescriptor(\Account.displayName)])
    private var accounts: [Account]

    @State private var renamingAccount: Account?
    @State private var confirmDeleteAccount: Account?
    @State private var balances: [String: Decimal] = [:]

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                row(.allTransactions, label: "All Transactions", systemImage: "list.bullet.rectangle")
                row(.analysis, label: "Analysis", systemImage: "chart.line.uptrend.xyaxis")
                row(.importHistory, label: "Import History", systemImage: "clock.arrow.circlepath")
                row(.categoriesAndRules, label: "Categories & Rules", systemImage: "tag")
            }

            if !accounts.isEmpty {
                Section("Accounts") {
                    ForEach(accounts) { account in
                        accountRow(account)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 220, maxWidth: 320)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ProfileSwitcherFooter()
        }
        .task(id: signals.storeRevision) {
            balances = await cache.accountLatestBalances()
        }
        .onAppear {
            if let cached = cache.peekAccountLatestBalances() {
                balances = cached
            }
        }
        .sheet(item: $renamingAccount) { account in
            RenameAccountSheet(account: account) {
                try? context.save()
                signals.bump()
                renamingAccount = nil
            } onCancel: {
                renamingAccount = nil
            }
        }
        .confirmationDialog("Delete this account?",
                            isPresented: Binding(get: { confirmDeleteAccount != nil },
                                                 set: { if !$0 { confirmDeleteAccount = nil } }),
                            titleVisibility: .visible) {
            Button("Delete \(confirmDeleteAccount?.transactions.count ?? 0) transactions", role: .destructive) {
                if let account = confirmDeleteAccount {
                    deleteAccount(account)
                }
                confirmDeleteAccount = nil
            }
            Button("Cancel", role: .cancel) { confirmDeleteAccount = nil }
        } message: {
            Text("This will remove the account and every transaction and import batch linked to it. This can't be undone.")
        }
    }

    @ViewBuilder
    private func row(_ destination: SidebarDestination, label: String, systemImage: String) -> some View {
        NavigationLink(value: destination) {
            Label(label, systemImage: systemImage)
        }
    }

    @ViewBuilder
    private func accountRow(_ account: Account) -> some View {
        NavigationLink(value: SidebarDestination.account(account.persistentModelID)) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(AccountPalette.color(for: account.colorIndex))
                    .frame(width: 10, height: 10)
                Text(account.displayName)
                Spacer(minLength: 4)
                Text(MoneyFormatter.shortKr(balances[account.accountNumber] ?? 0))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contextMenu {
            Button("Rename…") {
                renamingAccount = account
            }
            Menu("Color") {
                ForEach(0..<AccountPalette.all.count, id: \.self) { i in
                    Button {
                        account.colorIndex = i
                        try? context.save()
                        signals.bump()
                    } label: {
                        Label {
                            Text("Color \(i + 1)")
                        } icon: {
                            Circle().fill(AccountPalette.color(for: i))
                        }
                    }
                }
            }
            Divider()
            Button("Delete Account…", role: .destructive) {
                confirmDeleteAccount = account
            }
        }
    }

    private func deleteAccount(_ account: Account) {
        // Delete transactions individually to avoid SwiftData's mandatory-inverse batch delete error.
        for tx in account.transactions {
            context.delete(tx)
        }
        for batch in account.importBatches {
            context.delete(batch)
        }
        context.delete(account)
        try? context.save()

        // Deleting an account shrinks the known-numbers set. Any remaining
        // transaction whose text referenced that number is no longer a
        // transfer — re-scan to clear stale flags.
        _ = TransferPairingService.rescanAll(in: context)
        try? context.save()

        signals.bump()
    }
}

// MARK: - Rename sheet

private struct RenameAccountSheet: View {
    @Bindable var account: Account
    var onSave: () -> Void
    var onCancel: () -> Void

    @State private var workingName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename account").font(.headline)
            Text(account.accountNumber)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Display name", text: $workingName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save") {
                    let trimmed = workingName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        account.displayName = trimmed
                    }
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(workingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .onAppear { workingName = account.displayName }
    }
}
