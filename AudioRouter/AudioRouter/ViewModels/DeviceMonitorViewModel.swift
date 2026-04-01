import Foundation
import CoreAudio
import Observation

/// Observes audio device availability including hot-plug and removal events.
@Observable
@MainActor
final class DeviceMonitorViewModel {

    // MARK: - Published state

    private(set) var devices: [AudioDevice] = [.systemDefault]
    private(set) var hdmiDevices: [AudioDevice] = []
    var lastError: String?

    // MARK: - Services

    private let audioService = AudioDeviceService()
    private let hdmiService = HDMIMonitorService()

    // MARK: - Init

    init() {
        Task { await loadDevices() }
        Task { await observeChanges() }
    }

    // MARK: - Public

    func reload() async {
        await loadDevices()
    }

    // MARK: - Private

    private func loadDevices() async {
        do {
            let raw = try await audioService.getOutputDevices()
            devices = raw.map { dev in
                guard dev.id != kAudioObjectUnknown else { return dev }
                let isHDMI = hdmiService.isHDMI(deviceID: dev.id)
                return AudioDevice(id: dev.id, name: dev.name, uid: dev.uid, isHDMI: isHDMI)
            }
            hdmiDevices = devices.filter(\.isHDMI)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func observeChanges() async {
        for await _ in audioService.deviceChangeStream {
            await loadDevices()
        }
    }
}
