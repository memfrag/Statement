//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation

extension AppEnvironment {

    /// The lazily constructed, process-global environment.
    ///
    /// This value is created by ``makeAppEnvironment()`` and is intended for read-only access
    /// in production code. In most app code, prefer `@Environment(AppSettings.self)` and other
    /// dependency mechanisms over reaching for this singleton.
    public static let `default`: AppEnvironment = makeAppEnvironment()

    /// Creates the process-global environment based on runtime conditions.
    ///
    /// If the `APP_ENVIRONMENT` process environment variable equals "mock" (case-insensitive)
    /// and the build is `DEBUG`, a mock environment is returned; otherwise a live environment
    /// is constructed.
    ///
    /// - Returns: The configured ``AppEnvironment`` instance used by ``shared``.
    ///
    private static func makeAppEnvironment() -> AppEnvironment {
        #if DEBUG
        if ProcessInfo.processInfo.environment["APP_ENVIRONMENT"]?.lowercased() == "mock" {
            return .mock()
        }
        #endif
        return .live()
    }
}