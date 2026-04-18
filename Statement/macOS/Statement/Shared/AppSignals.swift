//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI

/// Cross-view store-mutation signal. Any code that writes to SwiftData should
/// call `bump()` after a successful save. Views interested in "the data changed"
/// can key their `.task(id: signals.storeRevision)` to react.
@MainActor
@Observable
final class AppSignals {
    var storeRevision: Int = 0

    func bump() {
        storeRevision &+= 1
    }
}
