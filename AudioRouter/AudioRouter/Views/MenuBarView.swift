import SwiftUI

/// Root view displayed inside the menu-bar popover.
struct MenuBarView: View {

    var routingVM: AudioRoutingViewModel
    var profileVM: ProfileViewModel

    @State private var selectedTab: Tab = .apps

    enum Tab: String, CaseIterable, Identifiable {
        case apps = "Apps"
        case profiles = "Profiles"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            tabContent
        }
        .frame(width: 400, height: 500)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(Color.accentColor)
            Text("Audio Router")
                .font(.headline)
            Spacer()
            if routingVM.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Button {
                    Task { await routingVM.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh device list")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) {
                    if selectedTab == tab {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .apps:
            AppListView(routingVM: routingVM)
        case .profiles:
            ProfileView(routingVM: routingVM, profileVM: profileVM)
        }
    }
}
