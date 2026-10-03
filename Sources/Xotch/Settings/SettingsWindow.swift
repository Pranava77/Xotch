import AppKit
import SwiftUI

/// Settings opened from inside the notch. SwiftUI's `openSettings` and
/// `SettingsLink` do nothing there, because the notch isn't part of a scene.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        // The notch sits above every window; get it out of the way.
        ScreenManager.shared.closeAll()
        let window = window ?? {
            let made = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            made.title = "Xotch Settings"
            made.styleMask = [.titled, .closable, .miniaturizable]
            made.isReleasedWhenClosed = false
            made.center()
            Self.window = made
            return made
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
