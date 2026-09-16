import AppKit

/// Puts a notch on the chosen displays, rebuilds when displays change,
/// and routes pointer, keyboard and trackpad events to each notch.
@MainActor
final class ScreenManager {
    static let shared = ScreenManager()

    private var controllers: [NotchWindowController] = []
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var displayChoice = ""
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var isFileDrag = false

    func start() {
        rebuild()
        installMonitors()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
    }

    func openPrimary() {
        controllers.first?.open(pinned: true)
    }

    func closeAll() {
        controllers.forEach { $0.close() }
    }

    /// Switches every notch to a module, e.g. from a Home card.
    func show(moduleID: String) {
        controllers.forEach { $0.select(moduleID: moduleID) }
    }

    // MARK: - Displays

    private func settingsChanged() {
        if AppSettings.displayChoice != displayChoice {
            rebuild()
        }
    }

    private func rebuild() {
        displayChoice = AppSettings.displayChoice
        controllers.forEach { $0.tearDown() }
        controllers = targetScreens().map { NotchWindowController(screen: $0) }
    }

    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        if displayChoice == DisplayChoice.all {
            return screens
        }
        if let name = DisplayChoice.screenName(in: displayChoice),
           let match = screens.first(where: { $0.localizedName == name }) {
            return [match]
        }
        // Automatic: the built-in notch if there is one, otherwise the menu-bar display.
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return [notched]
        }
        return Array(screens.prefix(1))
    }

    // MARK: - Events

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        add(NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] event in
            let isDrag = event.type == .leftMouseDragged
            MainActor.assumeIsolated {
                self?.pointerMoved()
                if isDrag { self?.dragMoved() }
            }
        })
        add(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragEnded() }
        })
        add(NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        })
        add(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerPressed() }
        })
        add(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        })
        add(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) }
            return event
        })
    }

    private func add(_ monitor: Any?) {
        if let monitor { monitors.append(monitor) }
    }

    private func pointerMoved() {
        let location = NSEvent.mouseLocation
        controllers.forEach { $0.pointerMoved(to: location) }
    }

    private func pointerPressed() {
        let location = NSEvent.mouseLocation
        controllers.forEach { $0.pointerPressed(at: location) }
        // Remember the drag pasteboard, so a change means a new drag began.
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        isFileDrag = false
    }

    /// Another app is dragging something. Only file drags open the shelf.
    private func dragMoved() {
        let location = NSEvent.mouseLocation
        guard controllers.contains(where: { $0.isInDragZone(location) }) else { return }
        if !isFileDrag {
            let pasteboard = NSPasteboard(name: .drag)
            guard pasteboard.changeCount != dragChangeCount,
                  pasteboard.types?.contains(.fileURL) == true else { return }
            isFileDrag = true
        }
        controllers.forEach { $0.fileDragMoved(to: location) }
    }

    private func dragEnded() {
        guard isFileDrag else { return }
        isFileDrag = false
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        controllers.forEach { $0.fileDragEnded() }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        controllers.contains { $0.handleKey(event) }
    }

    private func handleScroll(_ event: NSEvent) {
        controllers.forEach { $0.handleScroll(event) }
    }
}
