//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI

/// Sidebar footer that shows the active profile's name and a menu button for
/// switching, renaming, creating, and deleting profiles.
struct ProfileSwitcherFooter: View {
    @Environment(ProfileStore.self) private var store

    @State private var showNewSheet: Bool = false
    @State private var showRenameSheet: Bool = false
    @State private var confirmDelete: Profile?
    @State private var workingName: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(avatarColor(for: store.activeProfile))
                .frame(width: 22, height: 22)
                .overlay(
                    Text(initials(for: store.activeProfile.displayName))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(store.activeProfile.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("Profile")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Menu {
                // Active profile section
                Section {
                    ForEach(store.profiles) { profile in
                        Button {
                            store.setActive(profile)
                        } label: {
                            if profile.id == store.activeProfileID {
                                Label(profile.displayName, systemImage: "checkmark")
                            } else {
                                Text(profile.displayName)
                            }
                        }
                    }
                }

                Section {
                    Button("New Profile…") {
                        workingName = ""
                        showNewSheet = true
                    }
                    Button("Rename \"\(store.activeProfile.displayName)\"…") {
                        workingName = store.activeProfile.displayName
                        showRenameSheet = true
                    }
                    Button("Delete \"\(store.activeProfile.displayName)\"…", role: .destructive) {
                        confirmDelete = store.activeProfile
                    }
                    .disabled(store.profiles.count <= 1)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .regular))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 0.5),
            alignment: .top
        )
        .sheet(isPresented: $showNewSheet) {
            ProfileNameSheet(title: "New Profile", name: $workingName) {
                let profile = store.create(name: workingName)
                store.setActive(profile)
                showNewSheet = false
            } onCancel: {
                showNewSheet = false
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            ProfileNameSheet(title: "Rename Profile", name: $workingName) {
                store.rename(store.activeProfile, to: workingName)
                showRenameSheet = false
            } onCancel: {
                showRenameSheet = false
            }
        }
        .confirmationDialog("Delete profile \"\(confirmDelete?.displayName ?? "")\"?",
                            isPresented: Binding(get: { confirmDelete != nil },
                                                 set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Profile", role: .destructive) {
                if let profile = confirmDelete {
                    store.delete(profile)
                }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) {
                confirmDelete = nil
            }
        } message: {
            Text("This permanently removes the profile and its store file from disk. Other profiles are unaffected. This can't be undone.")
        }
    }

    // MARK: Avatar helpers

    private func initials(for name: String) -> String {
        let components = name.split(separator: " ").prefix(2)
        let letters = components.compactMap { $0.first.map(String.init) }
        let joined = letters.joined().uppercased()
        return joined.isEmpty ? "?" : String(joined.prefix(2))
    }

    private func avatarColor(for profile: Profile) -> Color {
        // Deterministic color from the UUID.
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .green, .teal, .cyan, .mint, .brown]
        let hash = abs(profile.id.uuidString.hashValue)
        return palette[hash % palette.count]
    }
}

// MARK: - Name sheet

private struct ProfileNameSheet: View {
    let title: String
    @Binding var name: String
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}
