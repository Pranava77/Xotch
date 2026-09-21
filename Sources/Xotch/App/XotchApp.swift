import SwiftUI

@main
struct XotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        MenuBarExtra("Xotch", systemImage: "rectangle.topthird.inset.filled") {
            MenuContent()
        }
        Settings {
            SettingsView()
        }
    }
}

private struct MenuContent: View {
    @AppStorage(Diagnostics.shareKey) private var shareDiagnostics = false
    private var diagnostics: Diagnostics { .shared }
    private var capture: CaptureService { .shared }

    var body: some View {
        Button("Open Notch") { ScreenManager.shared.openPrimary() }
        Divider()
        Button("Take Screenshot") { capture.takeScreenshot(.area) }
        if capture.isRecording {
            Button("Stop Recording") { capture.stopRecording() }
        } else {
            Button("Record Screen") { capture.startRecording(.screen) }
                .disabled(!CaptureService.canRecord)
        }
        Divider()
        Button("Send a Test Live Activity") { ActivityCenter.shared.postDemo() }
        Divider()
        if shareDiagnostics, diagnostics.lastCrashReport != nil {
            Button("Xotch Quit Unexpectedly: Email Report…") { diagnostics.emailCrashReport() }
        }
        Button("Send Feedback…") { diagnostics.sendFeedback() }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Xotch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
