//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftData
import SwiftUI

/// Observable catalog of user profiles.
///
/// Loads / saves itself from a JSON file in Application Support. Hands out
/// per-profile `ModelContainer`s on demand (with internal caching), and
/// publishes `activeProfileID` so views can react to switches via
/// `.id(store.activeProfileID)`.
@MainActor
@Observable
final class ProfileStore {

    /// Process-wide shared instance. Used by scene-level Commands (which
    /// live outside the view hierarchy and can't read `@Environment`) to
    /// reach the active profile's container. Views should still use
    /// `@Environment(ProfileStore.self)` for reactive observation.
    @ObservationIgnored
    static let shared: ProfileStore = .loadOrBootstrap()

    private(set) var profiles: [Profile]
    private(set) var activeProfileID: UUID

    /// Cache of live containers keyed by profile ID. Containers are retained
    /// after first use so switching back to a previously-opened profile is
    /// instantaneous.
    @ObservationIgnored
    private var containerCache: [UUID: ModelContainer] = [:]

    // MARK: - Init / load

    private init(catalog: ProfileCatalog) {
        self.profiles = catalog.profiles
        self.activeProfileID = catalog.activeProfileID
    }

    static func loadOrBootstrap() -> ProfileStore {
        let url = Self.catalogURL
        if let data = try? Data(contentsOf: url),
           let catalog = try? JSONDecoder().decode(ProfileCatalog.self, from: data),
           !catalog.profiles.isEmpty,
           catalog.profiles.contains(where: { $0.id == catalog.activeProfileID }) {
            return ProfileStore(catalog: catalog)
        }

        // Bootstrap: create a single Default profile.
        let defaultProfile = Profile(displayName: "Default")
        let bootstrapped = ProfileCatalog(
            profiles: [defaultProfile],
            activeProfileID: defaultProfile.id
        )
        let store = ProfileStore(catalog: bootstrapped)
        store.persist()
        return store
    }

    // MARK: - Lookups

    var activeProfile: Profile {
        profiles.first { $0.id == activeProfileID } ?? profiles[0]
    }

    // MARK: - Container access

    /// Returns (and memoizes) the SwiftData container for the given profile.
    func container(for profileID: UUID) throws -> ModelContainer {
        if let cached = containerCache[profileID] {
            return cached
        }
        let container = try StatementModelContainer.make(profileID: profileID)
        containerCache[profileID] = container
        return container
    }

    /// Convenience: the container for the currently active profile.
    func activeContainer() throws -> ModelContainer {
        try container(for: activeProfileID)
    }

    /// Optional accessor suitable for scene-level Commands. Returns nil if
    /// the container fails to open; callers can then surface an NSAlert.
    var activeContext: ModelContext? {
        (try? activeContainer())?.mainContext
    }

    // MARK: - Mutations

    func create(name: String) -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? "Profile \(profiles.count + 1)" : trimmed
        let profile = Profile(displayName: final)
        profiles.append(profile)
        persist()
        return profile
    }

    func rename(_ profile: Profile, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        profiles[index].displayName = trimmed
        persist()
    }

    /// Deletes the profile from the catalog AND removes its on-disk store.
    /// Refuses if it would leave the catalog empty.
    func delete(_ profile: Profile) {
        guard profiles.count > 1 else {
            return
        }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }

        // Tear down any live container for this profile and remove disk storage.
        containerCache.removeValue(forKey: profile.id)
        StatementModelContainer.removeStore(for: profile.id)
        SeedData.clearMigrationFlags(for: profile.id)

        profiles.remove(at: index)
        if activeProfileID == profile.id {
            activeProfileID = profiles[0].id
        }
        persist()
    }

    func setActive(_ profile: Profile) {
        guard profiles.contains(where: { $0.id == profile.id }) else {
            return
        }
        activeProfileID = profile.id
        persist()
    }

    /// Removes every profile's on-disk store and resets the catalog to a
    /// single fresh Default profile. Used by "Erase all profiles".
    func eraseAllProfiles() {
        for profile in profiles {
            containerCache.removeValue(forKey: profile.id)
            StatementModelContainer.removeStore(for: profile.id)
            SeedData.clearMigrationFlags(for: profile.id)
        }

        let defaultProfile = Profile(displayName: "Default")
        profiles = [defaultProfile]
        activeProfileID = defaultProfile.id
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let catalog = ProfileCatalog(profiles: profiles, activeProfileID: activeProfileID)
        do {
            let data = try JSONEncoder().encode(catalog)
            let url = Self.catalogURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ProfileStore] failed to persist catalog: \(error)")
        }
    }

    private static var catalogURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Statement", isDirectory: true)
            .appendingPathComponent("profiles.json", isDirectory: false)
    }
}
