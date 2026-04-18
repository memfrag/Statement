//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation

extension AppEnvironment {
    #if DEBUG
    internal static func mock() -> AppEnvironment {
        AppEnvironment(appSettings: AppSettings.mock())
    }
    #endif
}
