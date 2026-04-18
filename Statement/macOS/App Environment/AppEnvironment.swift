//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import SwiftUI

/// An application-wide environment container for Statement.
///
/// Holds shared, read-only dependencies. Prefer SwiftUI `@Environment`
/// injection for accessing these from views.
public final class AppEnvironment {

    public let appSettings: AppSettings

    internal init(appSettings: AppSettings) {
        self.appSettings = appSettings
    }
}
