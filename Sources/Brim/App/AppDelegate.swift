import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist sets LSUIElement; this also covers running the bare binary.
        NSApp.setActivationPolicy(.accessory)
        ScreenManager.shared.start()
        #if DEBUG
        DebugHooks.install()
        #endif
    }
}
