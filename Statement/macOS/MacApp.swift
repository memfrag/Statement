//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData
import SwiftUIToolbox
import AttributionsUI
import AppDesign

@main
struct MacApp: App {

    // swiftlint:disable:next weak_delegate
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate

    init() {
        AppDesign.apply()
    }

    var body: some Scene {
        MainWindow()
        SettingsWindow()
        AboutWindow(developedBy: "Apparata AB",
                    attributionsWindowID: AttributionsWindow.windowID)
        AttributionsWindow([
            ("CoreXLSX", .bsd0Clause(year: "2019-2024", holder: "CoreOffice contributors"))
        ], header: "The following software may be included in this product.")
        HelpWindow()
    }
}
