import AgentManagerCore
import AppKit
import SwiftUI

@main
struct AgentManagerApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Agent Manager", id: "main") {
            RootView(model: model)
                .onAppear {
                    model.reload()
                    // Capture SwiftUI's window opener so the AppKit-managed menu
                    // bar can bring the main window forward from any mode.
                    model.presentMainWindow = {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    model.startMenuBar()
                }
        }
        .windowResizability(.contentMinSize)
        // First-launch size (macOS restores the user's own size afterwards):
        // roomy enough for the planner grid + coverage column without scrolling.
        .defaultSize(width: 1120, height: 780)
    }
}

/// A SwiftPM executable launches as an accessory by default; promote to a normal
/// app so the window shows and can take focus. Also reopens the window when the
/// Dock icon is clicked with nothing visible (e.g. the menu bar is hidden).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = AgentManagerLogo.iconImage() {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}
