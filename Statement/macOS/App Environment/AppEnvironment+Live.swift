//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation

extension AppEnvironment {
    internal static func live() -> AppEnvironment {
        AppEnvironment(appSettings: AppSettings())
    }
}
