//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import AttributionsUI

struct OpenSourceAttributions: View {
    
    var body: some View {
        Attributions(
            ("CGMath", .bsd0Clause(year: "2025", holder: "Apparata AB")),
            ("MathKit", .bsd0Clause(year: "2025", holder: "Apparata AB"))
        )
        .attributionsHeader("The following software and/or data sets may be included in this product.")
    }
}
