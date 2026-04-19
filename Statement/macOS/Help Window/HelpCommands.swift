//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import AppKit

struct HelpCommands: Commands {

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button {
                openWindow(id: HelpWindow.windowID)
            } label: {
                Text("\(Bundle.main.name) Help")
            }

            Divider()

            Button("New Demo Profile") {
                MainActor.assumeIsolated {
                    createOrSwitchToDemoProfile()
                }
            }
        }
    }

    @MainActor
    private func createOrSwitchToDemoProfile() {
        let store = ProfileStore.shared

        if let existing = store.profiles.first(where: { $0.displayName == DemoData.profileName }) {
            store.setActive(existing)
            return
        }

        let profile = store.create(name: DemoData.profileName)
        do {
            let container = try store.container(for: profile.id)
            DemoData.populate(context: container.mainContext)
            store.setActive(profile)
        } catch {
            store.delete(profile)
            let alert = NSAlert()
            alert.messageText = "Couldn't create demo profile"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
