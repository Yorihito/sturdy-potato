import Foundation
import Observation

/// Manages routing profiles: creation, deletion, persistence and application.
@Observable
@MainActor
final class ProfileViewModel {

    // MARK: - Published state

    private(set) var profiles: [Profile] = []
    var activeProfile: Profile?
    var lastError: String?

    // MARK: - Service

    private let service = ProfileService()

    // MARK: - Init

    init() {
        profiles = service.load()
    }

    // MARK: - Public API

    /// Snapshots the current app-to-device assignments from `routingVM` into a new profile.
    func createProfile(name: String, from routingVM: AudioRoutingViewModel) -> Profile {
        let mappings = Dictionary(
            uniqueKeysWithValues: routingVM.apps.map { ($0.id, $0.assignedDeviceUID) }
        )
        let profile = Profile(name: name, mappings: mappings)
        service.add(profile)
        profiles = service.load()
        return profile
    }

    /// Applies the profile's device mappings to all running apps via `routingVM`.
    func apply(_ profile: Profile, using routingVM: AudioRoutingViewModel) async {
        activeProfile = profile
        for app in routingVM.apps {
            let uid = profile.mappings[app.id] ?? AudioDevice.systemDefault.uid
            let device = routingVM.devices.first { $0.uid == uid } ?? .systemDefault
            await routingVM.assign(device: device, toApp: app)
        }
    }

    /// Removes a profile from persistent storage and the in-memory list.
    func delete(_ profile: Profile) {
        service.delete(id: profile.id)
        profiles = service.load()
        if activeProfile?.id == profile.id {
            activeProfile = nil
        }
    }

    /// Persists an updated profile.
    func update(_ profile: Profile) {
        service.update(profile)
        profiles = service.load()
        if activeProfile?.id == profile.id {
            activeProfile = profile
        }
    }
}
