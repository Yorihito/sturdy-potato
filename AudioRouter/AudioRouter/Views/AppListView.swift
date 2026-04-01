import SwiftUI
import AppKit

/// Displays the list of running regular applications with per-app device pickers.
struct AppListView: View {

    var routingVM: AudioRoutingViewModel

    var body: some View {
        Group {
            if routingVM.apps.isEmpty {
                ContentUnavailableView(
                    "No Applications",
                    systemImage: "app.dashed",
                    description: Text("Launch an app to set its auto-switch device.")
                )
            } else {
                List(routingVM.apps) { app in
                    AppRowView(app: app, routingVM: routingVM)
                        .listRowSeparator(.visible)
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct AppRowView: View {

    let app: AppEntry
    var routingVM: AudioRoutingViewModel

    var body: some View {
        HStack(spacing: 8) {
            appIcon
            appName
            Spacer()
            DevicePickerView(
                selectedDeviceUID: Binding(
                    get: {
                        // 常に ViewModel の最新値を参照する
                        routingVM.apps.first(where: { $0.id == app.id })?.assignedDeviceUID
                            ?? AudioDevice.systemDefault.uid
                    },
                    set: { uid in
                        guard let device = routingVM.devices.first(where: { $0.uid == uid }) else { return }
                        Task { await routingVM.assign(device: device, toApp: app) }
                    }
                ),
                devices: routingVM.devices
            )
        }
        .padding(.vertical, 4)
    }

    private var appIcon: some View {
        Group {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
    }

    private var appName: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(app.name)
                .lineLimit(1)
            Text(app.id)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
