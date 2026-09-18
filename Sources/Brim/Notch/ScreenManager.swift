import AppKit

/// Puts a notch on the chosen displays, keeps them in step with display
/// changes, sleep and full-screen apps, and routes pointer, keyboard and
/// trackpad events to each notch.
@MainActor
final class ScreenManager {
    static let shared = ScreenManager()

    private var controllers: [String: NotchWindowController] = [:]
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var displayChoice = ""
    private var hideInFullScreen = true
    private var rebuildTask: Task<Void, Never>?
    private var fullScreenTask: Task<Void, Never>?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var isFileDrag = false

    func start() {
        rebuild()
        installMonitors()

        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { manager in
            manager.scheduleRebuild()
        }
        observe(NotificationCenter.default, UserDefaults.didChangeNotification) { manager in
            manager.settingsChanged()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { manager in
            // Don't come back from sleep with the notch pinned open.
            manager.closeAll()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { manager in
            manager.scheduleRebuild()
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { manager in
            #if DEBUG
            manager.debugNoteSpaceChange()
            #endif
            manager.scheduleFullScreenCheck()
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { manager in
            manager.scheduleFullScreenCheck()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (ScreenManager) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    func openPrimary() {
        primary?.open(pinned: true)
    }

    /// Opens the notch without taking focus, e.g. to preview an effect from Settings.
    func openPrimaryForPreview() {
        primary?.open(pinned: false, focus: false)
    }

    func closeAll() {
        controllers.values.forEach { $0.close() }
    }

    /// Switches every notch to a module, e.g. from a Home card.
    func show(moduleID: String) {
        controllers.values.forEach { $0.select(moduleID: moduleID) }
    }

    private var primary: NotchWindowController? {
        controllers.values.sorted { $0.screenFrame.minX < $1.screenFrame.minX }
            .first { $0.hasHardwareNotch } ?? controllers.values.first
    }

    // MARK: - Displays

    private func settingsChanged() {
        ModuleRegistry.syncRunning()
        DownloadsService.shared.settingsChanged()
        AudioLevels.shared.settingsChanged()
        CaptureService.shared.settingsChanged()
        LifeService.shared.settingsChanged()
        let hide = AppSettings.hideInFullScreen
        if hide != hideInFullScreen {
            hideInFullScreen = hide
            checkFullScreen()
        }
        if AppSettings.displayChoice != displayChoice {
            scheduleRebuild()
        }
    }

    /// Display changes arrive in bursts; rebuild once they settle.
    func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    /// Keeps notches whose display didn't change, so their state survives.
    func rebuild() {
        displayChoice = AppSettings.displayChoice
        hideInFullScreen = AppSettings.hideInFullScreen
        let targets = targetScreens()
        var next: [String: NotchWindowController] = [:]
        let selected = primary?.model.selectedModuleID
        for screen in targets {
            let key = Self.key(for: screen)
            if let existing = controllers[key] {
                next[key] = existing
            } else {
                let controller = NotchWindowController(screen: screen)
                if let selected {
                    controller.model.selectedModuleID = selected
                }
                next[key] = controller
            }
        }
        for (key, controller) in controllers where next[key] == nil {
            controller.tearDown()
        }
        controllers = next
        checkFullScreen()
    }

    /// A display's identity plus its geometry: a resolution change counts as a new display.
    private static func key(for screen: NSScreen) -> String {
        let frame = screen.frame
        return "\(screen.displayID ?? 0)-\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))-\(Int(screen.safeAreaInsets.top))"
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

    // MARK: - Full screen

    private func scheduleFullScreenCheck() {
        checkFullScreen()
        // Entering or leaving full screen animates for a moment; look again after.
        fullScreenTask?.cancel()
        fullScreenTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.checkFullScreen()
        }
    }

    private func checkFullScreen() {
        guard hideInFullScreen else {
            controllers.values.forEach { $0.setHiddenForFullScreen(false) }
            return
        }
        let windows = FullScreenDetector.onScreenWindows()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for controller in controllers.values {
            let frame = FullScreenDetector.quartzFrame(of: controller.screenFrame, primaryHeight: primaryHeight)
            controller.setHiddenForFullScreen(FullScreenDetector.isFullScreen(screen: frame, windows: windows))
        }
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
        #if DEBUG
        pointerEvents += 1
        #endif
        let location = NSEvent.mouseLocation
        controllers.values.forEach { $0.pointerMoved(to: location) }
    }

    private func pointerPressed() {
        let location = NSEvent.mouseLocation
        controllers.values.forEach { $0.pointerPressed(at: location) }
        // Remember the drag pasteboard, so a change means a new drag began.
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        isFileDrag = false
    }

    /// Another app is dragging something. Only file drags open the shelf.
    private func dragMoved() {
        let location = NSEvent.mouseLocation
        guard controllers.values.contains(where: { $0.isInDragZone(location) }) else { return }
        if !isFileDrag {
            let pasteboard = NSPasteboard(name: .drag)
            guard pasteboard.changeCount != dragChangeCount,
                  pasteboard.types?.contains(.fileURL) == true else { return }
            isFileDrag = true
        }
        controllers.values.forEach { $0.fileDragMoved(to: location) }
    }

    private func dragEnded() {
        guard isFileDrag else { return }
        isFileDrag = false
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        controllers.values.forEach { $0.fileDragEnded() }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        controllers.values.contains { $0.handleKey(event) }
    }

    private func handleScroll(_ event: NSEvent) {
        controllers.values.forEach { $0.handleScroll(event) }
    }

    #if DEBUG
    /// Timestamps when macOS says the desktop changed, to line up against the
    /// window server's slide animation.
    private var spaceLog: URL?

    func debugTraceSpaces(to path: String) {
        spaceLog = URL(fileURLWithPath: path)
        try? "space change log\n".write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    func debugNoteSpaceChange() {
        guard let spaceLog, let handle = try? FileHandle(forWritingTo: spaceLog) else { return }
        let line = String(format: "%.3f activeSpaceDidChange\n", Date().timeIntervalSince1970)
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }

    private var pointerEvents = 0
    private var lastCountReset = Date()

    /// Pointer events per second since the last call.
    func debugPointerRate() -> Double {
        let rate = Double(pointerEvents) / max(Date().timeIntervalSince(lastCountReset), 0.001)
        pointerEvents = 0
        lastCountReset = Date()
        return rate
    }

    var debugSummary: String {
        controllers.map { key, controller in
            "\(key): phase=\(controller.model.phase) hiddenForFullScreen=\(controller.isHiddenForFullScreen) module=\(controller.model.selectedModuleID) \(controller.debugFrames)"
        }.sorted().joined(separator: "; ")
    }

    /// Drops every notch and builds new ones, to check for leaks.
    func debugForceRebuild() {
        controllers.values.forEach { $0.tearDown() }
        controllers = [:]
        rebuild()
    }

    func debugPalette() {
        primary?.openPalette(focus: false)
    }

    /// Plays the drop ripple in the middle of the open notch.
    func debugRipple() {
        guard let primary else { return }
        if primary.model.phase != .open {
            primary.open(pinned: true, focus: false)
        }
        primary.model.dropPoint = CGPoint(x: primary.model.openSize.width / 2, y: primary.model.openSize.height / 2)
        primary.model.dropCount += 1
    }

    func debugOpen(moduleID: String) {
        guard let primary else { return }
        primary.model.selectedModuleID = moduleID
        // No focus, so measuring doesn't take the keyboard from other apps.
        primary.open(pinned: true, focus: false)
    }
    #endif
}
