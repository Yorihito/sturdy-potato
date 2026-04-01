import Foundation
import CoreAudio
import Observation

/// Central view-model that combines app monitoring, device enumeration and
/// auto-switching the system default output when trigger apps launch or quit.
@Observable
@MainActor
final class AudioRoutingViewModel {

    // MARK: - Published state

    var apps: [AppEntry] = []
    var devices: [AudioDevice] = [.systemDefault]
    var isRefreshing: Bool = false
    var lastError: String?

    // MARK: - Services

    private let appMonitor = AppMonitorService()
    private let audioService = AudioDeviceService()
    private let hdmiService = HDMIMonitorService()
    private let autoSwitch: AutoSwitchService

    // MARK: - Init

    init() {
        autoSwitch = AutoSwitchService(audioService: audioService)

        apps = appMonitor.runningApps
        Task { await refresh() }
        Task { await observeDeviceChanges() }

        // Wire app-lifecycle callbacks into AutoSwitchService
        appMonitor.onLaunch = { [weak self] entry in
            guard let self else { return }
            let uid = entry.assignedDeviceUID
            Task { await self.autoSwitch.handleLaunch(bundleID: entry.id, assignedUID: uid) }
        }
        appMonitor.onTerminate = { [weak self] bundleID in
            guard let self else { return }
            let rules = self.currentRules()
            Task { await self.autoSwitch.handleTerminate(bundleID: bundleID, rules: rules) }
        }

        // Apply rules to apps already running at launch
        Task { await applyRulesToRunningApps() }
    }

    // MARK: - Public API

    /// Assigns `device` as the auto-switch trigger for `app`.
    /// When the app is running, the system output will switch to `device`.
    func assign(device: AudioDevice, toApp app: AppEntry) async {
        appMonitor.persistAssignment(bundleID: app.id, deviceUID: device.uid)
        syncAppsFromMonitor()
        let isRunning = apps.contains { $0.id == app.id }
        await autoSwitch.handleRuleChanged(bundleID: app.id, newUID: device.uid, isRunning: isRunning)
    }

    /// Reloads the device list and syncs the running-app roster.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let rawDevices = try await audioService.getOutputDevices()
            devices = rawDevices.map { dev in
                guard dev.id != kAudioObjectUnknown else { return dev }
                let isHDMI = hdmiService.isHDMI(deviceID: dev.id)
                return AudioDevice(id: dev.id, name: dev.name, uid: dev.uid, isHDMI: isHDMI)
            }
        } catch {
            lastError = error.localizedDescription
        }
        syncAppsFromMonitor()
    }

    // MARK: - Convenience

    /// Returns the `AudioDevice` currently assigned to `app`, or `.systemDefault`.
    func assignedDevice(for app: AppEntry) -> AudioDevice {
        devices.first { $0.uid == app.assignedDeviceUID } ?? .systemDefault
    }

    // MARK: - Private

    private func syncAppsFromMonitor() {
        apps = appMonitor.runningApps
    }

    private func currentRules() -> [String: String] {
        Dictionary(uniqueKeysWithValues: apps.compactMap { app in
            app.assignedDeviceUID != AudioDevice.systemDefault.uid
                ? (app.id, app.assignedDeviceUID) : nil
        })
    }

    /// Fires auto-switch for any trigger apps already running when the app starts.
    private func applyRulesToRunningApps() async {
        for app in apps where app.assignedDeviceUID != AudioDevice.systemDefault.uid {
            await autoSwitch.handleLaunch(bundleID: app.id, assignedUID: app.assignedDeviceUID)
        }
    }

    /// Listens for hot-plug / removal events and refreshes the device list.
    private func observeDeviceChanges() async {
        for await _ in audioService.deviceChangeStream {
            await refresh()
        }
    }
}
