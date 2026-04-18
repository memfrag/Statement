//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData

/// Builds per-profile SwiftData containers for Statement.
///
/// Each profile has its own `.sqlite` file under
/// `Application Support/Statement/Profiles/<profile-uuid>/Statement.sqlite`.
/// Containers are constructed on demand; `ProfileStore` caches them by
/// profile ID for the lifetime of the process.
@MainActor
enum StatementModelContainer {

    private static let schema = Schema([
        Account.self,
        Transaction.self,
        Category.self,
        Subcategory.self,
        CategoryRule.self,
        RenameRule.self,
        ImportBatch.self
    ])

    /// Create a freshly-opened container for the given profile. Creates the
    /// on-disk folder if it doesn't exist.
    static func make(profileID: UUID) throws -> ModelContainer {
        let url = try storeURL(for: profileID, create: true)
        let config = ModelConfiguration(
            "Statement",
            schema: schema,
            url: url
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Deletes the entire profile folder (store + any SwiftData auxiliaries).
    /// Called when a profile is deleted or when "Erase all profiles" runs.
    static func removeStore(for profileID: UUID) {
        guard let folder = try? profileFolder(for: profileID, create: false) else {
            return
        }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Paths

    /// `…/Application Support/Statement/Profiles/<uuid>/Statement.sqlite`
    static func storeURL(for profileID: UUID, create: Bool) throws -> URL {
        let folder = try profileFolder(for: profileID, create: create)
        return folder.appendingPathComponent("Statement.sqlite", isDirectory: false)
    }

    /// `…/Application Support/Statement/Profiles/<uuid>/`
    static func profileFolder(for profileID: UUID, create: Bool) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base
            .appendingPathComponent("Statement", isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
        if create {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
        }
        return folder
    }
}
