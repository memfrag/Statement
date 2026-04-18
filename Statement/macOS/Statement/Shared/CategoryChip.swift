//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI

struct CategoryChip: View {
    let category: Category?
    let subcategory: Subcategory?

    var body: some View {
        let hasCategory = category != nil
        let tint: Color = category.map { AccountPalette.color(for: $0.colorIndex) } ?? .secondary
        let label: String = {
            if let c = category {
                if let s = subcategory {
                    return "\(c.name) · \(s.name)"
                }
                return c.name
            }
            return "Uncategorized"
        }()

        HStack(spacing: 6) {
            Circle()
                .fill(hasCategory ? tint : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hasCategory ? tint : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(hasCategory ? tint.opacity(0.14) : Color.clear)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(hasCategory ? Color.clear : Color.secondary.opacity(0.35), lineWidth: 1)
        )
    }
}
