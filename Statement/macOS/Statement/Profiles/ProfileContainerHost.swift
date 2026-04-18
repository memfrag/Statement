//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData

/// Bridges `ProfileStore` to `RootView`.
///
/// Watches `activeProfileID`, opens the container for that profile on demand
/// (cached by `ProfileStore`), and forces a full `RootView` rebuild on every
/// profile switch via `.id(activeProfileID)`. The rebuild recreates the
/// analytics actor + cache bound to the new container, wipes transient UI
/// state (search text, selection, drop-sheet state), and kicks off
/// seed/migration `.task` against the new store.
struct ProfileContainerHost: View {
    let profileStore: ProfileStore

    var body: some View {
        let activeID = profileStore.activeProfileID
        content(for: activeID)
            .id(activeID)
            .environment(profileStore)
    }

    @ViewBuilder
    private func content(for profileID: UUID) -> some View {
        if let container = try? profileStore.container(for: profileID) {
            RootView(profileID: profileID, modelContainer: container)
                .frame(minWidth: 960, minHeight: 640)
                .modelContainer(container)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Failed to open profile")
                    .font(.title2.weight(.semibold))
                Text("The store file for this profile couldn't be opened. Try restarting the app or switching profiles.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }
}
