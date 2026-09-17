import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill` and logout send SIGTERM; quit normally so notes are saved.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSource = source

        // Info.plist sets LSUIElement; this also covers running the bare binary.
        NSApp.setActivationPolicy(.accessory)
        // Writing to the media bridge after it exits must not kill Brim.
        signal(SIGPIPE, SIG_IGN)
        LegacyCleanup.run()
        Diagnostics.shared.sessionStarted()
        ModuleRegistry.syncRunning()
        DownloadsService.shared.settingsChanged()
        ScreenManager.shared.start()
        #if DEBUG
        DebugHooks.install()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotesService.shared.flush()
        ClaudeLiveService.shared.stop()
        Diagnostics.shared.sessionEnded()
    }
}
