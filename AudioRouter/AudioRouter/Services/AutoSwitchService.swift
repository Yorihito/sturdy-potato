import Foundation

/// Automatically switches the system default output device when trigger apps launch or quit.
///
/// Rules: bundleID → deviceUID (non-system-default)
/// - When a trigger app launches → switch system output to its assigned device.
/// - When all trigger apps quit → restore the previously saved system default.
@Observable
@MainActor
final class AutoSwitchService {

    private let audioService: AudioDeviceService

    /// Bundle IDs of currently running trigger apps, in launch order.
    private(set) var activeTriggers: [String] = []

    /// System default device UID saved before the first trigger activated.
    private var savedDefaultUID: String?

    init(audioService: AudioDeviceService) {
        self.audioService = audioService
    }

    // MARK: - App lifecycle events

    /// Call when an app launches. `assignedUID` is the persisted rule for this bundle.
    func handleLaunch(bundleID: String, assignedUID: String) async {
        guard assignedUID != AudioDevice.systemDefault.uid else { return }

        if activeTriggers.isEmpty {
            savedDefaultUID = await audioService.getSystemDefaultOutputDevice()?.uid
        }
        if !activeTriggers.contains(bundleID) {
            activeTriggers.append(bundleID)
        }
        await switchTo(uid: assignedUID, reason: "\(bundleID) launched")
    }

    /// Call when an app quits. `rules` is the current bundleID→deviceUID map.
    func handleTerminate(bundleID: String, rules: [String: String]) async {
        activeTriggers.removeAll { $0 == bundleID }

        if activeTriggers.isEmpty {
            if let saved = savedDefaultUID {
                await switchTo(uid: saved, reason: "all triggers quit — restoring saved default")
                savedDefaultUID = nil
            }
        } else if let last = activeTriggers.last, let uid = rules[last] {
            await switchTo(uid: uid, reason: "\(bundleID) quit — switching to \(last)")
        }
    }

    /// Call when the user changes a rule assignment (app may already be running).
    func handleRuleChanged(bundleID: String, newUID: String, isRunning: Bool) async {
        if newUID == AudioDevice.systemDefault.uid {
            // Rule cleared
            let wasActive = activeTriggers.contains(bundleID)
            activeTriggers.removeAll { $0 == bundleID }
            if wasActive, activeTriggers.isEmpty, let saved = savedDefaultUID {
                await switchTo(uid: saved, reason: "rule cleared — restoring saved default")
                savedDefaultUID = nil
            }
        } else if isRunning {
            await handleLaunch(bundleID: bundleID, assignedUID: newUID)
        }
    }

    // MARK: - Private

    private func switchTo(uid: String, reason: String) async {
        do {
            try await audioService.setSystemDefault(uid: uid)
            NSLog("[AutoSwitch] %@ → %@", reason, uid)
        } catch {
            NSLog("[AutoSwitch] Failed (%@): %@", reason, error.localizedDescription)
        }
    }
}
