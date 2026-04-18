//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import Sparkle

struct CheckForUpdatesCommand: Commands {

    let updater: SPUUpdater

    @State private var canCheckForUpdates = false

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!canCheckForUpdates)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) { newValue in
                canCheckForUpdates = newValue
            }
        }
    }
}
