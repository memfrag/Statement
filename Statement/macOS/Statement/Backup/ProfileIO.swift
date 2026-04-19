//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData

/// Profile-level counterpart to `DataExporter` / `DataImporter`.
///
/// "Export Profile…" writes a backup envelope tagged with the profile's
/// display name. "Import Profile…" creates a fresh profile in
/// `ProfileStore`, opens its container, and feeds the envelope into the
/// new profile's store. This lets users move a whole profile between
/// machines in a single file without touching any existing profile.
@MainActor
enum ProfileIO {

    enum ImportError: LocalizedError {
        case containerFailed(Error)

        var errorDescription: String? {
            switch self {
            case .containerFailed(let underlying):
                return "Couldn't open the new profile's store: \(underlying.localizedDescription)"
            }
        }
    }

    struct ImportResult {
        let profile: Profile
        let summary: DataImportSummary
    }

    static func exportActiveProfile(to url: URL) throws {
        let store = ProfileStore.shared
        let profile = store.activeProfile
        let container = try store.activeContainer()
        try DataExporter.export(
            to: url,
            context: container.mainContext,
            profileName: profile.displayName
        )
    }

    static func importProfile(from url: URL) throws -> ImportResult {
        let store = ProfileStore.shared

        let suggestedName = (try? DataImporter.peekProfileName(from: url))
            ?? url.deletingPathExtension().lastPathComponent

        let finalName = uniqueProfileName(base: suggestedName, existing: store.profiles)
        let profile = store.create(name: finalName)

        let container: ModelContainer
        do {
            container = try store.container(for: profile.id)
        } catch {
            store.delete(profile)
            throw ImportError.containerFailed(error)
        }

        let summary: DataImportSummary
        do {
            summary = try DataImporter.importBackup(
                from: url,
                context: container.mainContext
            )
            try? CategoryRuleEngine.applyToAll(in: container.mainContext, preserveManual: true)
            try? RenameRuleEngine.applyToAll(in: container.mainContext, preserveManual: true)
            _ = TransferPairingService.rescanAll(in: container.mainContext)
            try container.mainContext.save()
        } catch {
            store.delete(profile)
            throw error
        }

        return ImportResult(profile: profile, summary: summary)
    }

    // MARK: - Helpers

    private static func uniqueProfileName(base: String, existing: [Profile]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "Imported Profile" : trimmed
        let names = Set(existing.map(\.displayName))
        if !names.contains(root) {
            return root
        }
        var suffix = 2
        while names.contains("\(root) (\(suffix))") {
            suffix += 1
        }
        return "\(root) (\(suffix))"
    }
}
