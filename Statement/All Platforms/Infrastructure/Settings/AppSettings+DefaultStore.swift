//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import KeyValueStore

// MARK: - Default Store

extension AnyKeyValueStore where Key == AppSettings.Key {

    /// The default store for `AppSettings`, backed by `UserDefaults`.
    @MainActor internal static let defaultStore = UserDefaultsStore(
            keyedBy: Key.self,
            prefixedBy: "AppSettings"
        )
        .eraseToAnyKeyValueStore()
}
