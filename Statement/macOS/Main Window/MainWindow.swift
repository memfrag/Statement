//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData
import SwiftUIToolbox

struct MainWindow: Scene {

    var body: some Scene {
        WindowGroup {
            ProfileContainerHost(profileStore: ProfileStore.shared)
                .appEnvironment(.default)
        }
        .commands {
            AboutCommand()
            SidebarCommands()
            ImportCommands()
            RuleCommands()
            BackupCommands()
            HelpCommands()
            CommandGroup(replacing: .newItem, addition: { })
        }
    }
}
