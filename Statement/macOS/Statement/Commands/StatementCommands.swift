//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

// MARK: - Import commands

struct ImportCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import SEB Statement…") {
                MainActor.assumeIsolated {
                    runImportPanel()
                }
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
    }

    @MainActor
    private func runImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xlsx") ?? .spreadsheet
        ]
        panel.prompt = "Import"
        panel.message = "Select one or more SEB kontoutdrag .xlsx exports"
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else {
                return
            }
            let urls = panel.urls
            Task { @MainActor in
                guard let context = ProfileStore.shared.activeContext else {
                    return
                }
                _ = StatementImportService.importFiles(urls, context: context)
            }
        }
    }
}

// MARK: - Rule commands

struct RuleCommands: Commands {
    @State private var showConfirm: Bool = false

    var body: some Commands {
        CommandMenu("Rules") {
            Button("Re-apply Rules (keep manual)") {
                MainActor.assumeIsolated {
                    guard let context = ProfileStore.shared.activeContext else {
                        return
                    }
                    try? CategoryRuleEngine.applyToAll(in: context, preserveManual: true)
                    try? context.save()
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("Re-apply Rules (overwrite manual)…") {
                MainActor.assumeIsolated {
                    let alert = NSAlert()
                    alert.messageText = "Overwrite manual categorizations?"
                    alert.informativeText = "Every transaction's category will be rewritten from the first matching rule, including transactions you edited by hand. This can't be undone."
                    alert.addButton(withTitle: "Overwrite")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        guard let context = ProfileStore.shared.activeContext else {
                            return
                        }
                        try? CategoryRuleEngine.applyToAll(in: context, preserveManual: false)
                        try? context.save()
                    }
                }
            }

            Divider()

            Button("Review Transfers…") {
                NotificationCenter.default.post(
                    name: .statementOpenReviewTransfers, object: nil
                )
            }
        }
    }
}

extension Notification.Name {
    /// Posted by the `Rules → Review Transfers…` menu command. Observed by
    /// `RootView`, which opens the Review Transfers sheet in on-demand mode.
    static let statementOpenReviewTransfers = Notification.Name("statement.openReviewTransfers")

    /// Posted after `File → Erase All Imported Data…` successfully wipes
    /// transactions/batches/accounts. `RootView` observes it and bumps
    /// `AppSignals` so analytics caches invalidate.
    static let statementImportedDataErased = Notification.Name("statement.importedDataErased")

    /// Posted when the user picks an option in the Erase confirmation alert.
    /// The user info dict has a `"scope"` key: `"active"` or `"all"`.
    /// `RootView` observes and routes to `ProfileStore` / the active context.
    static let statementEraseRequest = Notification.Name("statement.eraseRequest")
}

// MARK: - Backup commands

struct BackupCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export All Data…") {
                MainActor.assumeIsolated { runExport() }
            }
            Button("Import Data…") {
                MainActor.assumeIsolated { runRestore() }
            }
            Divider()
            Button("Export Profile…") {
                MainActor.assumeIsolated { runExportProfile() }
            }
            Button("Import Profile…") {
                MainActor.assumeIsolated { runImportProfile() }
            }
            Divider()
            Button("Erase All Imported Data…") {
                MainActor.assumeIsolated { runErase() }
            }
        }
    }

    @MainActor
    private func runExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Statement-backup.json"
        panel.prompt = "Export"
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            Task { @MainActor in
                guard let context = ProfileStore.shared.activeContext else {
                    return
                }
                do {
                    try DataExporter.export(to: url, context: context)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Export failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    @MainActor
    private func runErase() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Erase imported data?"
        alert.informativeText = "Choose what to erase. Active profile only removes accounts, transactions, and import batches from the current profile (categories and rules stay). All profiles wipes every profile's store file from disk and resets to a single empty Default profile. Neither action can be undone — export a backup first if you might want the data back."
        alert.addButton(withTitle: "Erase Active Profile")
        alert.addButton(withTitle: "Erase All Profiles")
        alert.addButton(withTitle: "Cancel")
        if alert.buttons.count >= 2 {
            alert.buttons[0].hasDestructiveAction = true
            alert.buttons[1].hasDestructiveAction = true
        }
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NotificationCenter.default.post(
                name: .statementEraseRequest,
                object: nil,
                userInfo: ["scope": "active"]
            )
        case .alertSecondButtonReturn:
            NotificationCenter.default.post(
                name: .statementEraseRequest,
                object: nil,
                userInfo: ["scope": "all"]
            )
        default:
            return
        }
    }

    @MainActor
    private func runRestore() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            Task { @MainActor in
                guard let context = ProfileStore.shared.activeContext else {
                    return
                }
                do {
                    let summary = try DataImporter.importBackup(from: url, context: context)
                    let alert = NSAlert()
                    alert.messageText = "Backup imported"
                    alert.informativeText = """
                    \(summary.accountsInserted) accounts · \
                    \(summary.transactionsInserted) transactions · \
                    \(summary.transactionsSkipped) duplicates skipped.
                    """
                    alert.runModal()
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Import failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    @MainActor
    private func runExportProfile() {
        let activeName = ProfileStore.shared.activeProfile.displayName
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(activeName).statementprofile.json"
        panel.prompt = "Export Profile"
        panel.message = "Export the active profile '\(activeName)' including its accounts, transactions, categories, and rules."
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            Task { @MainActor in
                do {
                    try ProfileIO.exportActiveProfile(to: url)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Profile export failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    @MainActor
    private func runImportProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import Profile"
        panel.message = "Pick a profile export to add as a new profile."
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            Task { @MainActor in
                do {
                    let result = try ProfileIO.importProfile(from: url)
                    ProfileStore.shared.setActive(result.profile)
                    let alert = NSAlert()
                    alert.messageText = "Profile imported as \"\(result.profile.displayName)\""
                    alert.informativeText = """
                    \(result.summary.accountsInserted) accounts · \
                    \(result.summary.transactionsInserted) transactions · \
                    \(result.summary.rulesInserted) rules · \
                    \(result.summary.renameRulesInserted) rename rules.
                    """
                    alert.runModal()
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Profile import failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
}
