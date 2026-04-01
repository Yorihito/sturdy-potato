import Foundation
import CoreAudio
import AppKit

// MARK: - Errors

enum AudioDeviceError: Error, LocalizedError {
    case coreAudioError(OSStatus, String)
    case deviceNotFound(String)
    case noDefaultDevice

    var errorDescription: String? {
        switch self {
        case .coreAudioError(let status, let context):
            return "CoreAudio error \(status) in \(context)"
        case .deviceNotFound(let uid):
            return "Audio device not found: \(uid)"
        case .noDefaultDevice:
            return "No default output device available"
        }
    }
}

// MARK: - AudioDeviceService

actor AudioDeviceService {

    /// Fires whenever the HAL device list changes.
    let deviceChangeStream: AsyncStream<Void>
    private let deviceChangeContinuation: AsyncStream<Void>.Continuation

    init() {
        var cont: AsyncStream<Void>.Continuation!
        self.deviceChangeStream = AsyncStream { cont = $0 }
        self.deviceChangeContinuation = cont
    }

    // MARK: - Public API

    func getOutputDevices() throws -> [AudioDevice] {
        let ids = try getAllDeviceIDs()
        var result: [AudioDevice] = [.systemDefault]
        for id in ids {
            if let dev = try? makeAudioDevice(from: id) {
                result.append(dev)
            }
        }
        return result
    }

    func getSystemDefaultOutputDevice() -> AudioDevice? {
        var defaultID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID
        )
        guard status == noErr, defaultID != kAudioObjectUnknown else { return nil }
        return try? makeAudioDevice(from: defaultID)
    }

    /// Switches the system-wide default output device to the device identified by `uid`.
    /// Pass `AudioDevice.systemDefault.uid` to no-op (the caller should handle this).
    func setSystemDefault(uid: String) throws {
        let targetID: AudioDeviceID
        if uid == AudioDevice.systemDefault.uid {
            guard let dev = getSystemDefaultOutputDevice() else {
                throw AudioDeviceError.noDefaultDevice
            }
            targetID = dev.id
        } else {
            targetID = try resolveDeviceID(uid: uid)
        }
        try setSystemDefaultOutputDevice(deviceID: targetID)
    }

    // MARK: - Private helpers

    private func getAllDeviceIDs() throws -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        )
        guard status == noErr else {
            throw AudioDeviceError.coreAudioError(status, "GetPropertyDataSize(Devices)")
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        )
        guard status == noErr else {
            throw AudioDeviceError.coreAudioError(status, "GetPropertyData(Devices)")
        }
        return ids.filter { hasOutputStreams(deviceID: $0) }
    }

    private func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr && size > 0
    }

    private func makeAudioDevice(from deviceID: AudioDeviceID) throws -> AudioDevice {
        let name = try getStringProperty(objectID: deviceID, selector: kAudioObjectPropertyName)
        let uid  = try getStringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
        let isHDMI = getTransportType(deviceID: deviceID) == kAudioDeviceTransportTypeHDMI
        return AudioDevice(id: deviceID, name: name, uid: uid, isHDMI: isHDMI)
    }

    private func getStringProperty(objectID: AudioObjectID,
                                   selector: AudioObjectPropertySelector) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CoreAudio returns CFString at +1 (caller must release).
        // Use Unmanaged so Swift does not insert an extra retain/release pair.
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ref)
        guard status == noErr, let ref else {
            throw AudioDeviceError.coreAudioError(status, "getStringProperty(\(selector))")
        }
        // takeRetainedValue() consumes the +1 that CoreAudio gave us.
        return ref.takeRetainedValue() as String
    }

    private func getTransportType(deviceID: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport)
        return transport
    }

    private func resolveDeviceID(uid: String) throws -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        )
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        )
        for deviceID in ids {
            if let devUID = try? getStringProperty(objectID: deviceID,
                                                    selector: kAudioDevicePropertyDeviceUID),
               devUID == uid {
                return deviceID
            }
        }
        throw AudioDeviceError.deviceNotFound(uid)
    }

    func setSystemDefaultOutputDevice(deviceID: AudioDeviceID) throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &id
        )
        guard status == noErr else {
            throw AudioDeviceError.coreAudioError(status, "setSystemDefaultOutputDevice")
        }
    }

    private func pidForBundleID(_ bundleID: String) -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }
            .map { $0.processIdentifier }
    }
}
