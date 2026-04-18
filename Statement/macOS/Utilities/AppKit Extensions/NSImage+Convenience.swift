//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import AppKit

public extension NSImage {
    
    convenience init(requiredNamed name: String) {
        // swiftlint:disable:next force_unwrapping
        self.init(named: name)!
    }
}
