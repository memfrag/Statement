//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation

/// A user profile = a named SwiftData store on disk.
///
/// Profiles are kept in a tiny JSON file at
/// `Application Support/<bundle>/profiles.json` so they live outside any
/// single SwiftData store and can enumerate without having to open anything.
struct Profile: Identifiable, Codable, Hashable {
    let id: UUID
    var displayName: String
    var createdAt: Date

    init(id: UUID = UUID(), displayName: String, createdAt: Date = .now) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

/// Persistent envelope written to `profiles.json`.
struct ProfileCatalog: Codable {
    var profiles: [Profile]
    var activeProfileID: UUID
}
