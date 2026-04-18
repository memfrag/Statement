//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI

struct EmptyDropZoneView: View {
    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 84, height: 84)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
                        )
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .shadow(color: Color.accentColor.opacity(0.35), radius: 20, y: 10)

                Text("Drop kontoutdrag files to begin")
                    .font(.system(size: 22, weight: .bold, design: .default))

                Text("Drag one or more SEB .xlsx or .pdf statements onto the window. Statement parses them, deduplicates against anything you've imported before, and attaches transactions to the right account automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)

                HStack(spacing: 6) {
                    Text("⌘O").kbdStyle()
                    Text("to browse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(40)
            .frame(maxWidth: 600)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.regularMaterial)
                    )
            }
            .padding(40)
        }
    }
}

private extension Text {
    func kbdStyle() -> some View {
        self
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
            )
    }
}
