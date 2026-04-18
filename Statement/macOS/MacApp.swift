//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData
import SwiftUIToolbox
import AttributionsUI
import AppDesign
import Sparkle

@main
struct MacApp: App {

    // swiftlint:disable:next weak_delegate
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init() {
        AppDesign.apply()
    }

    var body: some Scene {
        MainWindow()
            .commands {
                CheckForUpdatesCommand(updater: updaterController.updater)
            }
        SettingsWindow()
        AboutWindow(developedBy: "Apparata AB",
                    attributionsWindowID: AttributionsWindow.windowID)
        AttributionsWindow([
            ("CoreXLSX", .bsd0Clause(year: "2019-2024", holder: "CoreOffice contributors")),
            ("Sparkle", .mit(year: "2006-2024", holder: "Andy Matuschak and the Sparkle Project Contributors"))
        ], header: "The following software may be included in this product.")
        HelpWindow()
    }
}
