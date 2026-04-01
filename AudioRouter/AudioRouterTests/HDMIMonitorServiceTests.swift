import XCTest
import CoreAudio
@testable import AudioRouter

// MARK: - HDMIMonitorServiceTests

final class HDMIMonitorServiceTests: XCTestCase {

    var sut: HDMIMonitorService!

    override func setUp() {
        super.setUp()
        sut = HDMIMonitorService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - isHDMI

    func test_isHDMI_unknownObjectID_returnsFalse() {
        // kAudioObjectUnknown should never be HDMI
        let result = sut.isHDMI(deviceID: AudioDeviceID(kAudioObjectUnknown))
        XCTAssertFalse(result, "Unknown device ID should not be identified as HDMI")
    }

    func test_isHDMI_realDevices_doesNotCrash() {
        // Just ensure no crash when iterating real devices
        let ids = allDeviceIDs()
        for id in ids {
            _ = sut.isHDMI(deviceID: id)
        }
    }

    // MARK: - hdmiOutputDeviceIDs

    func test_hdmiOutputDeviceIDs_returnsArray() {
        // Result may be empty on machines with no HDMI – that's fine
        let ids = sut.hdmiOutputDeviceIDs()
        XCTAssertNotNil(ids)
    }

    func test_hdmiOutputDeviceIDs_allAreHDMI() {
        let ids = sut.hdmiOutputDeviceIDs()
        for id in ids {
            XCTAssertTrue(sut.isHDMI(deviceID: id),
                          "Device \(id) returned by hdmiOutputDeviceIDs() must be HDMI")
        }
    }

    func test_hdmiOutputDeviceIDs_subsetOfAllDevices() {
        let all = Set(allDeviceIDs())
        let hdmi = Set(sut.hdmiOutputDeviceIDs())
        XCTAssertTrue(hdmi.isSubset(of: all),
                      "HDMI IDs must be a subset of all HAL device IDs")
    }

    // MARK: - ioKitHDMIDeviceNames

    func test_ioKitHDMIDeviceNames_returnsArray() {
        let names = sut.ioKitHDMIDeviceNames()
        XCTAssertNotNil(names, "Should return an array (possibly empty)")
    }

    func test_ioKitHDMIDeviceNames_allNonEmpty() {
        let names = sut.ioKitHDMIDeviceNames()
        for name in names {
            XCTAssertFalse(name.isEmpty, "Device name from IOKit should not be empty")
        }
    }

    func test_ioKitHDMIDeviceNames_containHDMIOrDisplayPort() {
        let names = sut.ioKitHDMIDeviceNames()
        for name in names {
            let lower = name.lowercased()
            XCTAssertTrue(
                lower.contains("hdmi") || lower.contains("displayport"),
                "IOKit HDMI device name '\(name)' should contain 'hdmi' or 'displayport'"
            )
        }
    }

    // MARK: - Sendable / value-semantics

    func test_hdmiMonitorService_isSendable() {
        // Verifies the compiler-enforced Sendable conformance by crossing
        // an actor boundary.
        let service = sut!
        let exp = expectation(description: "Sendable across actor boundary")
        Task.detached {
            let result = service.isHDMI(deviceID: AudioDeviceID(kAudioObjectUnknown))
            XCTAssertFalse(result)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    // MARK: - Helpers

    private func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize
        ) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }
        return ids
    }
}
