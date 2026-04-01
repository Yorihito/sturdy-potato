import Foundation
import AppKit

struct AppEntry: Identifiable, Equatable {
    let id: String           // bundleID
    let name: String
    let icon: NSImage?
    var assignedDeviceUID: String   // "system-default" means system default
    let processID: pid_t

    static func == (lhs: AppEntry, rhs: AppEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.processID == rhs.processID
            && lhs.assignedDeviceUID == rhs.assignedDeviceUID
    }
}
