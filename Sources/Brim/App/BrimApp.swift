import SwiftUI

@main
struct BrimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        MenuBarExtra("Brim", systemImage: "rectangle.topthird.inset.filled") {
            MenuContent()
        }
        Settings {
            SettingsView()
        }
    }
}

private struct MenuContent: View {
    var body: some View {
        Button("Open Notch") { ScreenManager.shared.openPrimary() }
        Button("Send a Test Live Activity") { ActivityCenter.shared.postDemo() }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Brim") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
