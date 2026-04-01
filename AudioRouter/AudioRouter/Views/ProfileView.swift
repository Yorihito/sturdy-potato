import SwiftUI

/// Manages saved routing profiles: create, apply, and delete.
struct ProfileView: View {

    var routingVM: AudioRoutingViewModel
    var profileVM: ProfileViewModel

    @State private var newProfileName: String = ""
    @State private var showNameError: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            createSection
            Divider()
            profileList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Subviews

    private var createSection: some View {
        HStack(spacing: 8) {
            TextField("New profile name", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveProfile() }
            Button("Save Current", action: saveProfile)
                .buttonStyle(.borderedProminent)
                .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
        .overlay(alignment: .bottom) {
            if showNameError {
                Text("Please enter a profile name.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private var profileList: some View {
        if profileVM.profiles.isEmpty {
            ContentUnavailableView(
                "No Saved Profiles",
                systemImage: "bookmark.slash",
                description: Text("Save the current routing as a named profile.")
            )
        } else {
            List {
                ForEach(profileVM.profiles) { profile in
                    ProfileRowView(
                        profile: profile,
                        isActive: profileVM.activeProfile?.id == profile.id,
                        onApply: {
                            Task { await profileVM.apply(profile, using: routingVM) }
                        },
                        onDelete: {
                            profileVM.delete(profile)
                        }
                    )
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Actions

    private func saveProfile() {
        let trimmed = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            showNameError = true
            return
        }
        showNameError = false
        _ = profileVM.createProfile(name: trimmed, from: routingVM)
        newProfileName = ""
    }
}

// MARK: - Row

private struct ProfileRowView: View {

    let profile: Profile
    let isActive: Bool
    let onApply: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(profile.name)
                        .fontWeight(isActive ? .semibold : .regular)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .imageScale(.small)
                    }
                }
                Text("\(profile.mappings.count) app\(profile.mappings.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Apply", action: onApply)
                .buttonStyle(.bordered)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete profile")
        }
        .padding(.vertical, 4)
    }
}
