import SwiftUI

/// A compact menu-button that lets the user pick an audio output device.
struct DevicePickerView: View {

    @Binding var selectedDeviceUID: String
    let devices: [AudioDevice]

    var body: some View {
        Menu {
            ForEach(devices) { device in
                Button {
                    selectedDeviceUID = device.uid
                } label: {
                    HStack {
                        deviceIcon(for: device)
                        Text(device.name)
                        if selectedDeviceUID == device.uid {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let current = devices.first(where: { $0.uid == selectedDeviceUID }) {
                    deviceIcon(for: current)
                    Text(current.name)
                        .lineLimit(1)
                } else {
                    Image(systemName: "speaker.slash")
                    Text("Unknown")
                }
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Select audio output device")
    }

    // MARK: - Helpers

    @ViewBuilder
    private func deviceIcon(for device: AudioDevice) -> some View {
        if device.uid == AudioDevice.systemDefault.uid {
            Image(systemName: "speaker.wave.2")
                .imageScale(.small)
        } else if device.isHDMI {
            Image(systemName: "tv")
                .imageScale(.small)
        } else {
            Image(systemName: "speaker.fill")
                .imageScale(.small)
        }
    }
}
