import Foundation
import CoreAudio
import IOKit
import IOKit.audio

/// Provides HDMI device detection by inspecting the CoreAudio transport type
/// property and, optionally, the IOKit audio device registry.
final class HDMIMonitorService: Sendable {

    // MARK: - Public API

    /// Returns `true` when the given CoreAudio device is connected over HDMI.
    func isHDMI(deviceID: AudioDeviceID) -> Bool {
        transportType(for: deviceID) == kAudioDeviceTransportTypeHDMI
    }

    /// Returns all CoreAudio output device IDs whose transport type is HDMI.
    func hdmiOutputDeviceIDs() -> [AudioDeviceID] {
        allDeviceIDs().filter { isHDMI(deviceID: $0) }
    }

    // MARK: - IOKit enumeration (supplementary)

    /// Enumerates IOKit audio device services and returns the names of those
    /// that are HDMI-capable (transport == HDMI).
    func ioKitHDMIDeviceNames() -> [String] {
        var names: [String] = []
        let matchingDict = IOServiceMatching("IOAudioDevice")
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS else {
            return names
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            // Read the human-readable name
            var nameCStr = [CChar](repeating: 0, count: 128)
            if IORegistryEntryGetName(service, &nameCStr) == KERN_SUCCESS {
                let nameStr = String(cString: nameCStr)
                // Heuristic: IOKit audio devices labelled with HDMI
                if nameStr.localizedCaseInsensitiveContains("HDMI") ||
                   nameStr.localizedCaseInsensitiveContains("DisplayPort") {
                    names.append(nameStr)
                }
            }
        }
        return names
    }

    // MARK: - Private helpers

    private func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(AudioObjectID(deviceID), &addr, 0, nil, &size, &value)
        return value
    }

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
