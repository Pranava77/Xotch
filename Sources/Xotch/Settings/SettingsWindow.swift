import AppKit
import SwiftUI

/// The one Settings window, opened from the menu bar and from inside the notch.
/// SwiftUI's `openSettings` and `SettingsLink` do nothing in the notch, because
/// it isn't part of a scene, so Xotch keeps its own window instead.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    /// Shows Settings, on `pane` if given, otherwise where it was last left.
    static func show(_ pane: SettingsPane? = nil) {
        if let pane {
            UserDefaults.standard.set(pane.rawValue, forKey: SettingsKey.settingsPane)
        }
        // The notch sits above every window; get it out of the way.
        ScreenManager.shared.closeAll()
        let window = window ?? {
            let made = makeWindow()
            Self.window = made
            return made
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// A sidebar of pages beside the page itself, like System Settings. SwiftUI's
    /// NavigationSplitView ignores its column width and title outside a SwiftUI
    /// scene, so AppKit's split view holds the two halves instead.
    static func makeWindow() -> NSWindow {
        let sidebarController = NSHostingController(rootView: SettingsSidebar())
        sidebarController.sizingOptions = []
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebar.canCollapse = false
        sidebar.minimumThickness = 210
        sidebar.maximumThickness = 210

        let detailController = NSHostingController(rootView: SettingsDetail())
        detailController.sizingOptions = []

        let split = NSSplitViewController()
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: detailController))

        let window = NSWindow(contentViewController: split)
        // Full-size content and a toolbar run the sidebar up under the title bar.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 720, height: 560))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
