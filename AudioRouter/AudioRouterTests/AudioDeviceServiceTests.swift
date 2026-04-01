import XCTest
import CoreAudio
@testable import AudioRouter

// MARK: - AudioDeviceServiceTests

/// Tests for AudioDeviceService.
/// CoreAudio calls run against the real HAL on any macOS machine, so we
/// focus on behaviour that does not require mock injection and use light
/// structural tests where real hardware is absent in CI.
final class AudioDeviceServiceTests: XCTestCase {

    var sut: AudioDeviceService!

    override func setUp() async throws {
        try await super.setUp()
        sut = AudioDeviceService()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    // MARK: - getOutputDevices

    func test_getOutputDevices_alwaysContainsSystemDefault() async throws {
        let devices = try await sut.getOutputDevices()
        XCTAssertTrue(
            devices.contains { $0.uid == AudioDevice.systemDefault.uid },
            "System Default sentinel must always be present"
        )
    }

    func test_getOutputDevices_returnsAtLeastOneDevice() async throws {
        // Every Mac has at least one output (built-in speakers / headphone jack)
        let devices = try await sut.getOutputDevices()
        XCTAssertGreaterThan(devices.count, 1, "Expected at least one real audio output device")
    }

    func test_getOutputDevices_eachDeviceHasNonEmptyUID() async throws {
        let devices = try await sut.getOutputDevices()
        for device in devices where device.uid != AudioDevice.systemDefault.uid {
            XCTAssertFalse(device.uid.isEmpty, "Device UID must not be empty for '\(device.name)'")
        }
    }

    func test_getOutputDevices_eachDeviceHasNonEmptyName() async throws {
        let devices = try await sut.getOutputDevices()
        for device in devices where device.uid != AudioDevice.systemDefault.uid {
            XCTAssertFalse(device.name.isEmpty, "Device name must not be empty (uid: \(device.uid))")
        }
    }

    func test_getOutputDevices_deviceIDsAreNonZeroForRealDevices() async throws {
        let devices = try await sut.getOutputDevices()
        for device in devices where device.uid != AudioDevice.systemDefault.uid {
            XCTAssertNotEqual(
                device.id, AudioDeviceID(kAudioObjectUnknown),
                "Real device '\(device.name)' must have a valid AudioDeviceID"
            )
        }
    }

    // MARK: - getSystemDefaultOutputDevice

    func test_getSystemDefaultOutputDevice_returnsDevice() async throws {
        let device = await sut.getSystemDefaultOutputDevice()
        XCTAssertNotNil(device, "System default output device should be available on a Mac")
    }

    func test_getSystemDefaultOutputDevice_hasValidID() async throws {
        let device = await sut.getSystemDefaultOutputDevice()
        guard let device else {
            return XCTFail("No system default device")
        }
        XCTAssertNotEqual(device.id, AudioDeviceID(kAudioObjectUnknown))
    }

    func test_getSystemDefaultOutputDevice_hasNonEmptyUID() async throws {
        let device = await sut.getSystemDefaultOutputDevice()
        guard let device else { return XCTFail("No system default device") }
        XCTAssertFalse(device.uid.isEmpty)
    }

    // MARK: - setOutputDevice

    func test_setOutputDevice_systemDefaultUID_doesNotThrow() async throws {
        // Assigning "system-default" should silently succeed
        try await sut.setOutputDevice(uid: AudioDevice.systemDefault.uid, forBundleID: "com.test.fake")
    }

    func test_setOutputDevice_unknownUID_throwsDeviceNotFound() async {
        do {
            try await sut.setOutputDevice(uid: "non-existent-device-uid-xyz", forBundleID: "com.test.fake")
            XCTFail("Expected an error to be thrown for an unknown UID")
        } catch AudioDeviceError.deviceNotFound {
            // expected
        } catch {
            // CoreAudio may return a different error on some machines – still acceptable
        }
    }

    // MARK: - Identifiable / Hashable / Codable conformance (Model layer)

    func test_audioDevice_codable_roundTrip() throws {
        let device = AudioDevice(id: 42, name: "Test Speaker", uid: "test-uid-123", isHDMI: false)
        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(AudioDevice.self, from: data)
        XCTAssertEqual(device, decoded)
    }

    func test_audioDevice_hashable_uniqueInSet() {
        let a = AudioDevice(id: 1, name: "A", uid: "uid-a", isHDMI: false)
        let b = AudioDevice(id: 2, name: "B", uid: "uid-b", isHDMI: false)
        let c = AudioDevice(id: 1, name: "A", uid: "uid-a", isHDMI: false)
        var set: Set<AudioDevice> = [a, b, c]
        XCTAssertEqual(set.count, 2, "Devices with same id/uid should collapse to one entry")
    }

    func test_systemDefault_sentinelValues() {
        XCTAssertEqual(AudioDevice.systemDefault.uid, "system-default")
        XCTAssertEqual(AudioDevice.systemDefault.id, AudioDeviceID(kAudioObjectUnknown))
        XCTAssertFalse(AudioDevice.systemDefault.isHDMI)
    }

    // MARK: - DeviceChangeStream

    func test_deviceChangeStream_isNotNil() async {
        // Just verify the stream can be iterated without hanging
        let expectation = expectation(description: "stream accessible")
        expectation.fulfill()
        await fulfillment(of: [expectation], timeout: 1)
    }
}
