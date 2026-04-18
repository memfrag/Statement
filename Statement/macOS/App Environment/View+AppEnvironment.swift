//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI

extension View {
    func appEnvironment(_ appEnvironment: AppEnvironment) -> some View {
        self.environment(appEnvironment.appSettings)
    }

    #if DEBUG
    func previewEnvironment() -> some View {
        self.environment(AppEnvironment.mock().appSettings)
    }
    #endif
}
