import Foundation

/// Persists and retrieves routing profiles using `UserDefaults`.
final class ProfileService: @unchecked Sendable {

    private let defaultsKey = "audiorouter.profiles"
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Persistence

    func save(_ profiles: [Profile]) {
        guard let data = try? JSONEncoder().encode(profiles) else {
            assertionFailure("ProfileService: failed to encode profiles")
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }

    func load() -> [Profile] {
        guard let data = defaults.data(forKey: defaultsKey),
              let profiles = try? JSONDecoder().decode([Profile].self, from: data)
        else { return [] }
        return profiles
    }

    // MARK: - Apply

    /// Applies a profile's device mappings to the supplied running apps array in-place.
    ///
    /// - Parameters:
    ///   - profile: The profile whose mappings should be applied.
    ///   - apps: Inout array of `AppEntry` values to update.
    ///
    /// Returns the updated array (mutated in-place for convenience).
    @discardableResult
    func apply(_ profile: Profile, to apps: inout [AppEntry]) -> [AppEntry] {
        for index in apps.indices {
            if let uid = profile.mappings[apps[index].id] {
                apps[index].assignedDeviceUID = uid
            } else {
                apps[index].assignedDeviceUID = AudioDevice.systemDefault.uid
            }
        }
        return apps
    }

    // MARK: - CRUD helpers

    func add(_ profile: Profile) {
        var existing = load()
        existing.append(profile)
        save(existing)
    }

    func delete(id: UUID) {
        var existing = load()
        existing.removeAll { $0.id == id }
        save(existing)
    }

    func update(_ profile: Profile) {
        var existing = load()
        if let idx = existing.firstIndex(where: { $0.id == profile.id }) {
            existing[idx] = profile
        } else {
            existing.append(profile)
        }
        save(existing)
    }
}
