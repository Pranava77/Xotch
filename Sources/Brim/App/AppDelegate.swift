import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist sets LSUIElement; this also covers running the bare binary.
        NSApp.setActivationPolicy(.accessory)
        // Writing to the media bridge after it exits must not kill Brim.
        signal(SIGPIPE, SIG_IGN)
        ModuleRegistry.startAll()
        ScreenManager.shared.start()
        #if DEBUG
        DebugHooks.install()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotesService.shared.flush()
        ClaudeLiveService.shared.stop()
    }
}
