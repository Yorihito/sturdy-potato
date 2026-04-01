import SwiftUI
import AppKit

@main
struct AudioRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var onboardingWindow: NSWindow?   // strong reference — keeps window alive during animations
    let routingViewModel = AudioRoutingViewModel()
    let profileViewModel = ProfileViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Audio Router")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Set up popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 400, height: 500)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(
            rootView: MenuBarView(routingVM: routingViewModel, profileVM: profileViewModel)
        )

        // Check first launch
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            showOnboarding()
        }

        Task {
            await routingViewModel.refresh()
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func showOnboarding() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Audio Router"
        window.contentViewController = NSHostingController(rootView: OnboardingView())
        window.center()
        window.isReleasedWhenClosed = false  // prevent AppKit from releasing on close
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window  // retain strongly on AppDelegate
    }
}
