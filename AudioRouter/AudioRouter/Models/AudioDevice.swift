import Foundation
import CoreAudio

struct AudioDevice: Identifiable, Codable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let isHDMI: Bool

    static let systemDefault = AudioDevice(
        id: kAudioObjectUnknown,
        name: "System Default",
        uid: "system-default",
        isHDMI: false
    )
}
