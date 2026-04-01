import Foundation
import AppKit
import Observation

/// Monitors running applications and exposes them as `AppEntry` values.
/// Only apps with `.regular` activation policy are included.
@Observable
@MainActor
final class AppMonitorService {

    /// Currently running regular applications.
    private(set) var runningApps: [AppEntry] = []

    // nonisolated(unsafe): deinit is nonisolated in Swift 6, but we only
    // ever write this on MainActor (init/installObservers), and read it in
    // deinit which runs after all actor tasks have finished.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// Called on MainActor when a new app entry appears.
    var onLaunch: ((AppEntry) -> Void)?
    /// Called on MainActor when an app terminates (passes bundleID).
    var onTerminate: ((String) -> Void)?

    init() {
        refresh()
        installObservers()
    }

    deinit {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Private

    private func refresh() {
        var seen = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { makeEntry(from: $0) }
            .filter { seen.insert($0.id).inserted }   // 同一バンドル ID は最初の1件のみ残す
    }

    private func makeEntry(from app: NSRunningApplication) -> AppEntry? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        let name = app.localizedName ?? bundleID
        return AppEntry(
            id: bundleID,
            name: name,
            icon: app.icon,
            assignedDeviceUID: currentAssignment(for: bundleID),
            processID: app.processIdentifier
        )
    }

    /// Returns a previously persisted device UID for the given bundle, or the sentinel default.
    private func currentAssignment(for bundleID: String) -> String {
        UserDefaults.standard.string(forKey: "audiorouter.assignment.\(bundleID)")
            ?? AudioDevice.systemDefault.uid
    }

    private func installObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        let launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract NSRunningApplication before crossing isolation boundary
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app else { return }
                // バンドル ID が既存になければ追加（同一アプリの複数プロセスは除外）
                if let entry = self.makeEntry(from: app),
                   !self.runningApps.contains(where: { $0.id == entry.id }) {
                    self.runningApps.append(entry)
                    self.onLaunch?(entry)
                }
            }
        }

        let termObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid else { return }
                if let terminated = self.runningApps.first(where: { $0.processID == pid }) {
                    self.onTerminate?(terminated.id)
                }
                self.runningApps.removeAll { $0.processID == pid }
            }
        }

        observers = [launchObs, termObs]
    }

    // MARK: - Public

    /// Persist the device assignment for a bundle so it survives restarts.
    func persistAssignment(bundleID: String, deviceUID: String) {
        UserDefaults.standard.set(deviceUID, forKey: "audiorouter.assignment.\(bundleID)")
        // Update live entry
        if let idx = runningApps.firstIndex(where: { $0.id == bundleID }) {
            runningApps[idx].assignedDeviceUID = deviceUID
        }
    }
}
