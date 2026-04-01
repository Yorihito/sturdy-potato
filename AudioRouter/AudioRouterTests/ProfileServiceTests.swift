import XCTest
@testable import AudioRouter

// MARK: - ProfileServiceTests

/// Tests ProfileService using an in-memory UserDefaults suite so we never
/// touch the real user defaults.
final class ProfileServiceTests: XCTestCase {

    private let suiteName = "com.audiorouter.tests.profiles.\(UUID().uuidString)"
    var defaults: UserDefaults!
    var sut: ProfileService!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        sut = ProfileService(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        sut = nil
        super.tearDown()
    }

    // MARK: - load (empty state)

    func test_load_whenNothingSaved_returnsEmptyArray() {
        let profiles = sut.load()
        XCTAssertEqual(profiles, [])
    }

    // MARK: - save / load round-trip

    func test_saveAndLoad_singleProfile() throws {
        let profile = Profile(name: "Test", mappings: ["com.apple.music": "uid-hdmi"])
        sut.save([profile])
        let loaded = sut.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Test")
        XCTAssertEqual(loaded.first?.mappings["com.apple.music"], "uid-hdmi")
    }

    func test_saveAndLoad_multipleProfiles_preservesOrder() {
        let p1 = Profile(name: "Home", mappings: [:])
        let p2 = Profile(name: "Work", mappings: ["com.zoom.us": "uid-headphones"])
        let p3 = Profile(name: "Studio", mappings: [:])
        sut.save([p1, p2, p3])
        let loaded = sut.load()
        XCTAssertEqual(loaded.map(\.name), ["Home", "Work", "Studio"])
    }

    func test_save_emptyArray_clearsProfiles() {
        let p = Profile(name: "Temp", mappings: [:])
        sut.save([p])
        sut.save([])
        XCTAssertEqual(sut.load(), [])
    }

    func test_save_overwritesPreviousData() {
        let old = Profile(name: "Old", mappings: [:])
        let new = Profile(name: "New", mappings: [:])
        sut.save([old])
        sut.save([new])
        let loaded = sut.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "New")
    }

    // MARK: - add

    func test_add_appendsProfile() {
        let p1 = Profile(name: "A", mappings: [:])
        let p2 = Profile(name: "B", mappings: [:])
        sut.add(p1)
        sut.add(p2)
        let loaded = sut.load()
        XCTAssertEqual(loaded.count, 2)
    }

    // MARK: - delete

    func test_delete_removesCorrectProfile() {
        let p1 = Profile(name: "Keep", mappings: [:])
        let p2 = Profile(name: "Remove", mappings: [:])
        sut.save([p1, p2])
        sut.delete(id: p2.id)
        let loaded = sut.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Keep")
    }

    func test_delete_nonExistentID_doesNotCrash() {
        let p = Profile(name: "A", mappings: [:])
        sut.save([p])
        sut.delete(id: UUID()) // random non-existing id
        XCTAssertEqual(sut.load().count, 1)
    }

    // MARK: - update

    func test_update_modifiesExistingProfile() {
        var p = Profile(name: "Original", mappings: [:])
        sut.save([p])
        p.name = "Updated"
        p.mappings["com.spotify.client"] = "uid-speakers"
        sut.update(p)
        let loaded = sut.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Updated")
        XCTAssertEqual(loaded.first?.mappings["com.spotify.client"], "uid-speakers")
    }

    func test_update_insertsIfNotFound() {
        let p = Profile(name: "New", mappings: [:])
        sut.update(p) // nothing in storage yet
        XCTAssertEqual(sut.load().count, 1)
    }

    // MARK: - apply

    func test_apply_updatesMatchingAppEntries() {
        let profile = Profile(
            name: "P",
            mappings: [
                "com.apple.safari": "uid-speakers",
                "com.apple.music": "uid-hdmi"
            ]
        )
        var apps: [AppEntry] = [
            AppEntry(id: "com.apple.safari", name: "Safari", icon: nil,
                     assignedDeviceUID: "system-default", processID: 101),
            AppEntry(id: "com.apple.music",  name: "Music",  icon: nil,
                     assignedDeviceUID: "system-default", processID: 102),
            AppEntry(id: "com.apple.maps",   name: "Maps",   icon: nil,
                     assignedDeviceUID: "system-default", processID: 103)
        ]

        sut.apply(profile, to: &apps)

        XCTAssertEqual(apps[0].assignedDeviceUID, "uid-speakers")
        XCTAssertEqual(apps[1].assignedDeviceUID, "uid-hdmi")
        XCTAssertEqual(apps[2].assignedDeviceUID, AudioDevice.systemDefault.uid,
                       "Apps not in profile should fall back to system default")
    }

    func test_apply_emptyMappings_resetsAllToDefault() {
        let profile = Profile(name: "Empty", mappings: [:])
        var apps: [AppEntry] = [
            AppEntry(id: "com.example.app", name: "App", icon: nil,
                     assignedDeviceUID: "uid-hdmi", processID: 1)
        ]
        sut.apply(profile, to: &apps)
        XCTAssertEqual(apps[0].assignedDeviceUID, AudioDevice.systemDefault.uid)
    }

    func test_apply_emptyAppArray_doesNotCrash() {
        let profile = Profile(name: "P", mappings: ["com.foo": "uid-bar"])
        var apps: [AppEntry] = []
        sut.apply(profile, to: &apps)
        XCTAssertTrue(apps.isEmpty)
    }

    // MARK: - Profile Codable

    func test_profile_codable_roundTrip() throws {
        let original = Profile(
            id: UUID(),
            name: "Round Trip",
            mappings: ["com.test": "uid-test", "com.other": "system-default"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_profile_equatable() {
        let id = UUID()
        let p1 = Profile(id: id, name: "Same", mappings: [:])
        let p2 = Profile(id: id, name: "Same", mappings: [:])
        let p3 = Profile(id: UUID(), name: "Different", mappings: [:])
        XCTAssertEqual(p1, p2)
        XCTAssertNotEqual(p1, p3)
    }

    // MARK: - Concurrency (lightweight)

    func test_saveAndLoad_concurrentAccess_doesNotCrash() async {
        let sut = self.sut!
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let profile = Profile(name: "P\(i)", mappings: [:])
                    sut.save([profile])
                    _ = sut.load()
                }
            }
        }
    }
}
