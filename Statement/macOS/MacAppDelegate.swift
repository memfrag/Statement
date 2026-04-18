//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI

class MacAppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
