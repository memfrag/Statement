//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI

/// Colors used to visually tag accounts and categories.
enum AccountPalette {

    static let all: [Color] = [
        .cyan, .indigo, .orange, .pink, .mint, .teal, .purple, .yellow, .red, .brown, .green, .blue
    ]

    static func color(for index: Int) -> Color {
        all[((index % all.count) + all.count) % all.count]
    }
}
