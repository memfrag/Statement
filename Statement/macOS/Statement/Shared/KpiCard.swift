//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI

/// A KPI card used in the top row of each analysis view.
struct KpiCard: View {
    let label: String
    let value: String
    var subtitle: String?
    var color: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(color == .secondary ? .secondary : color)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}
