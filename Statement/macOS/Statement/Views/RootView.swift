//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

/// Top-level container for the main window. Owns selection, seeds defaults,
/// wires the drop receiver, constructs the analytics actor, and routes between
/// the sidebar destinations.
struct RootView: View {
    let profileID: UUID
    let modelContainer: ModelContainer

    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileStore.self) private var profileStore
    @Query private var accounts: [Account]
    @State private var selection: SidebarDestination? = .allTransactions
    @State private var coordinator = ImportCoordinator()
    @State private var signals: AppSignals
    @State private var analytics: AnalyticsActor
    @State private var analyticsCache: AnalyticsCache
    @State private var analysisFilter = AnalysisFilter()
    @State private var searchText: String = ""

    init(profileID: UUID, modelContainer: ModelContainer) {
        self.profileID = profileID
        self.modelContainer = modelContainer
        let signalsInit = AppSignals()
        let actorInit = AnalyticsActor(modelContainer: modelContainer)
        _signals = State(initialValue: signalsInit)
        _analytics = State(initialValue: actorInit)
        _analyticsCache = State(initialValue: AnalyticsCache(actor: actorInit, signals: signalsInit))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            detailContent
                .toolbar { toolbarContent }
        }
        .statementDropReceiver(coordinator: coordinator, container: modelContainer, signals: signals)
        .sheet(isPresented: $coordinator.isImporting) {
            ImportProgressSheet(statusText: coordinator.importStatus)
        }
        .sheet(item: $coordinator.lastResult) { result in
            ImportSummarySheet(result: result) {
                let unresolved = result.unresolvedTransferIDs
                coordinator.lastResult = nil
                if !unresolved.isEmpty {
                    coordinator.pendingReview = TransferReviewRequest(outgoingIDs: unresolved)
                }
            }
            .environment(signals)
            .environment(analyticsCache)
        }
        .sheet(item: $coordinator.pendingReview) { request in
            ReviewTransfersSheet(request: request) {
                coordinator.pendingReview = nil
            }
            .environment(signals)
            .environment(analyticsCache)
        }
        .onReceive(NotificationCenter.default.publisher(for: .statementOpenReviewTransfers)) { _ in
            // On-demand mode: open the sheet with no specific IDs so it
            // pulls every unresolved row in the store.
            coordinator.pendingReview = TransferReviewRequest(outgoingIDs: [])
        }
        .onReceive(NotificationCenter.default.publisher(for: .statementImportedDataErased)) { _ in
            // The store was wiped; invalidate caches and force re-render.
            signals.bump()
        }
        .onReceive(NotificationCenter.default.publisher(for: .statementEraseRequest)) { note in
            let scope = (note.userInfo?["scope"] as? String) ?? "active"
            if scope == "active" {
                eraseActiveProfile()
            } else if scope == "all" {
                profileStore.eraseAllProfiles()
            }
        }
        .task {
            SeedData.seedIfEmpty(context: modelContext)
            SeedData.migrateAddHealthIfNeeded(context: modelContext, profileID: profileID)
            SeedData.migrateAddInternalTransferCategoryIfNeeded(context: modelContext, profileID: profileID)
            SeedData.migrateAddExpenseCategoryIfNeeded(context: modelContext, profileID: profileID)
            SeedData.migrateAddSoftwareCategoryIfNeeded(context: modelContext, profileID: profileID)
            SeedData.migrateAddLifestyleCategoriesIfNeeded(context: modelContext, profileID: profileID)
            SeedData.migrateAddSavingsCategoryIfNeeded(context: modelContext, profileID: profileID)
            SeedData.migrateAddHardwareCategoriesIfNeeded(context: modelContext, profileID: profileID)
            SeedData.migrateAddClothesCategoryIfNeeded(context: modelContext, profileID: profileID)
            SeedData.migrateFlagInternalTransfersIfNeeded(context: modelContext, profileID: profileID)
            SeedData.migrateCleanupXLSXTextIfNeeded(context: modelContext, profileID: profileID)
            signals.bump()
            #if DEBUG
            StartupVerifier.runIfRequested(context: modelContext)
            #endif
        }
        // Environment modifiers applied OUTSIDE (last in chain) so every
        // ancestor modifier above — including sheets and the drop receiver —
        // inherits these values. macOS sheets built inside `.sheet` closures
        // don't always propagate `@Observable` through the presenter boundary,
        // so the sheet closures also re-inject the observables they read.
        .environment(coordinator)
        .environment(signals)
        .environment(analyticsCache)
        .environment(analysisFilter)
        .environment(\.analyticsActor, analytics)
    }

    @ViewBuilder
    private var detailContent: some View {
        if accounts.isEmpty {
            EmptyDropZoneView()
        } else {
            switch selection {
            case .allTransactions, .none:
                TransactionsView(filter: .all)
            case .analysis:
                AnalysisRootView()
            case .categoriesAndRules:
                CategoriesAndRulesView()
            case .importHistory:
                ImportHistoryView()
            case .account(let id):
                if let account = accounts.first(where: { $0.persistentModelID == id }) {
                    TransactionsView(filter: .account(account))
                } else {
                    TransactionsView(filter: .all)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                openImportPanel()
            } label: {
                Label("Import", systemImage: "tray.and.arrow.down")
            }
            .help("Import SEB .xlsx statements (⌘O)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                try? CategoryRuleEngine.applyToAll(in: modelContext, preserveManual: true)
                try? modelContext.save()
                signals.bump()
            } label: {
                Label("Re-apply", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Re-apply rules to all transactions (keep manual)")
        }
    }

    /// Wipes accounts, transactions, and import batches from the active
    /// profile's store. Categories and rules stay. Analytics cache is
    /// invalidated via `signals.bump()`.
    private func eraseActiveProfile() {
        do {
            for tx in try modelContext.fetch(FetchDescriptor<Transaction>()) {
                modelContext.delete(tx)
            }
            for batch in try modelContext.fetch(FetchDescriptor<ImportBatch>()) {
                modelContext.delete(batch)
            }
            for account in try modelContext.fetch(FetchDescriptor<Account>()) {
                modelContext.delete(account)
            }
            try modelContext.save()
            signals.bump()
        } catch {
            print("[Erase active] failed: \(error)")
        }
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xlsx") ?? .spreadsheet,
            UTType.pdf
        ]
        panel.prompt = "Import"
        panel.message = "Select one or more SEB kontoutdrag .xlsx or .pdf statements"
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else {
                return
            }
            let urls = panel.urls
            Task { @MainActor in
                await coordinator.run(urls, container: modelContainer)
                signals.bump()
            }
        }
    }
}

// MARK: - Environment key for AnalyticsActor

private struct AnalyticsActorKey: EnvironmentKey {
    static let defaultValue: AnalyticsActor? = nil
}

extension EnvironmentValues {
    var analyticsActor: AnalyticsActor? {
        get { self[AnalyticsActorKey.self] }
        set { self[AnalyticsActorKey.self] = newValue }
    }
}
