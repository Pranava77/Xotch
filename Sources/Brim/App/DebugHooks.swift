#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: drive the notch from the command line.
///
///     scripts/debug.sh open | close | activity | snapshot <folder>
///
/// `snapshot` renders every notch state to PNGs with ImageRenderer, so the
/// shell can be checked without screen-recording permission.
enum DebugHooks {
    static let notificationName = Notification.Name("com.pranava.brim.debug")

    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: notificationName, object: nil, queue: .main
        ) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { run(command) }
        }
    }

    @MainActor
    private static func run(_ command: String) {
        switch command {
        case "open": ScreenManager.shared.openPrimary()
        case "close": ScreenManager.shared.closeAll()
        case "activity": ActivityCenter.shared.postDemo()
        default:
            if command.hasPrefix("snapshot:") {
                snapshot(to: String(command.dropFirst("snapshot:".count)))
            }
        }
    }

    @MainActor
    private static func snapshot(to directory: String) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else {
            return
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let actions = SnapshotActions()

        func render(_ name: String, configure: (NotchViewModel) -> Void) {
            let model = NotchViewModel(geometry: NotchGeometry(screen: screen))
            configure(model)
            let view = ShellView(model: model, actions: actions)
                .frame(width: Layout.panelSize.width, height: Layout.panelSize.height)
                .background(Color(white: 0.84))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return
            }
            try? png.write(to: folder.appendingPathComponent("\(name).png"))
        }

        render("1-closed") { _ in }
        render("2-peek") { $0.phase = .peek }
        for module in ModuleRegistry.all {
            render("4-open-\(module.id)") {
                $0.phase = .open
                $0.selectedModuleID = module.id
            }
        }
        render("5-open-pinned") {
            $0.phase = .open
            $0.isPinned = true
        }
        ActivityCenter.shared.post(LiveActivity(moduleID: "revenue", symbol: "dollarsign.circle.fill",
                                                text: "+$49", tint: .green))
        render("3-activity") { _ in }
    }
}

@MainActor
private final class SnapshotActions: NotchActions {
    func tapped() {}
    func togglePin() {}
    func select(moduleID: String) {}
}
#endif
