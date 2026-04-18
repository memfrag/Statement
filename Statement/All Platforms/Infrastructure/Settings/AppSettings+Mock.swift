//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import KeyValueStore

// MARK: - Mock Store

#if DEBUG

extension AppSettings {

    /// Creates a mock instance of `AppSettings` for use in previews and testing.
    ///
    /// The mock store is backed by an in-memory key–value store.
    ///
    /// - Returns: A mock `AppSettings` instance.
    ///
    @MainActor public static func mock() -> AppSettings {
        let store = InMemoryKeyValueStore(keyedBy: Key.self, initialContent: [
            .colorScheme: AppColorScheme.system
        ])
        return AppSettings(store: store.eraseToAnyKeyValueStore())
    }
}

#endif
